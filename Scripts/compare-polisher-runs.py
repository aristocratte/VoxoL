#!/usr/bin/env python3
"""Compare local VoxoL polisher runs without printing dictated text.

These are latency and output-parity checks, NOT independent quality scores.
Match by unique case ID, not array order; report failures and fallbacks rather
than silently removing slow or unsuccessful cases from the headline numbers.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path
from typing import Any


def read_run(path: Path) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    rows = payload.get("results")
    if not isinstance(rows, list) or not rows:
        raise ValueError(f"{path}: expected nonempty results array")
    indexed = {}
    for row in rows:
        identifier = row.get("id")
        duration = row.get("durationMilliseconds")
        if not isinstance(identifier, str) or not identifier or identifier in indexed:
            raise ValueError(f"{path}: missing or duplicate case ID")
        if not isinstance(duration, (int, float)) or not math.isfinite(duration) or duration < 0:
            raise ValueError(f"{path}: invalid duration for {identifier}")
        if not all(isinstance(row.get(key), str) for key in ("candidate", "finalText")):
            raise ValueError(f"{path}: missing text for {identifier}")
        indexed[identifier] = row
    return payload, indexed


def duration_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    values = sorted(float(row["durationMilliseconds"]) for row in rows)
    if not values:
        return {"count": 0, "meanMs": None, "medianMs": None, "p95Ms": None}
    return {
        "count": len(values),
        "meanMs": statistics.mean(values),
        "medianMs": statistics.median(values),
        "p95Ms": values[math.ceil(0.95 * len(values)) - 1],
        "maximumMs": values[-1],
        "failures": sum(bool(row.get("failure")) for row in rows),
        "accepted": sum(row.get("accepted") is True for row in rows),
    }


def compare_runs(baseline: Path, candidate: Path) -> dict[str, Any]:
    before_payload, before = read_run(baseline)
    after_payload, after = read_run(candidate)
    if before.keys() != after.keys():
        raise ValueError("Case sets differ; refuse a misleading unpaired comparison")
    identifiers = sorted(before)
    differences = []
    for identifier in identifiers:
        a, b = before[identifier], after[identifier]
        raw_equal = a["candidate"] == b["candidate"]
        final_equal = a["finalText"] == b["finalText"]
        if not raw_equal or not final_equal or a.get("failure") != b.get("failure"):
            differences.append({
                "id": identifier,
                "sameRawText": raw_equal,
                "sameFinalText": final_equal,
                "baselineAccepted": a.get("accepted"),
                "candidateAccepted": b.get("accepted"),
                "baselineOutputTokens": a.get("outputTokens"),
                "candidateOutputTokens": b.get("outputTokens"),
                "baselineFailure": a.get("failure"),
                "candidateFailure": b.get("failure"),
            })
    complete = [key for key in identifiers if not before[key].get("failure")
                and not after[key].get("failure")]
    return {
        "schemaVersion": 1,
        "interpretation": "Local performance and literal output parity; not a semantic quality benchmark.",
        "percentileConvention": "Median: midpoint; p95: nearest rank, including runtime failures.",
        "baselineSHA256": hashlib.sha256(baseline.read_bytes()).hexdigest(),
        "candidateSHA256": hashlib.sha256(candidate.read_bytes()).hexdigest(),
        "caseCount": len(identifiers),
        "rawTextDifferences": sum(not row["sameRawText"] for row in differences),
        "finalTextDifferences": sum(not row["sameFinalText"] for row in differences),
        "acceptedToRejected": sum(before[key].get("accepted") is True
                                  and after[key].get("accepted") is False for key in identifiers),
        "allCases": {
            "baseline": duration_summary(list(before.values())),
            "candidate": duration_summary(list(after.values())),
        },
        "bothCompleted": {
            "baseline": duration_summary([before[key] for key in complete]),
            "candidate": duration_summary([after[key] for key in complete]),
        },
        "baselineMLXMemory": before_payload.get("mlxMemory"),
        "candidateMLXMemory": after_payload.get("mlxMemory"),
        "differences": differences,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    try:
        result = compare_runs(args.baseline, args.candidate)
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.exit(2, f"Comparison failed: {error}\n")
    print(json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False))


if __name__ == "__main__":
    main()
