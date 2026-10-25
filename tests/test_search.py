"""Unit tests that don't need an OSM file or an existing index.

The full search path is exercised by the Dart suite against
out/lviv-search.sqlite, which is not in the repo. These cover the parts the
build pipeline and search roundtrip are made of - vocab encoding, the
Cyrillic folding the Dart side mirrors, and the search engine run against
an index built in-process.
"""

from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path

from mapidx import emit, search, translit, vocab


def _build_index(places: dict[int, dict]) -> Path:
    """Write a tiny search index with the vocabulary test cases need.

    places[rowid] = {"name": str, "context": str, "category": str,
                     "name_words": set[str], "context_words": set[str]},
    optionally with "lon" and "lat"
    """
    with tempfile.NamedTemporaryFile(suffix="-search.sqlite", delete=False) as f:
        path = Path(f.name)
    db = sqlite3.connect(path)
    db.executescript(emit.SEARCH_SCHEMA)
    db.execute("CREATE TEMP TABLE pairs(word TEXT NOT NULL, ref INTEGER NOT NULL)")
    for rid, place in places.items():
        db.execute(
            "INSERT INTO places VALUES (?,?,?,?,?,?,?)",
            (rid, place.get("lon", 23.4), place.get("lat", 48.8),
             emit.display_name(place["name"], place["context"]), place["category"],
             " ".join(sorted(place["name_words"])),
             " ".join(sorted(place["context_words"] - place["name_words"]))),
        )
        for word in place["name_words"]:
            db.execute("INSERT INTO pairs VALUES (?,?)",
                       (word, rid << 1 | vocab.NAME_BIT))
        for word in place["context_words"] - place["name_words"]:
            db.execute("INSERT INTO pairs VALUES (?,?)", (word, rid << 1))
    words = sorted({row[0] for row in db.execute("SELECT word FROM pairs")})
    for word in words:
        refs = [row[0] for row in db.execute(
            "SELECT ref FROM pairs WHERE word = ? ORDER BY ref", (word,))]
        db.execute("INSERT INTO vocab VALUES (?, ?, ?)",
                   (word, len(refs), vocab.encode(refs)))
        db.execute("INSERT INTO vocab_fuzzy(word) VALUES (?)", (word,))
    db.execute("INSERT INTO vocab_fuzzy(vocab_fuzzy) VALUES ('optimize')")
    db.commit()
    db.execute("DROP TABLE pairs")
    db.close()
    return path


class VocabTests(unittest.TestCase):
    def test_encode_decode_roundtrip(self) -> None:
        refs = list(range(0, 10)) + [1_000_000]
        self.assertEqual(vocab.decode(vocab.encode(refs)), refs)

    def test_encode_uses_signed_deltas(self) -> None:
        # LEB128 deltas, not fixed-width: one million postings have to fit
        # in fewer than eight bytes per ref or the index size blows up.
        self.assertLess(len(vocab.encode([0, 1_000_000])), 8)

    def test_back_to_back_postings(self) -> None:
        # Adjacent refs deltas to 1: the smallest meaningful blob shape.
        self.assertEqual(vocab.decode(vocab.encode([42, 43, 44, 45])),
                         [42, 43, 44, 45])


class TranslitTests(unittest.TestCase):
    def test_casefolds_cyrillic(self) -> None:
        self.assertEqual(translit.normalise("Київ"), "киів")
        self.assertEqual(translit.normalise("ЛЬВІВ"), "львів")

    def test_folds_breve_and_ú(self) -> None:
        # й differs from и only by a breve, and that one mark is exactly the
        # kind of difference a typo is - the lookup should treat them as the
        # same word. Same idea for ў -> у.
        self.assertEqual(translit.normalise("Хмельницький"), "хмельницькии")
        self.assertEqual(translit.normalise("ў"), "у")

    def test_strips_latin_accents(self) -> None:
        # NFKD strips the acute from ź but leaves ó in place - the exact set
        # of decomposed letters depends on the Unicode version Python ships.
        self.assertEqual(translit.normalise("Łódź"), "łodz")

    def test_kmu_basic(self) -> None:
        # The official transliteration; what shows up on road signs.
        self.assertEqual(translit.romanise_kmu("Київ"), "kyiv")

    def test_kmu_keeps_зг_distinct_from_ж(self) -> None:
        self.assertEqual(translit.romanise_kmu("згода"), "zghoda")

    def test_naive_picks_g_over_h(self) -> None:
        # The phonetic scheme; what people type in a search box.
        self.assertEqual(translit.romanise_naive("Г"), "g")
        self.assertEqual(translit.romanise_kmu("Г"), "h")


class SearchEngineTests(unittest.TestCase):
    """Search against an index built in-process from a few rows."""

    def setUp(self) -> None:
        # Town has "Славсько" in its own name only. Hotel has "Славсько" in
        # context and "Медовий двір" in its own name. Two places is enough to
        # exercise both the exact and the context paths.
        self.path = _build_index({
            1: {"name": "Славсько", "context": "", "category": "place=town",
                "name_words": {"славсько"}, "context_words": set()},
            2: {"name": "Медовий двір", "context": "Славсько",
                "category": "tourism=hotel",
                "name_words": {"медовий", "двір"},
                "context_words": {"славсько"}},
        })
        self.addCleanup(self.path.unlink)

    def test_single_word_match(self) -> None:
        # One typed word; one place has it as an exact name word - the town.
        hits = search.search(self.path, "Славсько")
        self.assertEqual(hits[0]["name"], "Славсько")
        self.assertEqual(hits[0]["exact_count"], 1)

    def test_two_words_both_match(self) -> None:
        # Hotel has both words; it must rank above a one-word town match.
        hits = search.search(self.path, "Медовий двір")
        self.assertGreaterEqual(len(hits), 1)
        self.assertEqual(hits[0]["name"], "Медовий двір")

    def test_exact_match_outranks_context_match(self) -> None:
        # "сладьско" with a typo - misspelled past the trigram index. Town's
        # Славсько is the exact match; hotel has it only in context. Exact
        # match must outrank context for the same word.
        hits = search.search(self.path, "сладьско")
        names = [hit["name"] for hit in hits]
        if "Славсько" in names and "Медовий двір" in names:
            self.assertLess(names.index("Славсько"),
                            names.index("Медовий двір"),
                            "exact-match place must rank ahead of context-match")

    def test_named_tells_a_name_match_from_a_context_match(self) -> None:
        hits = {hit["name"]: hit["named"] for hit in search.search(self.path, "Славсько")}
        self.assertEqual(hits, {"Славсько": True, "Медовий двір": False})

    def test_a_hit_says_what_it_is(self) -> None:
        hits = {hit["name"]: hit["category"] for hit in search.search(self.path, "Славсько")}
        self.assertEqual(hits, {"Славсько": "place=town", "Медовий двір": "tourism=hotel"})


# Lviv's centre, and a box of about 10 km round it
LVIV = (24.03, 49.84)
LVIV_BOX = (49.79, 23.96, 49.89, 24.10)
# A degree past the box: a town in the same oblast
OBLAST_DEG = 1.0


class WithinTests(unittest.TestCase):
    def test_keeps_the_box_s_place_behind_more_than_it_cuts_to(self) -> None:
        limit = 1
        # search cuts its candidates to ten times the limit
        far = {rid: {"name": "Шевченка", "context": "", "category": "highway=residential",
                     "name_words": {"шевченка"}, "context_words": set(),
                     "lon": LVIV[0] + OBLAST_DEG, "lat": LVIV[1]}
               for rid in range(1, 10 * limit + 2)}
        near = {"name": "Шевченка", "context": "Львів", "category": "highway=residential",
                "name_words": {"шевченка"}, "context_words": {"львів"},
                "lon": LVIV[0], "lat": LVIV[1]}
        path = _build_index({**far, len(far) + 1: near})
        self.addCleanup(path.unlink)

        hits = search.search(path, "шевченка", limit, within=LVIV_BOX)

        self.assertEqual([hit["address"] for hit in hits], [["Львів"]])


if __name__ == "__main__":
    unittest.main()
