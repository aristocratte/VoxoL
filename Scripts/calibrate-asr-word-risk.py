#!/usr/bin/env python3
"""Fit a monotonic word-error probability table from reviewed Parakeet words."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass
class Block:
    margins: list[float]
    errors: int
    count: int

    @property
    def probability(self) -> float:
        return self.errors / self.count


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Calibrate P(word incorrect) from minimum decoder margin."
    )
    parser.add_argument("--input", type=Path, required=True, help="Reviewed JSONL words")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--language", choices=("all", "fr", "en"), default="all")
    parser.add_argument("--minimum-rows", type=int, default=20)
    return parser.parse_args()


def load_rows(path: Path, language: str = "all") -> list[dict[str, object]]:
    rows = [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    required = {"surface", "correct", "minimum_margin", "language"}
    for index, row in enumerate(rows, start=1):
        missing = required - row.keys()
        if missing:
            raise ValueError(f"row {index} is missing: {', '.join(sorted(missing))}")
        if not isinstance(row["correct"], bool):
            raise ValueError(f"row {index} correct must be a boolean")
    if language != "all":
        rows = [row for row in rows if row["language"] == language]
    return rows


def fit_isotonic(rows: Iterable[dict[str, object]]) -> list[dict[str, float]]:
    grouped: dict[float, list[int]] = {}
    for row in rows:
        margin = float(row["minimum_margin"])
        grouped.setdefault(margin, []).append(0 if bool(row["correct"]) else 1)

    blocks: list[Block] = []
    for margin, labels in sorted(grouped.items()):
        blocks.append(Block([margin], sum(labels), len(labels)))
        # More margin may not imply more error. Pool adjacent violations until
        # probabilities are monotonically non-increasing.
        while len(blocks) >= 2 and blocks[-2].probability < blocks[-1].probability:
            right = blocks.pop()
            left = blocks.pop()
            blocks.append(
                Block(
                    margins=left.margins + right.margins,
                    errors=left.errors + right.errors,
                    count=left.count + right.count,
                )
            )

    fitted: list[dict[str, float]] = []
    for block in blocks:
        for margin in block.margins:
            fitted.append(
                {
                    "margin": margin,
                    "errorProbability": block.probability,
                }
            )
    return fitted


def build_report(rows: list[dict[str, object]]) -> dict[str, object]:
    labels = [not bool(row["correct"]) for row in rows]
    return {
        "schemaVersion": 1,
        "method": "isotonic-pav",
        "target": "word-incorrect",
        "feature": "minimumLogitMargin",
        "rowCount": len(rows),
        "errorCount": sum(labels),
        "languageCounts": dict(sorted(Counter(str(row["language"]) for row in rows).items())),
        "knots": fit_isotonic(rows),
    }


def main() -> None:
    args = parse_args()
    rows = load_rows(args.input, language=args.language)
    if len(rows) < args.minimum_rows:
        raise ValueError(
            f"need at least {args.minimum_rows} reviewed words, found {len(rows)}"
        )
    if len({bool(row["correct"]) for row in rows}) != 2:
        raise ValueError("calibration requires both correct and incorrect reviewed words")
    report = build_report(rows)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(args.output)


if __name__ == "__main__":
    main()
