#!/usr/bin/env python3
"""Did the French/English fine-tune help, do nothing, or hurt the other languages?

The shipped model is stock Parakeet TDT v3 plus a delta trained only on French
and English. It loses FLEURS in all eight languages and MLS in most, while
winning the other three corpora everywhere. One explanation is that the delta
degraded the six languages it never saw — catastrophic forgetting — and that
would make the fix free: ship the stock weights for those languages.

Both runtimes are exported from the same base by the same script, quantised the
same way, and run on the same compute units, so the only variable between the
two columns is the training. A per-language and per-corpus split says whether
the delta is a net gain, a wash, or a regression outside its training
languages.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

TRAINED = {"fr", "en"}


def wer(path: Path) -> float | None:
    if not path.exists():
        return None
    counts = json.loads(path.read_text())["finalClean"]["wordErrors"]
    total = counts["substitutions"] + counts["deletions"] + counts["insertions"]
    return 100 * total / counts["referenceUnitCount"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument(
        "--tuned",
        default="int8gpu",
        help="Label of the fine-tuned run. Defaults to the GPU baseline so the "
        "comparison holds the compute unit fixed as well as the export path.",
    )
    parser.add_argument("--stock", default="stock")
    arguments = parser.parse_args()

    rows = []
    for directory in sorted((arguments.root / "benchmarks").iterdir()):
        if directory.name.startswith("."):
            continue
        tuned = wer(directory / f"{arguments.tuned}-report.json")
        stock = wer(directory / f"{arguments.stock}-report.json")
        if tuned is None or stock is None:
            continue
        corpus, _, language = directory.name.rpartition("-")
        rows.append(
            {
                "name": directory.name,
                "corpus": corpus,
                "language": language,
                "tuned": tuned,
                "stock": stock,
                "delta": tuned - stock,
            }
        )

    if not rows:
        raise SystemExit("No benchmark has both runs scored yet.")

    print(f"{len(rows)} benchmarks compares  (negatif = le fine-tune aide)\n")
    print(f"{'benchmark':18s} {'fine-tune':>10s} {'stock':>8s} {'ecart':>8s}")
    for row in rows:
        marker = " *" if row["language"] in TRAINED else ""
        print(
            f"{row['name']:18s} {row['tuned']:9.2f}% {row['stock']:7.2f}% "
            f"{row['delta']:+7.2f}{marker}"
        )

    def summarise(label: str, subset: list[dict]) -> None:
        if not subset:
            return
        mean = sum(row["delta"] for row in subset) / len(subset)
        worse = sum(1 for row in subset if row["delta"] > 0.05)
        better = sum(1 for row in subset if row["delta"] < -0.05)
        print(
            f"  {label:34s} n={len(subset):2d}  ecart moyen {mean:+6.3f}  "
            f"le fine-tune aide {better}, nuit {worse}"
        )

    print("\n=== bilan ===")
    summarise(
        "langues entrainees (fr, en)",
        [row for row in rows if row["language"] in TRAINED],
    )
    summarise(
        "langues jamais vues",
        [row for row in rows if row["language"] not in TRAINED],
    )
    for corpus in sorted({row["corpus"] for row in rows}):
        summarise(corpus, [row for row in rows if row["corpus"] == corpus])
    return 0


if __name__ == "__main__":
    sys.exit(main())
