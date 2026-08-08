#!/usr/bin/env python3
"""Does the corpus effect survive matching on how hard the clips are?

The claim withdrawn from the diagnosis was that the deficit follows a speaking
style. An audit pointed out that each "domain" rests on a single corpus, so the
effect is indistinguishable from anything else that differs between those
corpora — text difficulty, proper-noun density, how badly the tokenizer splits
the words, clip length.

This holds language fixed and compares two corpora clip by clip, stratified on
difficulty proxies computed from the reference alone. If the gap between the two
systems survives inside every stratum, the corpus is carrying something the
proxies do not explain. If it collapses, "domain" was a label for lexical
difficulty and the framing was wrong twice over.

Difficulty is measured from the reference, never from either system's output, so
the strata cannot be contaminated by the thing being measured.
"""

from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path
import re
import statistics
import sys

WORD = re.compile(r"[^\W\d_]+", re.UNICODE)


def load(directory: Path, tokenizer) -> list[dict]:
    manifest = directory / "manifest-numeric-frozen.json"
    if not manifest.is_file():
        return []
    items = json.loads(manifest.read_text())["items"]

    def counts(name: str) -> dict[str, tuple[float, float]]:
        path = directory / f"{name}-numeric-items.jsonl"
        result = {}
        if not path.is_file():
            return result
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            errors = row["finalWordErrors"]
            result[row["id"]] = (
                errors["substitutions"] + errors["deletions"] + errors["insertions"],
                errors["referenceUnitCount"],
            )
        return result

    ours, theirs = counts("voxol"), counts("wispr")
    rows = []
    for item in items:
        identifier = item["id"]
        if identifier not in ours or identifier not in theirs:
            continue
        reference = item["reference"]["clean"]
        words = WORD.findall(reference)
        if not words:
            continue
        pieces = len(tokenizer.encode(reference, add_special_tokens=False).ids)
        rows.append(
            {
                "id": identifier,
                # Subword pieces per word: the tokenizer's own measure of how
                # unusual the vocabulary is, and the one the audit singled out.
                "fragmentation": pieces / len(words),
                "words": len(words),
                "ours": ours[identifier],
                "theirs": theirs[identifier],
            }
        )
    return rows


def gap(rows: list[dict]) -> float:
    ours = sum(r["ours"][0] for r in rows) / max(sum(r["ours"][1] for r in rows), 1)
    theirs = sum(r["theirs"][0] for r in rows) / max(
        sum(r["theirs"][1] for r in rows), 1
    )
    return 100 * (ours - theirs)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("/Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual"),
    )
    parser.add_argument("--language", default="fr")
    parser.add_argument("--corpora", nargs=2, default=["fleurs", "commonvoice"])
    parser.add_argument("--strata", type=int, default=4)
    arguments = parser.parse_args()

    from tokenizers import Tokenizer

    tokenizer = Tokenizer.from_file(
        str(
            Path.home()
            / "Library/Application Support/VoxoL/Models/asr"
            / "7c35754d166cca382ad1e53e68b01e7c575f3a1d/tokenizer.json"
        )
    )

    sets = {}
    for corpus in arguments.corpora:
        directory = arguments.root / "benchmarks" / f"{corpus}-{arguments.language}"
        sets[corpus] = load(directory, tokenizer)
        if not sets[corpus]:
            raise SystemExit(f"nothing scored for {directory.name}")

    print(f"langue {arguments.language} — {arguments.corpora[0]} contre {arguments.corpora[1]}\n")
    for corpus, rows in sets.items():
        print(
            f"  {corpus:12s} {len(rows):4d} clips  "
            f"fragmentation mediane {statistics.median(r['fragmentation'] for r in rows):.2f}  "
            f"mots/clip {statistics.median(r['words'] for r in rows):.0f}  "
            f"ecart global {gap(rows):+.2f}"
        )

    # Common quantile edges so the same difficulty means the same stratum in
    # both corpora.
    everything = sorted(
        r["fragmentation"] for rows in sets.values() for r in rows
    )
    edges = [
        everything[int(len(everything) * k / arguments.strata)]
        for k in range(1, arguments.strata)
    ]

    def stratum(value: float) -> int:
        for index, edge in enumerate(edges):
            if value < edge:
                return index
        return len(edges)

    print(f"\n{'strate de fragmentation':28s} " + "  ".join(f"{c:>14s}" for c in arguments.corpora))
    survives = 0
    compared = 0
    for index in range(arguments.strata):
        low = "-inf" if index == 0 else f"{edges[index-1]:.2f}"
        high = "+inf" if index == len(edges) else f"{edges[index]:.2f}"
        cells = []
        gaps = []
        for corpus in arguments.corpora:
            rows = [r for r in sets[corpus] if stratum(r["fragmentation"]) == index]
            if len(rows) < 20:
                cells.append(f"{len(rows):3d} clips   n/a")
                gaps.append(None)
                continue
            value = gap(rows)
            gaps.append(value)
            cells.append(f"{len(rows):3d} clips {value:+6.2f}")
        print(f"  [{low:>6s}, {high:>6s})            " + "  ".join(f"{c:>14s}" for c in cells))
        if all(g is not None for g in gaps):
            compared += 1
            if gaps[0] - gaps[1] > 0.5:
                survives += 1

    print(
        f"\n  strates comparables : {compared}, "
        f"dont {survives} ou {arguments.corpora[0]} reste nettement pire "
        f"(> 0.5 point)"
    )
    if compared and survives == compared:
        print("  -> l ecart survit a l appariement : le corpus porte autre chose")
    elif survives == 0:
        print("  -> l ecart disparait : c etait la difficulte lexicale, pas le corpus")
    else:
        print("  -> resultat mixte : ni pleinement explique, ni pleinement confirme")
    return 0


if __name__ == "__main__":
    sys.exit(main())
