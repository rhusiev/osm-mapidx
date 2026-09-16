"""Export the place table to the two consumable formats.

Both exports read the same rows. The OSM export feeds OsmAndMapCreator and ends
up searchable inside OsmAnd itself, but inherits OsmAnd's prefix-only matching.
The search export is queried outside OsmAnd - by the CLI and by the phone app -
and adds typo tolerance.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

import osmium

from .translit import is_cyrillic, normalise, romanise_kmu, romanise_context
from .vocab import NAME_BIT, encode, words

SEARCH_SCHEMA = """
CREATE TABLE places(
  rowid INTEGER PRIMARY KEY,
  lon REAL NOT NULL,
  lat REAL NOT NULL,
  display_name TEXT NOT NULL,
  category TEXT NOT NULL,
  name_terms TEXT NOT NULL,
  context_terms TEXT NOT NULL
);
CREATE TABLE vocab(word TEXT PRIMARY KEY, places INTEGER NOT NULL,
                   postings BLOB NOT NULL) WITHOUT ROWID;
CREATE VIRTUAL TABLE vocab_fuzzy USING fts5(word, tokenize='trigram');
"""


def _rows(db: sqlite3.Connection):
    query = """
      SELECT p.id, p.lon, p.lat, p.primary_name, p.category, p.context,
             group_concat(n.name, char(10))
      FROM places p JOIN names n ON n.place_id = p.id
      GROUP BY p.id
    """
    return db.execute(query)


def display_name(name: str, context: str) -> str:
    return f"{name} ({context})" if context else name


def _matched_context(name: str, context: str) -> str:
    """Latin name variants get a Latin context, so a fully Latin query matches."""
    if context and not is_cyrillic(name) and is_cyrillic(context):
        return romanise_kmu(context)
    return context


def write_osm(place_db: Path, out_pbf: Path, progress=print) -> int:
    """One node per name variant, each carrying the full context in its name."""
    out_pbf.unlink(missing_ok=True)
    db = sqlite3.connect(place_db)
    writer = osmium.SimpleWriter(str(out_pbf))
    node_id = 0
    try:
        for _, lon, lat, _, category, context, variants in _rows(db):
            key, _, value = category.partition("=")
            for variant in variants.split("\n"):
                node_id += 1
                if node_id % 250_000 == 0:
                    progress(f"  osm: {node_id:,} nodes")
                writer.add_node(osmium.osm.mutable.Node(
                    id=node_id,
                    location=(lon, lat),
                    tags={"name": display_name(variant, _matched_context(variant, context)),
                          key: value},
                ))
    finally:
        writer.close()
        db.close()
    return node_id


def write_search(place_db: Path, out_db: Path) -> tuple[int, int]:
    """One row per place, plus a word index over its names and its context."""
    out_db.unlink(missing_ok=True)
    src = sqlite3.connect(place_db)
    dst = sqlite3.connect(out_db)
    dst.execute("PRAGMA journal_mode=OFF")
    dst.execute("PRAGMA synchronous=OFF")
    dst.executescript(SEARCH_SCHEMA)
    dst.execute("CREATE TEMP TABLE pairs(word TEXT NOT NULL, ref INTEGER NOT NULL)")

    places = 0
    for place_id, lon, lat, primary, category, context, variants in _rows(src):
        places += 1
        name_words = words(normalise(variants.replace("\n", " ")))
        context_words = words(normalise(
            " ".join([context, *romanise_context(context)]))) - name_words
        dst.execute("INSERT INTO places VALUES (?,?,?,?,?,?,?)",
                    (place_id, lon, lat, display_name(primary, context), category,
                     " ".join(sorted(name_words)), " ".join(sorted(context_words))))
        dst.executemany("INSERT INTO pairs VALUES (?,?)",
                        [(word, place_id << 1 | NAME_BIT) for word in name_words]
                        + [(word, place_id << 1) for word in context_words])

    vocabulary = _write_vocab(dst)
    dst.commit()
    dst.execute("INSERT INTO vocab_fuzzy(vocab_fuzzy) VALUES ('optimize')")
    dst.execute("DROP TABLE pairs")
    dst.commit()
    dst.execute("VACUUM")
    dst.close()
    src.close()
    return places, vocabulary


def _write_vocab(dst: sqlite3.Connection) -> int:
    """Postings are grouped by streaming the pairs in order, never in memory."""
    cursor = dst.execute("SELECT word, ref FROM pairs ORDER BY word, ref")
    writer = dst.cursor()
    count = 0
    current: str | None = None
    refs: list[int] = []

    def flush() -> None:
        writer.execute("INSERT INTO vocab VALUES (?,?,?)",
                       (current, len(refs), encode(refs)))
        writer.execute("INSERT INTO vocab_fuzzy(word) VALUES (?)", (current,))

    for word, ref in cursor:
        if word != current:
            if current is not None:
                flush()
                count += 1
            current, refs = word, []
        refs.append(ref)
    if current is not None:
        flush()
        count += 1
    return count
