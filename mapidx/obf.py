"""Turn the synthetic .osm.pbf into a POI-only .obf with OsmAndMapCreator.

MapCreator keeps a node only if one of its tags is a POI type it recognises on
a *node*, and silently drops the rest. That set is not derivable from
poi_types.xml - waterway=stream is listed there yet rejected on nodes - so it
is probed: one node per distinct category through generate-poi, then read back.
Rejected categories get a second, accepted tag so the name still reaches the
index, and the POI count of the result is checked against the input.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import osmium

# Added to nodes whose own category MapCreator rejects. It is accepted on
# nodes, says nothing false about the object, and keeps the entry searchable.
FALLBACK_TAG = ("place", "locality")

# Both MapCreator tools need far more than their 512M default: the inspector
# reads the whole POI name index into memory. Overridable from the environment.
JAVA_OPTS = "-Xms1G -Xmx12G"
NAME_INDEX_CHARS = 3

_OSMID = re.compile(r"osmid=(\d+)")


def _run(script: Path, *args: str, cwd: Path) -> str:
    env = {**os.environ}
    env.setdefault("JAVA_OPTS", JAVA_OPTS)
    done = subprocess.run([str(script.resolve()), *args], cwd=cwd, env=env,
                          capture_output=True, text=True)
    if done.returncode:
        tail = "\n".join(done.stderr.splitlines()[-15:])
        raise SystemExit(f"{script.name} failed ({done.returncode}):\n{tail}")
    return done.stdout


def _tag(node) -> tuple[str, str] | None:
    """The one non-name tag emit.write_osm gives every synthetic node."""
    for key, value in node.tags:
        if key != "name":
            return key, value
    return None


def _generate_poi(creator: Path, pbf: Path) -> Path:
    """MapCreator writes the obf beside the input, named after it."""
    work = pbf.parent
    for stale in work.glob("*.obf"):
        stale.unlink()
    _run(creator / "utilities.sh", "generate-poi", str(pbf.resolve()),
         f"--chars-build-poi-nameindex={NAME_INDEX_CHARS}", cwd=work)
    return next(work.glob("*.obf"))


def _indexed_ids(creator: Path, obf: Path) -> set[int]:
    out = _run(creator / "inspector.sh", "-vpoi", "-vpoiobjects",
               str(obf.resolve()),
               cwd=obf.parent)
    return {int(m) for m in _OSMID.findall(out)}


def categories(pbf: Path) -> set[str]:
    found = set()
    for node in osmium.FileProcessor(str(pbf)):
        tag = _tag(node)
        if tag:
            found.add(f"{tag[0]}={tag[1]}")
    return found


def probe_accepted(creator: Path, wanted: set[str], work: Path) -> set[str]:
    """Which categories survive generate-poi, found out by running it."""
    ordered = sorted(wanted)
    probe = work / "probe.osm.pbf"
    work.mkdir(parents=True, exist_ok=True)
    probe.unlink(missing_ok=True)
    writer = osmium.SimpleWriter(str(probe))
    try:
        for node_id, category in enumerate(ordered, 1):
            key, _, value = category.partition("=")
            writer.add_node(osmium.osm.mutable.Node(
                id=node_id, location=(24.0, 49.0),
                tags={"name": f"probe{node_id}", key: value}))
    finally:
        writer.close()
    kept = _indexed_ids(creator, _generate_poi(creator, probe))
    return {category for node_id, category in enumerate(ordered, 1)
            if node_id in kept}


def stage(src: Path, dst: Path, accepted: set[str]) -> tuple[int, int]:
    """Copy the synthetic nodes, rescuing those MapCreator would drop."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.unlink(missing_ok=True)
    writer = osmium.SimpleWriter(str(dst))
    total = rescued = 0
    try:
        for node in osmium.FileProcessor(str(src)):
            total += 1
            tags = dict(node.tags)
            tag = _tag(node)
            if tag is None or f"{tag[0]}={tag[1]}" not in accepted:
                rescued += 1
                tags[FALLBACK_TAG[0]] = FALLBACK_TAG[1]
            writer.add_node(osmium.osm.mutable.Node(
                id=node.id, location=(node.location.lon, node.location.lat),
                tags=tags))
    finally:
        writer.close()
    return total, rescued


def build(creator: Path, src: Path, out: Path, work: Path, progress=print) -> Path:
    """src is out/<region>-mapidx.osm.pbf; returns the finished .obf."""
    found = categories(src)
    accepted = probe_accepted(creator, found, work / "probe")
    progress(f"categories: {len(accepted):,} of {len(found):,} accepted by MapCreator")

    # MapCreator names the obf after the input file, and OsmAnd shows that name
    # in its map list, so the staged copy carries the name we want to see.
    region = src.name.split("-", 1)[0]
    staged = work / "obf" / f"{region.capitalize()}_mapidx.osm.pbf"
    total, rescued = stage(src, staged, accepted)
    progress(f"staged {total:,} nodes, {rescued:,} rescued with "
             f"{FALLBACK_TAG[0]}={FALLBACK_TAG[1]}")

    obf = _generate_poi(creator, staged)
    indexed = len(_indexed_ids(creator, obf))
    progress(f"indexed {indexed:,} of {total:,} nodes")
    if indexed < total:
        raise SystemExit(f"MapCreator dropped {total - indexed:,} nodes")

    out.mkdir(parents=True, exist_ok=True)
    final = out / obf.name
    final.unlink(missing_ok=True)
    obf.rename(final)
    return final
