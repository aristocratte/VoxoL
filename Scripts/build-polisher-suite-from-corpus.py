#!/usr/bin/env python3
"""Turn the diagnostic AI-labeled corpus into a polisher evaluation suite.

`Data/corpus/human-v1.jsonl` holds raw transcripts paired with targets a human
reviewed but did not independently author. This writes them in the shape
`VoxoL --polisher-smoke --suite` reads, one case per pair, carrying the pair's
mode and writing profile so each target is judged under the contract it was
written for.

The suite is local evidence, never a promise: the report it produces compares
the shipped model against the same people who dictated, on their own words.

    python3 Scripts/build-polisher-suite-from-corpus.py \
        --corpus Data/corpus/human-v1.jsonl \
        --output .build/polisher-suite-human-v1.json
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

SUPPORTED_LANGUAGES = {"fr", "en"}


def build_cases(corpus: Path) -> list[dict[str, str]]:
    cases: list[dict[str, str]] = []
    with corpus.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("language") not in SUPPORTED_LANGUAGES:
                continue
            if not row.get("approved", True):
                continue
            cases.append(
                {
                    "id": row["id"],
                    "language": row["language"],
                    "transcript": row["raw_transcript"],
                    "expected": row["target_text"],
                    "mode": row.get("mode", "faithful"),
                    "profile": row.get("profile", "automatic"),
                }
            )
    return cases


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=Path("Data/corpus/human-v1.jsonl"))
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    cases = build_cases(arguments.corpus)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with arguments.output.open("w", encoding="utf-8") as handle:
        json.dump(
            {
                "role": "diagnostic-ai-labeled-v1",
                "promotionEligible": False,
                "languages": sorted(SUPPORTED_LANGUAGES),
                "cases": cases,
            },
            handle,
            ensure_ascii=False,
            indent=1,
        )
        handle.write("\n")
    print(f"{len(cases)} cases written to {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
