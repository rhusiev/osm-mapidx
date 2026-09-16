"""Typo-tolerant lookup over the search export, fast enough to run per keystroke.

The unit of work is the vocabulary word, not the row. Each typed word is first
resolved against the 114k indexed words - by prefix, and if that looks thin, by
the trigram index over those same words - which yields a handful of indexed
words and a score for each. Comparing strings happens once per indexed word
here, where the old row-at-a-time ranking paid for it again in every place that
word occurs.

Walking the postings of those words hands every place its per-word scores
directly, so a query whose words are all spelled recognisably never compares a
word to a place at all. Only when that leaves too few hits are places read in
full, best-agreement first: "двир" shares no trigram with "двір", so nothing in
the vocabulary can look like it, and the place is reached through "славско"
instead. Reading its words is what recognises "двір" once there.

Nothing intersects. A word resolving to real but wrong places - "двор" matches
310 of them, none the hotel in Славсько - would otherwise veto a place every
other word agrees on. Requiring every word to score happens at the end, against
scores, not against sets.

A word matching more places than the cap resolves to name matches only. "гро"
matching every громада in the oblast says nothing about which one is meant, and
walking its postings is the one thing here slow enough to notice.
"""

from __future__ import annotations

import math
import sqlite3
from difflib import SequenceMatcher

from .translit import normalise
from .vocab import NAME_BIT, WORD_RE, decode

MIN_WORD_SCORE = 0.6
MAX_LENGTH_GAP = 3

MAX_VOCAB_WORDS = 500
MAX_REFS = 20_000
# Places worth reading in full to judge a word the vocabulary could not resolve.
MAX_INCOMPLETE = 400

# Under this many places a prefix match is too thin to trust on its own, so the
# word is also resolved as a possible misspelling. "славско" matches one place
# exactly - a Russian name variant - and the hotel in Славсько is not it.
MIN_CONFIDENT_PLACES = 50
# Below this length a word has no trigram left once a letter in the middle is
# wrong, so the trigram index has nothing to find and is not asked.
MIN_FUZZY_WORD = 6

PROBE_TRIM = 2
MIN_PROBE = 3
# A word matched in the place's own name outranks the same word matched in its
# context: everyone types the name, the context only narrows it.
CONTEXT_PENALTY = 0.01
EARTH_RADIUS_M = 6_371_000

# The end of the Unicode range, so `word < prefix + LAST_CHAR` is every
# extension of the prefix and nothing else.
LAST_CHAR = "￿"


def _similarity(word: str, candidate: str) -> float:
    if candidate.startswith(word):
        return 1.0
    if word in candidate:
        return 0.9
    if abs(len(word) - len(candidate)) > MAX_LENGTH_GAP:
        return 0.0
    return SequenceMatcher(None, word, candidate).ratio()


def _word_score(word: str, haystack_words: list[str]) -> float:
    best = 0.0
    for candidate in haystack_words:
        # A word misspelled from its first letter is past saving here anyway,
        # and skipping those is what keeps this loop off the edit distance.
        if candidate[:1] != word[:1]:
            continue
        best = max(best, _similarity(word, candidate))
        if best == 1.0:
            break
    return best


def _resolve(db: sqlite3.Connection, word: str) -> tuple[list[tuple[str, float, bool]], bool]:
    """Indexed words this typed word could be, scored, and whether it matched
    so much of the oblast that only names are worth walking.

    The third tuple element is True only when the typed word equals the
    indexed word - "Славсько" matching the word "Славсько", not just any
    word that starts with "Славсько". That distinction is what lets a
    single-word area query rank the area itself above every POI whose name
    contains a longer word starting with the same prefix.

    Shortest indexed words first, so the cap keeps what was most likely meant
    rather than an arbitrary slice of the range. Sizes are read before the
    blobs: ordering a range of the vocabulary is cheap, ordering its postings
    is not.
    """
    sized = db.execute(
        "SELECT word, places FROM vocab WHERE word >= ? AND word < ? "
        "ORDER BY length(word) LIMIT ?",
        (word, word + LAST_CHAR, MAX_VOCAB_WORDS)).fetchall()

    matched: list[tuple[str, float, bool]] = []
    places = 0
    for candidate, count in sized:
        places += count
        if places > MAX_REFS:
            return matched, True
        matched.append((candidate, 1.0, candidate == word))

    if places < MIN_CONFIDENT_PLACES and len(word) >= MIN_FUZZY_WORD:
        probe = word[:max(MIN_PROBE, len(word) - PROBE_TRIM)]
        known = {candidate for candidate, _, _ in matched}
        for candidate, in db.execute(
                "SELECT word FROM vocab_fuzzy WHERE word LIKE ?", (f"%{probe}%",)):
            score = _similarity(word, candidate)
            if score >= MIN_WORD_SCORE and candidate not in known:
                matched.append((candidate, score, False))
    return matched, False


def _tally(db: sqlite3.Connection, query_words: list[str]) -> tuple[dict[int, list[float]], dict[int, list[bool]]]:
    """Every place some typed word resolves to, with that word's best score.

    The second return value flags per-place per-word whether the match was an
    exact word match in the place's own name - "Славсько" matching the word
    "Славсько" in a place called Славсько, not "Славського" in some POI's
    name. Counts of true flags over the query words rank a place above
    POIs whose names only start with the same prefix.
    """
    width = len(query_words)
    scores: dict[int, list[float]] = {}
    exact: dict[int, list[bool]] = {}
    for index, word in enumerate(query_words):
        matched, names_only = _resolve(db, word)
        walked = 0
        for candidate, score, is_exact in matched:
            blob, = db.execute("SELECT postings FROM vocab WHERE word = ?",
                               (candidate,)).fetchone()
            for ref in decode(blob):
                named = ref & NAME_BIT
                if names_only and not named:
                    continue
                here = score if named else score - CONTEXT_PENALTY
                place_scores = scores.setdefault(ref >> 1, [0.0] * width)
                place_exact = exact.setdefault(ref >> 1, [False] * width)
                if here > place_scores[index]:
                    place_scores[index] = here
                    place_exact[index] = named and is_exact
            walked += len(blob)
            if walked > MAX_REFS:
                break
    return scores, exact


def _complete(db: sqlite3.Connection, partial: list[tuple[int, list[float]]],
              query_words: list[str], threshold: float) -> list[tuple[int, list[float]]]:
    """Judge the words no indexed word resolved to, by reading the places.

    Best agreement among the other words first: a word the vocabulary failed on
    says nothing about where to look, so the places worth reading are the ones
    some other word already found.
    """
    partial.sort(key=lambda hit: -sum(hit[1]))
    del partial[MAX_INCOMPLETE:]
    if not partial:
        return []

    marks = ",".join("?" * len(partial))
    terms = dict(db.execute(
        f"SELECT rowid, name_terms || ' ' || context_terms FROM places "
        f"WHERE rowid IN ({marks})", [place for place, _ in partial]))

    filled = []
    for place, scores in partial:
        haystack = terms[place].split(" ")
        for index, score in enumerate(scores):
            if score < threshold:
                scores[index] = _word_score(query_words[index], haystack)
        if min(scores) >= threshold:
            filled.append((place, scores))
    return filled


def _distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    mean_lat = math.radians((lat1 + lat2) / 2)
    dx = math.radians(lon2 - lon1) * math.cos(mean_lat)
    dy = math.radians(lat2 - lat1)
    return math.hypot(dx, dy) * EARTH_RADIUS_M


def search(db_path: str, query: str, limit: int = 20,
           threshold: float = MIN_WORD_SCORE,
           origin: tuple[float, float] | None = None) -> list[dict]:
    """Ranked hits, each a dict of score, name, address, matched, lon, lat, metres."""
    query_words = WORD_RE.findall(normalise(query))
    if not query_words:
        return []

    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    scores_by_place, exact_by_place = _tally(db, query_words)
    ranked = [(place, scores_by_place[place]) for place in scores_by_place
              if min(scores_by_place[place]) >= threshold]
    # Every word agreeing straight from the index is the common case and costs
    # nothing. Reading places is only worth it when that came up short, which
    # is where a word is misspelled past anything the vocabulary could match.
    if len(ranked) < limit:
        ranked += _complete(db, [(place, scores_by_place[place])
                                 for place in scores_by_place
                                 if min(scores_by_place[place]) < threshold <= max(scores_by_place[place])],
                            query_words, threshold)
    if not ranked:
        db.close()
        return []

    scored = {place: sum(scores) / len(scores) for place, scores in ranked}
    # Distance can only reorder hits that already scored equally, so it is
    # enough to fetch a few times the asked-for number and sort those.
    best = sorted(scored, key=lambda place: -scored[place])[:limit * 10]
    marks = ",".join("?" * len(best))
    rows = db.execute(
        f"SELECT rowid, display_name, lon, lat, category FROM places "
        f"WHERE rowid IN ({marks})",
        best).fetchall()
    db.close()

    ranked_dict = dict(ranked)
    hits = [{
        "score": scored[place],
        # Number of query words that hit this place as an exact word in its
        # own name. "Славсько" alone makes the town itself rank above every
        # POI whose name only starts with the same prefix.
        "exact_count": sum(exact_by_place.get(place, [False] * len(query_words))),
        # A query for a city that names thousands of streets, shops and bus
        # stops needs the city itself still at the top. exact_count ties them
        # all, so areas (place=*, boundary=administrative) outrank POIs.
        "is_area": _is_area(category),
        "name": _primary_name(display),
        "address": _address_parts(display),
        "matched": [(query_words[i], ranked_dict[place][i])
                    for i in range(len(query_words))],
        "lon": lon,
        "lat": lat,
        "metres": _distance_m(origin[0], origin[1], lat, lon) if origin else None,
    } for place, display, lon, lat, category in rows]
    hits.sort(key=lambda hit: (-hit["exact_count"], -hit["is_area"],
                               -hit["score"], hit["metres"] or 0, hit["name"]))
    return hits[:limit]


def _primary_name(display: str) -> str:
    """The place's name alone, without the comma-separated context after it."""
    bracket = display.find(" (")
    return display if bracket < 0 else display[:bracket]


def _is_area(category: str) -> bool:
    return category.startswith("place=") or category.startswith("boundary=administrative")


def _address_parts(display: str) -> list[str]:
    """The context inside the brackets, split on commas."""
    bracket = display.find(" (")
    if bracket < 0:
        return []
    inner = display[bracket + 2:-1]
    return [part.strip() for part in inner.split(",") if part.strip()]
