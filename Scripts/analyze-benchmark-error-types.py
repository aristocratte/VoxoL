#!/usr/bin/env python3
"""Name the words one system gets wrong that the other gets right.

Caveat worth reading before the numbers: on a corpus whose reference is
lower-cased throughout — MLS and FLEURS both are — proper nouns cannot be
detected by casing and are counted under ordinary words. The category totals
are therefore a lower bound on names, not a partition.

The score tables say VoxoL loses FLEURS and MLS. They do not say what it loses
them on, and the answer decides the remedy: a system that misses proper nouns
needs vocabulary, one that mangles compounds needs different training text, one
that drops diacritics has a tokenizer problem, and one that simply hears the
wrong common word needs more audio.

Only clips where the two systems disagree are examined, because a word both get
wrong says nothing about the difference between them.
"""

from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path
import re
import sys
import unicodedata

WORD = re.compile(r"[^\W\d_]+", re.UNICODE)


def normalize(text: str) -> list[str]:
    lowered = (
        text.replace("’", "'")
        .replace("‘", "'")
        .lower()
    )
    return WORD.findall(lowered)


def align(reference: list[str], hypothesis: list[str]) -> list[tuple]:
    """Levenshtein backtrace, so a miss can be attributed to a reference word."""
    rows, columns = len(reference) + 1, len(hypothesis) + 1
    cost = [[0] * columns for _ in range(rows)]
    for i in range(rows):
        cost[i][0] = i
    for j in range(columns):
        cost[0][j] = j
    for i in range(1, rows):
        for j in range(1, columns):
            if reference[i - 1] == hypothesis[j - 1]:
                cost[i][j] = cost[i - 1][j - 1]
            else:
                cost[i][j] = 1 + min(
                    cost[i - 1][j - 1], cost[i - 1][j], cost[i][j - 1]
                )
    operations = []
    i, j = len(reference), len(hypothesis)
    while i > 0 or j > 0:
        if i > 0 and j > 0 and reference[i - 1] == hypothesis[j - 1]:
            operations.append(("ok", reference[i - 1], hypothesis[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and j > 0 and cost[i][j] == cost[i - 1][j - 1] + 1:
            operations.append(("sub", reference[i - 1], hypothesis[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and cost[i][j] == cost[i - 1][j] + 1:
            operations.append(("del", reference[i - 1], ""))
            i -= 1
        else:
            operations.append(("ins", "", hypothesis[j - 1]))
            j -= 1
    return list(reversed(operations))


def has_diacritic(word: str) -> bool:
    return any(unicodedata.combining(c) for c in unicodedata.normalize("NFD", word))


def classify(reference_word: str, hypothesis_word: str, cased: str) -> str:
    if not reference_word:
        return "insertion"
    if not hypothesis_word:
        return "omission"
    if cased and cased[:1].isupper():
        return "nom propre / majuscule"
    # MLS and FLEURS publish their references entirely in lower case, so on
    # those corpora there is no case signal at all and proper nouns land in
    # whichever category their spelling puts them in. Read the counts below as
    # "of the errors that are not obviously X", not as a complete taxonomy.
    stripped = "".join(
        c
        for c in unicodedata.normalize("NFD", reference_word)
        if not unicodedata.combining(c)
    )
    other = "".join(
        c
        for c in unicodedata.normalize("NFD", hypothesis_word)
        if not unicodedata.combining(c)
    )
    if stripped == other and has_diacritic(reference_word) != has_diacritic(
        hypothesis_word
    ):
        return "diacritique"
    if len(reference_word) >= 12:
        return "mot long / compose"
    if reference_word[:4] == hypothesis_word[:4]:
        return "flexion / terminaison"
    return "mot courant confondu"


def load(path: Path, key: str) -> dict[str, str]:
    return {
        json.loads(line)["id"]: json.loads(line)[key]
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--benchmark", action="append", required=True)
    parser.add_argument("--examples", type=int, default=6)
    arguments = parser.parse_args()

    for name in arguments.benchmark:
        directory = arguments.root / "benchmarks" / name
        manifest = directory / "manifest-numeric-frozen.json"
        if not manifest.is_file():
            print(f"{name}: absent")
            continue
        references = {
            item["id"]: item["reference"]["clean"]
            for item in json.loads(manifest.read_text())["items"]
        }
        voxol = load(directory / "voxol-numeric-predictions.jsonl", "finalText")
        wispr = load(directory / "wispr-numeric-predictions.jsonl", "finalText")

        kinds = collections.Counter()
        samples: dict[str, list[tuple[str, str]]] = collections.defaultdict(list)
        exclusive = 0
        for identifier, reference in references.items():
            cased_words = WORD.findall(reference)
            words = normalize(reference)
            ours = align(words, normalize(voxol.get(identifier, "")))
            theirs = align(words, normalize(wispr.get(identifier, "")))
            # Which reference positions did Wispr get right?
            their_ok = set()
            position = 0
            for operation, reference_word, _ in theirs:
                if operation in ("ok", "sub", "del"):
                    if operation == "ok":
                        their_ok.add(position)
                    position += 1
            position = 0
            for operation, reference_word, hypothesis_word in ours:
                if operation == "ins":
                    continue
                if operation != "ok" and position in their_ok:
                    exclusive += 1
                    cased = (
                        cased_words[position] if position < len(cased_words) else ""
                    )
                    kind = classify(reference_word, hypothesis_word, cased)
                    kinds[kind] += 1
                    if len(samples[kind]) < arguments.examples:
                        samples[kind].append((reference_word, hypothesis_word))
                position += 1

        print(f"\n### {name} — {exclusive} mots ratés par VoxoL et réussis par Wispr")
        for kind, count in kinds.most_common():
            share = 100 * count / exclusive if exclusive else 0
            pairs = ", ".join(
                f"{a}→{b or '∅'}" for a, b in samples[kind][: arguments.examples]
            )
            print(f"  {share:5.1f}%  {kind:24s} {pairs}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
