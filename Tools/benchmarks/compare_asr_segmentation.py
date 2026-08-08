#!/usr/bin/env python3

import argparse
import json
import re
import statistics
from pathlib import Path


WORD = re.compile(r"\w+", re.UNICODE)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare Parakeet segmentation runs against a baseline."
    )
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument(
        "--candidate",
        action="append",
        required=True,
        metavar="NAME=PATH",
    )
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def load_json_lines(path: Path) -> list[dict]:
    return [
        json.loads(line)
        for line in path.read_text().splitlines()
        if line.strip()
    ]


def percentile(values: list[int], fraction: float) -> int:
    ordered = sorted(values)
    return ordered[int((len(ordered) - 1) * fraction)]


def duration_bucket(duration: float) -> str:
    if duration < 15:
        return "under_15s"
    if duration < 30:
        return "15_to_30s"
    return "30s_and_over"


def summarize(rows: list[dict]) -> dict:
    durations = [row["inferenceMilliseconds"] for row in rows]
    wers = [row["versusWisprASR"]["wordErrorRate"] for row in rows]
    buckets = {}
    for name in ("under_15s", "15_to_30s", "30s_and_over"):
        selected = [
            row
            for row in rows
            if duration_bucket(row["audioDurationSeconds"]) == name
        ]
        buckets[name] = {
            "count": len(selected),
            "meanWordErrorRate": statistics.mean(
                row["versusWisprASR"]["wordErrorRate"] for row in selected
            ),
            "meanInferenceMilliseconds": statistics.mean(
                row["inferenceMilliseconds"] for row in selected
            ),
        }
    return {
        "count": len(rows),
        "meanWordErrorRate": statistics.mean(wers),
        "meanInferenceMilliseconds": statistics.mean(durations),
        "p50InferenceMilliseconds": percentile(durations, 0.50),
        "p95InferenceMilliseconds": percentile(durations, 0.95),
        "byDuration": buckets,
    }


def compare(baseline: list[dict], candidate: list[dict]) -> dict:
    baseline_by_id = {row["id"]: row for row in baseline}
    candidate_by_id = {row["id"]: row for row in candidate}
    if baseline_by_id.keys() != candidate_by_id.keys():
        raise ValueError("Baseline and candidate record IDs differ")

    improved = equal = worsened = 0
    under_half_reference = 0
    deltas = []
    for record_id, baseline_row in baseline_by_id.items():
        candidate_row = candidate_by_id[record_id]
        delta = (
            candidate_row["versusWisprASR"]["wordErrorRate"]
            - baseline_row["versusWisprASR"]["wordErrorRate"]
        )
        deltas.append(delta)
        if delta < -1e-12:
            improved += 1
        elif delta > 1e-12:
            worsened += 1
        else:
            equal += 1

        reference_words = len(WORD.findall(candidate_row["referenceRawText"]))
        candidate_words = len(WORD.findall(candidate_row["parakeetText"]))
        if reference_words and candidate_words < reference_words * 0.5:
            under_half_reference += 1

    summary = summarize(candidate)
    baseline_summary = summarize(baseline)
    summary["versusBaseline"] = {
        "meanWordErrorRateDelta": (
            summary["meanWordErrorRate"]
            - baseline_summary["meanWordErrorRate"]
        ),
        "meanInferenceMillisecondsDelta": (
            summary["meanInferenceMilliseconds"]
            - baseline_summary["meanInferenceMilliseconds"]
        ),
        "improvedCount": improved,
        "equalCount": equal,
        "worsenedCount": worsened,
        "largestWordErrorRateImprovement": min(deltas),
        "largestWordErrorRateRegression": max(deltas),
        "underHalfReferenceWordCount": under_half_reference,
    }
    return summary


def main() -> None:
    args = arguments()
    baseline = load_json_lines(args.baseline)
    candidates = {}
    for value in args.candidate:
        name, separator, path = value.partition("=")
        if not separator or not name or not path:
            raise ValueError("--candidate must use NAME=PATH")
        candidates[name] = compare(baseline, load_json_lines(Path(path)))

    output = {
        "schemaVersion": 1,
        "baseline": summarize(baseline),
        "candidates": candidates,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary_output = args.output.with_suffix(f"{args.output.suffix}.tmp")
    temporary_output.write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n"
    )
    temporary_output.replace(args.output)


if __name__ == "__main__":
    main()
