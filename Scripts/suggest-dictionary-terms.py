#!/usr/bin/env python3
"""Derive dictionary entries from the corrections the owner actually made.

The decoder already substitutes a spoken form for a canonical one — `chip set`
becomes `chipset`, `élite` becomes `edited` — but only for entries someone
typed into the dictionary by hand, and an empty dictionary was exactly the
state that made real dictation unusable while every public benchmark said the
model was excellent.

The corrections captured by the app are that data, already collected. Each
session holds what was inserted and what the owner rewrote it to; aligning the
two word by word says which word the recogniser produced and which word was
meant. That is a spoken form and a canonical, in the dictionary's own terms.

Two things keep this from filling the dictionary with noise:

- a pair must appear in at least two separate sessions, so a one-off typo or a
  changed mind never becomes a permanent rewrite rule;
- the two words must be close enough to be a mishearing rather than an edit —
  rewriting `budget` to `planning` is the owner changing their text, not the
  recogniser getting it wrong, and turning that into a substitution rule would
  corrupt every later dictation.

Output is printed for review and written as JSON. Nothing is installed
automatically: a rewrite rule that fires on every future dictation deserves a
human look.
"""

from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path
import re
import sys
import unicodedata

WORD = re.compile(r"[^\W\d_]+(?:[''-][^\W\d_]+)*", re.UNICODE)
MINIMUM_SESSIONS = 2
MAXIMUM_DISTANCE = 0.5


def words(text: str) -> list[str]:
    return WORD.findall(text.replace("'", "'"))


def folded(word: str) -> str:
    return "".join(
        c
        for c in unicodedata.normalize("NFD", word.casefold())
        if not unicodedata.combining(c)
    )


def distance(left: str, right: str) -> int:
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        current = [i]
        for j, b in enumerate(right, 1):
            current.append(
                min(previous[j - 1] + (a != b), previous[j] + 1, current[j - 1] + 1)
            )
        previous = current
    return previous[-1]


def merges(source: list[str], target: list[str]) -> list[tuple[str, str]]:
    """Pairs where a word was split in two, or two were run together.

    `chipset` heard as `chip set` is the error that motivated all of this, and
    a word-to-word alignment cannot see it: two source words against one target
    word is a deletion plus a substitution, which the caller discards. Detected
    directly instead, in both directions.
    """
    pairs = []
    folded_target = [folded(word) for word in target]
    folded_source = [folded(word) for word in source]
    for index in range(len(source) - 1):
        joined = folded_source[index] + folded_source[index + 1]
        if joined and joined in folded_target:
            pairs.append((f"{source[index]} {source[index + 1]}",
                          target[folded_target.index(joined)]))
    for index in range(len(target) - 1):
        joined = folded_target[index] + folded_target[index + 1]
        if joined and joined in folded_source:
            pairs.append((source[folded_source.index(joined)],
                          f"{target[index]} {target[index + 1]}"))
    return pairs


def align(source: list[str], target: list[str]) -> list[tuple[str, str]]:
    """Substitution pairs only: insertions and deletions are edits, not errors."""
    rows, columns = len(source) + 1, len(target) + 1
    cost = [[0] * columns for _ in range(rows)]
    for i in range(rows):
        cost[i][0] = i
    for j in range(columns):
        cost[0][j] = j
    for i in range(1, rows):
        for j in range(1, columns):
            cost[i][j] = min(
                cost[i - 1][j - 1] + (folded(source[i - 1]) != folded(target[j - 1])),
                cost[i - 1][j] + 1,
                cost[i][j - 1] + 1,
            )
    pairs = []
    i, j = len(source), len(target)
    while i > 0 and j > 0:
        substitution = cost[i - 1][j - 1] + (
            folded(source[i - 1]) != folded(target[j - 1])
        )
        if cost[i][j] == substitution:
            if folded(source[i - 1]) != folded(target[j - 1]):
                pairs.append((source[i - 1], target[j - 1]))
            i, j = i - 1, j - 1
        elif cost[i][j] == cost[i - 1][j] + 1:
            i -= 1
        else:
            j -= 1
    return pairs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.home()
        / "Library/Application Support/VoxoL/PersonalBenchmark",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--minimum-sessions", type=int, default=MINIMUM_SESSIONS
    )
    arguments = parser.parse_args()

    sessions = sorted((arguments.root / "sessions").glob("*/meta.json"))
    if not sessions:
        print(
            "Aucune session capturée.\n"
            "Active « Personal benchmark capture », dicte, corrige les "
            "corrected.txt fautifs, puis relance."
        )
        return 0

    # A pair is keyed on its folded forms so accents and casing do not split
    # the same mistake into several near-identical candidates.
    counts: dict[tuple[str, str], set[str]] = collections.defaultdict(set)
    surfaces: dict[tuple[str, str], tuple[str, str]] = {}
    languages: dict[tuple[str, str], str] = {}
    reviewed = 0

    for meta_path in sessions:
        directory = meta_path.parent
        corrected_path = directory / "corrected.txt"
        if not corrected_path.is_file():
            continue
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        inserted = (meta.get("finalText") or "").strip()
        corrected = corrected_path.read_text(encoding="utf-8").strip()
        if not inserted or not corrected or inserted == corrected:
            continue
        reviewed += 1
        inserted_words, corrected_words = words(inserted), words(corrected)
        found = align(inserted_words, corrected_words) + merges(
            inserted_words, corrected_words
        )
        for heard, meant in found:
            key = (folded(heard), folded(meant))
            if not key[0] or not key[1]:
                continue
            counts[key].add(directory.name)
            surfaces.setdefault(key, (heard, meant))
            languages.setdefault(key, meta.get("language", "auto"))

    suggestions = []
    for key, session_ids in counts.items():
        if len(session_ids) < arguments.minimum_sessions:
            continue
        heard, meant = surfaces[key]
        # Spaces are what a split error adds; comparing without them keeps
        # `chip set` -> `chipset` at distance zero instead of rejecting it.
        left, right = key[0].replace(" ", ""), key[1].replace(" ", "")
        normalised = distance(left, right) / max(len(right), 1)
        if normalised > MAXIMUM_DISTANCE:
            continue
        suggestions.append(
            {
                "canonical": meant,
                "spokenForms": [heard],
                "language": languages[key],
                "sessions": len(session_ids),
                "distance": round(normalised, 3),
            }
        )
    suggestions.sort(key=lambda s: (-s["sessions"], s["distance"]))

    print(
        f"{len(sessions)} sessions, {reviewed} corrigées, "
        f"{len(suggestions)} entrée(s) proposée(s) "
        f"(vues dans ≥ {arguments.minimum_sessions} sessions)"
    )
    for suggestion in suggestions:
        print(
            f"  {suggestion['spokenForms'][0]:24s} -> {suggestion['canonical']:24s}"
            f"  {suggestion['sessions']} sessions"
        )
    if not suggestions and reviewed:
        print(
            "  Rien d'assez répété pour l'instant — une correction isolée ne "
            "devient pas une règle permanente."
        )

    if arguments.output:
        arguments.output.write_text(
            json.dumps(suggestions, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"\n{arguments.output}")
        print(
            "À relire avant import : chaque entrée réécrit toutes les dictées "
            "futures."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
