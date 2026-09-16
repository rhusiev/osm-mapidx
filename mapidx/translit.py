"""Cyrillic -> Latin romanisation for Ukrainian place names.

Two schemes are produced per name. `kmu` follows the official Ukrainian
transliteration (Cabinet of Ministers resolution 55, 2010), which is what
appears on road signs and passports. `naive` follows how people actually type
Latin-script Ukrainian in a search box, which often disagrees with the standard
(г as g rather than h, ц as c rather than ts).
"""

import unicodedata

_KMU_BASE = {
    "а": "a", "б": "b", "в": "v", "г": "h", "ґ": "g", "д": "d", "е": "e",
    "ж": "zh", "з": "z", "и": "y", "і": "i", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
    "ь": "", "'": "", "’": "", "ʼ": "",
    # Russian letters that still occur in Ukrainian OSM data
    "ы": "y", "э": "e", "ъ": "", "ё": "e",
}

# These depend on whether the letter starts a word.
_KMU_POSITIONAL = {
    "є": ("ye", "ie"), "ї": ("yi", "i"), "й": ("y", "i"),
    "ю": ("yu", "iu"), "я": ("ya", "ia"),
}

_NAIVE = _KMU_BASE | {
    "г": "g", "и": "i", "х": "h", "ц": "c", "щ": "sch",
    "є": "ye", "ї": "i", "й": "y", "ю": "yu", "я": "ya",
}


def _is_word_start(text: str, i: int) -> bool:
    return i == 0 or not text[i - 1].isalpha()


def romanise_kmu(text: str) -> str:
    out: list[str] = []
    i = 0
    lowered = text.lower()
    while i < len(lowered):
        ch = lowered[i]
        # зг -> zgh, so that it stays distinct from ж -> zh
        if ch == "з" and lowered[i + 1:i + 2] == "г":
            out.append("zgh")
            i += 2
            continue
        if ch in _KMU_POSITIONAL:
            initial, medial = _KMU_POSITIONAL[ch]
            out.append(initial if _is_word_start(lowered, i) else medial)
        else:
            out.append(_KMU_BASE.get(ch, ch))
        i += 1
    return "".join(out)


def romanise_naive(text: str) -> str:
    return "".join(_NAIVE.get(ch, ch) for ch in text.lower())


def is_cyrillic(text: str) -> bool:
    return any("Ѐ" <= ch <= "ӿ" for ch in text)


def romanisations(text: str) -> list[tuple[str, str]]:
    """Return (scheme, romanised) pairs, deduplicated, for a Cyrillic name."""
    if not is_cyrillic(text):
        return []
    seen: dict[str, str] = {}
    for scheme, fn in (("translit_kmu", romanise_kmu), ("translit_naive", romanise_naive)):
        value = fn(text).strip()
        if value and value.lower() != text.lower():
            seen.setdefault(value, scheme)
    return [(scheme, value) for value, scheme in seen.items()]


def normalise(text: str) -> str:
    """Fold case and drop accents so Cyrillic compares like ASCII does.

    SQLite's LIKE only case-folds ASCII, so both sides of a comparison must be
    normalised in Python before they reach the database. The accents go with
    the case: й, ї and ё are held apart from и, і and е by one combining mark,
    which is exactly the kind of difference a typo is.

    Python's NFKD decomposition handles Cyrillic from Unicode 15 onwards (й
    decomposes to U+0438 and U+0306, the breve), so the only step after that
    is dropping the combining mark. The Dart side has to do the same folding
    by hand because there is no NFKD in Dart's stdlib - the `_folded` map in
    `app/lib/src/text.dart` mirrors this NFKD result.
    """
    decomposed = unicodedata.normalize("NFKD", text.casefold())
    return "".join(ch for ch in decomposed if not unicodedata.combining(ch))


def romanise_context(text: str) -> list[str]:
    """Latin renderings of a context string, for matching Latin-typed queries."""
    return [value for _, value in romanisations(text)]
