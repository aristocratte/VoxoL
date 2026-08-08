#!/usr/bin/env python3
"""Give every benchmark item a prediction, so a failure is scored as a failure.

The scorer refuses to score a benchmark with a missing prediction, which leaves
two bad options when a system returns nothing for a clip: drop the clip, which
quietly rewards whichever system failed, or abandon the benchmark. This fills
the gaps with an empty transcript instead. An empty hypothesis scores as a full
deletion, which is exactly what the user experienced.

The count of filled items is printed and belongs in the published report next
to the word error rate: a system that wins on WER while silently returning
nothing 5% of the time has not won.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

EMPTY_CONFIDENCE = {
    "blankDecisionRatio": 0.0,
    "emittedTokenCount": 0,
    "inferenceAttemptCount": 1,
    "lowerDecileDurationLogitMargin": 0.0,
    "lowerDecileTokenLogitMargin": 0.0,
    "maximumFramesWithoutEmission": 0,
    "meanDurationLogitMargin": 0.0,
    "meanTokenLogitMargin": 0.0,
    "usedFallbackSegmentation": False,
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--coverage", type=Path, help="Where to write the coverage JSON.")
    arguments = parser.parse_args()

    identifiers = [
        item["id"] for item in json.loads(arguments.manifest.read_text())["items"]
    ]
    rows = []
    present = set()
    if arguments.predictions.exists():
        for line in arguments.predictions.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            # A row whose text is blank is a failure that already happened; it
            # stays, and it counts as missing for the coverage figure.
            rows.append(row)
            if str(row.get("rawText") or "").strip():
                present.add(row["id"])

    known = {row["id"] for row in rows}
    missing = [identifier for identifier in identifiers if identifier not in known]
    for identifier in missing:
        rows.append(
            {
                "id": identifier,
                "rawText": "",
                "finalText": "",
                "confidence": EMPTY_CONFIDENCE,
                "inferenceMilliseconds": 0,
            }
        )

    arguments.predictions.write_text(
        "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows),
        encoding="utf-8",
    )

    coverage = {
        "itemCount": len(identifiers),
        "transcribedCount": len(present),
        "emptyCount": len(identifiers) - len(present),
        "coverage": len(present) / len(identifiers) if identifiers else 0.0,
    }
    if arguments.coverage:
        arguments.coverage.write_text(json.dumps(coverage, indent=2) + "\n")
    print(
        f"coverage {coverage['transcribedCount']}/{coverage['itemCount']} "
        f"({100 * coverage['coverage']:.1f}%), filled {len(missing)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
