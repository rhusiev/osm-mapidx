"""The word index both the CLI and the phone app search.

A query has to be answered while someone is still typing it, so the unit of
matching is the word, not the row. Every distinct word in the place table -
name words, context words and their romanisations - gets one `vocab` row whose
blob lists the places it occurs in. A prefix is then a B-tree range scan over
114k words rather than a scan of 118k rows, and a typo is a trigram lookup over
those same words, which is the only place small enough for edit distance to be
affordable.
"""

from __future__ import annotations

import re

WORD_RE = re.compile(r"\w+", re.UNICODE)

# A place occurs in a word's postings as `place_id << 1 | from_name`, so the
# ranker can prefer "Медовий" the name over "Медовий" somewhere in a context.
NAME_BIT = 1


def words(text: str) -> set[str]:
    return set(WORD_RE.findall(text))


def encode(refs: list[int]) -> bytes:
    """Ascending refs as LEB128 deltas: 4M postings fit in about 6 MB."""
    out = bytearray()
    previous = 0
    for ref in refs:
        delta = ref - previous
        previous = ref
        while delta >= 0x80:
            out.append((delta & 0x7F) | 0x80)
            delta >>= 7
        out.append(delta)
    return bytes(out)


def decode(blob: bytes) -> list[int]:
    refs = []
    ref = shift = delta = 0
    for byte in blob:
        delta |= (byte & 0x7F) << shift
        if byte & 0x80:
            shift += 7
            continue
        ref += delta
        refs.append(ref)
        shift = delta = 0
    return refs
