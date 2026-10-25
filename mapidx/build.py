"""Build a place table with searchable context from an OSM extract.

OsmAnd's POI search matches query tokens against a POI's own name and nothing
else, so a POI that is findable as "Медовий двір" is not findable as
"Медовий двір Славсько". This module derives the context OsmAnd throws away -
containing admin units, nearby settlements, the street - so it can be folded
back into the name at emit time.
"""

from __future__ import annotations

import json
import math
import pickle
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import osmium
import osmium.filter
import shapely
from shapely import STRtree
from shapely.geometry import Point, box, shape
from shapely.ops import nearest_points

from .translit import romanisations

# An object becomes a searchable place if it carries one of these keys.
POI_KEYS = frozenset({
    "amenity", "tourism", "shop", "leisure", "historic", "office", "craft",
    "healthcare", "emergency", "aeroway", "aerialway", "man_made", "military",
    "club", "sport", "public_transport", "railway", "natural", "mountain_pass",
    "place", "landuse", "waterway", "building",
})

# Keys that alone are too weak to make something a POI worth indexing.
WEAK_POI_KEYS = frozenset({"building", "landuse", "natural", "waterway", "railway"})
STRONG_POI_KEYS = POI_KEYS - WEAK_POI_KEYS

NAME_KEYS_EXACT = ("name", "alt_name", "old_name", "int_name", "official_name",
                   "short_name", "loc_name", "nat_name", "reg_name")

PLACE_NEARBY_RANKS = frozenset({
    "city", "town", "village", "hamlet", "suburb", "neighbourhood",
    "isolated_dwelling", "borough", "quarter", "locality",
})
# Settlements are what people name in a search; subdivisions such as
# neighbourhood and locality are often closer but nobody searches by them, so
# they must not crowd the settlements out.
PLACE_SETTLEMENT_RANKS = frozenset({"city", "town", "village", "hamlet"})
PLACE_MAJOR_RANKS = frozenset({"city", "town"})

# Admin levels used as context, in the order they are appended to the name.
ADMIN_CONTEXT_LEVELS = ("8", "7", "6", "4")

SETTLEMENT_RADIUS_M = 12_000
MAJOR_RADIUS_M = 40_000
SUBDIVISION_RADIUS_M = 1_500
STREET_RADIUS_M = 120
MAX_SETTLEMENTS = 3
MAX_SUBDIVISIONS = 1
MAX_CONTEXT_PARTS = 6
INDEX_BBOX_PAD_DEG = 0.35

# Named roads people look a street up by. Paths, tracks and service roads seldom
# carry a name worth finding.
STREET_KINDS = frozenset({
    "trunk", "primary", "secondary", "tertiary", "unclassified", "residential",
    "living_street", "pedestrian",
})
# Ways of one name closer than about this are one street: OSM splits a street at
# junctions and tag changes, and draws a divided road as two ways. The same name
# in the next village is kilometres away.
STREET_JOIN_M = 60

_M_PER_DEG_LAT = 110_574.0


def _m_per_deg_lon(lat: float) -> float:
    return 111_320.0 * math.cos(math.radians(lat))


def _degree_box(lon: float, lat: float, radius_m: float):
    dlat = radius_m / _M_PER_DEG_LAT
    dlon = radius_m / max(_m_per_deg_lon(lat), 1.0)
    return box(lon - dlon, lat - dlat, lon + dlon, lat + dlat)


def _keep(geom, area) -> bool:
    return area is None or geom.intersects(area)


def _geometry(obj):
    try:
        return shape(obj.__geo_interface__["geometry"])
    except Exception:
        return None


@dataclass
class Indexes:
    admin_geoms: list = field(default_factory=list)
    admin_meta: list[tuple[str, str]] = field(default_factory=list)   # (name, level)
    place_geoms: list = field(default_factory=list)
    place_meta: list[tuple[str, str]] = field(default_factory=list)   # (name, place value)
    street_geoms: list = field(default_factory=list)
    street_meta: list[str] = field(default_factory=list)

    def save(self, path: Path) -> None:
        """STRtree cannot be pickled, so only the geometries and metadata are."""
        path.write_bytes(pickle.dumps((
            self.admin_geoms, self.admin_meta, self.place_geoms,
            self.place_meta, self.street_geoms, self.street_meta)))

    @classmethod
    def load(cls, path: Path) -> "Indexes":
        idx = cls(*pickle.loads(path.read_bytes()))
        idx.finalise()
        return idx

    def finalise(self) -> None:
        # Admin polygons are hit once per place, so pay the preparation cost up
        # front rather than rebuilding the point-in-polygon structure each time.
        shapely.prepare(self.admin_geoms)
        self._admin_tree = STRtree(self.admin_geoms) if self.admin_geoms else None
        self._street_tree = STRtree(self.street_geoms) if self.street_geoms else None

        self._place_xy = np.array([[g.x, g.y] for g in self.place_geoms],
                                  dtype=float).reshape(-1, 2)
        self._place_tree = STRtree(self.place_geoms) if self.place_geoms else None
        ranks = [rank for _, rank in self.place_meta]
        self._is_settlement = np.array([r in PLACE_SETTLEMENT_RANKS for r in ranks])
        self._is_major = np.array([r in PLACE_MAJOR_RANKS for r in ranks])

    def _nearby_places(self, lon: float, lat: float) -> tuple[list[str], list[str]]:
        """Nearest settlements and, separately, the immediate subdivision."""
        if self._place_tree is None:
            return [], []
        hits = self._place_tree.query(_degree_box(lon, lat, MAJOR_RADIUS_M))
        if len(hits) == 0:
            return [], []
        kx, ky = _m_per_deg_lon(lat), _M_PER_DEG_LAT
        delta = self._place_xy[hits] - (lon, lat)
        distances = np.hypot(delta[:, 0] * kx, delta[:, 1] * ky)
        order = np.argsort(distances)
        hits, distances = hits[order], distances[order]

        settlement = self._is_settlement[hits]
        near = hits[settlement & (distances <= SETTLEMENT_RADIUS_M)][:MAX_SETTLEMENTS]
        if len(near) == 0:
            near = hits[self._is_major[hits] & (distances <= MAJOR_RADIUS_M)][:1]
        sub = hits[~settlement & (distances <= SUBDIVISION_RADIUS_M)][:MAX_SUBDIVISIONS]
        return ([self.place_meta[i][0] for i in near],
                [self.place_meta[i][0] for i in sub])

    def _street(self, lon: float, lat: float) -> str | None:
        if self._street_tree is None:
            return None
        hits = self._street_tree.query(_degree_box(lon, lat, STREET_RADIUS_M))
        if len(hits) == 0:
            return None
        kx, ky = _m_per_deg_lon(lat), _M_PER_DEG_LAT
        point = Point(lon, lat)
        best: tuple[float, str] | None = None
        for idx in hits:
            near = nearest_points(self.street_geoms[idx], point)[0]
            distance = math.hypot((near.x - lon) * kx, (near.y - lat) * ky)
            if distance <= STREET_RADIUS_M and (best is None or distance < best[0]):
                best = (distance, self.street_meta[idx])
        return best[1] if best else None

    def context_for(self, lon: float, lat: float, own_name: str,
                    addr_street: str | None) -> list[str]:
        parts: list[str] = []

        def add(value: str | None) -> None:
            if value and value != own_name and value not in parts:
                parts.append(value)

        by_level: dict[str, str] = {}
        if self._admin_tree is not None:
            point = Point(lon, lat)
            for idx in self._admin_tree.query(point, predicate="intersects"):
                name, level = self.admin_meta[idx]
                by_level.setdefault(level, name)

        settlements, subdivisions = self._nearby_places(lon, lat)
        for name in settlements:
            add(name)
        add(addr_street or self._street(lon, lat))
        for name in subdivisions:
            add(name)
        for level in ADMIN_CONTEXT_LEVELS:
            add(by_level.get(level))
        return parts[:MAX_CONTEXT_PARTS]


def _poi_category(tags) -> str | None:
    for keys in (STRONG_POI_KEYS, WEAK_POI_KEYS):
        found = [(k, tags[k]) for k in keys if k in tags]
        if found:
            k, v = found[0]
            return f"{k}={v}"
    return None


def _clean(value: str | None) -> str:
    """Collapse whitespace: a newline in a name splits emit's group_concat rows."""
    return " ".join(value.split()) if value else ""


def _name_variants(tags) -> list[tuple[str, str]]:
    """Return (source, name) pairs: tagged names plus their romanisations."""
    out: list[tuple[str, str]] = []
    seen: set[str] = set()

    def add(source: str, value: str) -> None:
        value = _clean(value)
        key = value.casefold()
        if value and key not in seen:
            seen.add(key)
            out.append((source, value))

    for key in NAME_KEYS_EXACT:
        if key in tags:
            add(key, tags[key])
    for key, value in tags:
        if key.startswith("name:") or key.startswith("alt_name:"):
            add(key, value)

    for source, value in list(out):
        for scheme, romanised in romanisations(value):
            add(scheme, romanised)
    return out


@dataclass
class _StreetWay:
    osm_id: int
    geom: object
    variants: list[tuple[str, str]]
    tags: dict[str, str]


def _joined(ways: list[_StreetWay]) -> list[list[_StreetWay]]:
    """Ways of one name, grouped into the streets they draw."""
    geoms = [way.geom for way in ways]
    reach = STREET_JOIN_M / _m_per_deg_lon(geoms[0].centroid.y)
    left, right = STRtree(geoms).query(geoms, predicate="dwithin", distance=reach)
    parent = list(range(len(ways)))

    def root(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, j in zip(left, right):
        parent[root(i)] = root(j)
    streets: dict[int, list[_StreetWay]] = {}
    for i, way in enumerate(ways):
        streets.setdefault(root(i), []).append(way)
    return list(streets.values())


def _street_place(ways: list[_StreetWay]):
    """The street's longest way, a point on the street and all its names."""
    longest = max(ways, key=lambda way: way.geom.length)
    drawn = shapely.GeometryCollection([way.geom for way in ways])
    point = nearest_points(drawn, drawn.centroid)[0]
    variants, seen = [], set()
    for way in ways:
        for source, value in way.variants:
            if value.casefold() not in seen:
                seen.add(value.casefold())
                variants.append((source, value))
    return longest, point, variants


def _named_objects(pbf: Path):
    return (osmium.FileProcessor(str(pbf))
            .with_areas()
            .with_filter(osmium.filter.KeyFilter("name"))
            .with_filter(osmium.filter.GeoInterfaceFilter()))


def collect_indexes(pbf: Path, bbox: tuple[float, float, float, float] | None = None,
                    progress=print) -> Indexes:
    """Context sources are padded past the bbox so edge POIs still see neighbours."""
    idx = Indexes()
    pad = INDEX_BBOX_PAD_DEG
    area = box(bbox[0] - pad, bbox[1] - pad, bbox[2] + pad, bbox[3] + pad) if bbox else None

    for count, obj in enumerate(_named_objects(pbf), 1):
        if count % 250_000 == 0:
            progress(f"  pass 1: {count:,} named objects")
        tags = obj.tags
        name = _clean(tags.get("name"))
        if not name:
            continue
        kind = obj.type_str()
        if kind == "a" and tags.get("boundary") == "administrative":
            level = tags.get("admin_level")
            geom = _geometry(obj) if level in ADMIN_CONTEXT_LEVELS else None
            if geom is not None and not geom.is_empty and _keep(geom, area):
                idx.admin_geoms.append(geom)
                idx.admin_meta.append((name, level))
        elif kind == "n" and tags.get("place") in PLACE_NEARBY_RANKS:
            geom = Point(obj.location.lon, obj.location.lat)
            if _keep(geom, area):
                idx.place_geoms.append(geom)
                idx.place_meta.append((name, tags.get("place")))
        elif kind == "w" and "highway" in tags:
            geom = _geometry(obj)
            if geom is not None and not geom.is_empty and _keep(geom, area):
                idx.street_geoms.append(geom)
                idx.street_meta.append(name)
    idx.finalise()
    progress(f"  admin areas: {len(idx.admin_geoms):,}  "
             f"places: {len(idx.place_geoms):,}  streets: {len(idx.street_geoms):,}")
    return idx


SCHEMA = """
CREATE TABLE places(
  id INTEGER PRIMARY KEY,
  osm_type TEXT NOT NULL,
  osm_id INTEGER NOT NULL,
  lon REAL NOT NULL,
  lat REAL NOT NULL,
  primary_name TEXT NOT NULL,
  category TEXT NOT NULL,
  context TEXT NOT NULL,
  tags TEXT NOT NULL
);
CREATE TABLE names(
  place_id INTEGER NOT NULL REFERENCES places(id),
  source TEXT NOT NULL,
  name TEXT NOT NULL
);
CREATE INDEX names_place ON names(place_id);
"""


class _PlaceWriter:
    """Writes places and their name variants in batches."""

    BATCH = 20_000

    def __init__(self, db: sqlite3.Connection) -> None:
        self._db = db
        self._places: list[tuple] = []
        self._names: list[tuple] = []
        self.count = 0

    def add(self, osm_type: str, osm_id: int, lon: float, lat: float, name: str,
            category: str, context: list[str], tags: dict[str, str],
            variants: list[tuple[str, str]]) -> None:
        self.count += 1
        self._places.append((self.count, osm_type, osm_id, lon, lat, name, category,
                             ", ".join(context), json.dumps(tags, ensure_ascii=False)))
        self._names.extend((self.count, source, value) for source, value in variants)
        if len(self._places) >= self.BATCH:
            self.flush()

    def flush(self) -> None:
        self._db.executemany("INSERT INTO places VALUES (?,?,?,?,?,?,?,?,?)",
                             self._places)
        self._db.executemany("INSERT INTO names VALUES (?,?,?)", self._names)
        self._db.commit()
        self._places, self._names = [], []


def _in_bbox(bbox: tuple[float, float, float, float] | None,
             lon: float, lat: float) -> bool:
    return not bbox or (bbox[0] <= lon <= bbox[2] and bbox[1] <= lat <= bbox[3])


def _add_poi(out: _PlaceWriter, obj, name: str, idx: Indexes,
             bbox: tuple[float, float, float, float] | None) -> None:
    tags = obj.tags
    category = _poi_category(tags)
    if category is None:
        return
    if obj.type_str() == "n":
        lon, lat = obj.location.lon, obj.location.lat
    else:
        geom = _geometry(obj)
        if geom is None or geom.is_empty:
            return
        centre = geom.centroid
        lon, lat = centre.x, centre.y
    variants = _name_variants(tags)
    if not _in_bbox(bbox, lon, lat) or not variants:
        return
    context = idx.context_for(lon, lat, name, _clean(tags.get("addr:street")))
    out.add(obj.type_str(), obj.id, lon, lat, name, category, context, dict(tags),
            variants)


def _street_way(obj) -> _StreetWay | None:
    geom = _geometry(obj)
    if geom is None or geom.is_empty:
        return None
    return _StreetWay(obj.id, geom, _name_variants(obj.tags), dict(obj.tags))


def _add_streets(out: _PlaceWriter, name: str, ways: list[_StreetWay], idx: Indexes,
                 bbox: tuple[float, float, float, float] | None) -> None:
    """One place per street, however many ways OSM draws it with."""
    for street in _joined(ways):
        longest, point, variants = _street_place(street)
        if _in_bbox(bbox, point.x, point.y) and variants:
            out.add("w", longest.osm_id, point.x, point.y, name,
                    f"highway={longest.tags['highway']}",
                    idx.context_for(point.x, point.y, name, None), longest.tags,
                    variants)


def build_places(pbf: Path, db_path: Path, idx: Indexes,
                 bbox: tuple[float, float, float, float] | None = None,
                 progress=print) -> tuple[int, int]:
    """Named POIs, and named streets, each with its context."""
    db_path.unlink(missing_ok=True)
    db = sqlite3.connect(db_path)
    db.executescript(SCHEMA)
    out = _PlaceWriter(db)

    streets: dict[str, list[_StreetWay]] = {}
    for count, obj in enumerate(_named_objects(pbf), 1):
        if count % 250_000 == 0:
            progress(f"  pass 2: {count:,} named objects, {out.count:,} places")
        name = _clean(obj.tags.get("name"))
        if not name:
            continue
        if obj.type_str() == "w" and obj.tags.get("highway") in STREET_KINDS:
            way = _street_way(obj)
            if way is not None:
                streets.setdefault(name, []).append(way)
        else:
            _add_poi(out, obj, name, idx, bbox)
    pois = out.count
    for name, ways in streets.items():
        _add_streets(out, name, ways, idx, bbox)
    out.flush()
    progress(f"  pois: {pois:,}  streets: {out.count - pois:,}")
    counts = (db.execute("SELECT COUNT(*) FROM places").fetchone()[0],
              db.execute("SELECT COUNT(*) FROM names").fetchone()[0])
    db.close()
    return counts
