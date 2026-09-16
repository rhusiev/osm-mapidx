from __future__ import annotations

import argparse
import time
from pathlib import Path

from . import search

# build, emit and obf are imported inside their commands: they need osmium,
# shapely and numpy, while searching needs nothing outside the standard
# library, so the search command stays runnable on a phone (Termux).

REGIONS = {
    "lviv": (22.5, 48.6, 26.3, 50.7),
    "ukraine": None,
}


def _timed(label: str, fn, *args, **kwargs):
    start = time.monotonic()
    result = fn(*args, **kwargs)
    print(f"{label}: {time.monotonic() - start:.1f}s")
    return result


def cmd_build(args) -> None:
    from . import build, emit

    bbox = REGIONS[args.region]
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    place_db = out / f"{args.region}-places.sqlite"
    cache = Path(args.cache) / f"{args.region}-indexes.pickle"
    cache.parent.mkdir(parents=True, exist_ok=True)

    print(f"region {args.region} bbox={bbox}")
    if cache.exists() and not args.refresh:
        idx = _timed("pass 1 (cached)", build.Indexes.load, cache)
    else:
        idx = _timed("pass 1 (context sources)",
                     build.collect_indexes, Path(args.pbf), bbox)
        idx.save(cache)
    places, names = _timed("pass 2 (places)",
                           build.build_places, Path(args.pbf), place_db, idx, bbox)
    print(f"places: {places:,}  name variants: {names:,}")

    nodes = _timed("osm export", emit.write_osm, place_db,
                   out / f"{args.region}-mapidx.osm.pbf")
    print(f"synthetic nodes: {nodes:,}")
    rows, vocabulary = _timed("search export", emit.write_search, place_db,
                              out / f"{args.region}-search.sqlite")
    print(f"search rows: {rows:,}  indexed words: {vocabulary:,}")


def cmd_obf(args) -> None:
    from . import obf

    src = Path(args.out) / f"{args.region}-mapidx.osm.pbf"
    if not src.exists():
        raise SystemExit(f"missing {src} - run build first")
    final = _timed("obf build", obf.build, Path(args.creator), src,
                   Path(args.out), Path(args.work))
    print(f"obf: {final} ({final.stat().st_size / 1e6:,.0f} MB)")


def cmd_search(args) -> None:
    origin = tuple(args.near) if args.near else None
    for hit in search.search(args.db, args.query, args.limit, origin=origin):
        away = f"  {hit['metres'] / 1000:.1f} km" if hit["metres"] is not None else ""
        address = ", ".join(hit["address"])
        print(f"{hit['score']:.2f}  ex:{hit['exact_count']}  {hit['name']}  ({address})  "
              f"geo:{hit['lat']:.5f},{hit['lon']:.5f}{away}")


def main() -> None:
    parser = argparse.ArgumentParser(prog="mapidx")
    sub = parser.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="build place table and both exports")
    b.add_argument("pbf")
    b.add_argument("--region", choices=sorted(REGIONS), default="lviv")
    b.add_argument("--out", default="out")
    b.add_argument("--cache", default="build")
    b.add_argument("--refresh", action="store_true",
                   help="rebuild the context index cache")
    b.set_defaults(func=cmd_build)

    o = sub.add_parser("obf", help="turn the osm export into an OsmAnd map")
    o.add_argument("--region", choices=sorted(REGIONS), default="lviv")
    o.add_argument("--out", default="out")
    o.add_argument("--work", default="build")
    o.add_argument("--creator", default="build/OsmAndMapCreator")
    o.set_defaults(func=cmd_obf)

    s = sub.add_parser("search", help="fuzzy search the FTS export")
    s.add_argument("db")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=20)
    s.add_argument("--near", type=float, nargs=2, metavar=("LAT", "LON"),
                   help="rank ties by distance from here")
    s.set_defaults(func=cmd_search)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
