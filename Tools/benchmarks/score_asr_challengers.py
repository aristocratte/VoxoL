#!/usr/bin/env python3
"""Compare frozen dictation campaigns, or explicitly labelled historical teachers."""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import re
import statistics
import unicodedata
from pathlib import Path

import dictation_campaign as campaign


WORD = re.compile(r"[^\W_]+(?:['’\-][^\W_]+)*|\d+(?:[.,]\d+)*", re.UNICODE)
NUMBER = re.compile(r"\d+(?:[.,]\d+)*", re.UNICODE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--campaign-manifest", type=Path)
    parser.add_argument("--split", choices=("diagnostic", "public"), default="diagnostic")
    parser.add_argument("--stage", choices=("raw", "normalized", "final"), default="raw")
    return parser.parse_args()


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def words(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    return WORD.findall(normalized)


def edit_counts(
    reference: list[str],
    hypothesis: list[str],
) -> tuple[int, int, int]:
    previous = [
        (index, 0, index, 0)
        for index in range(len(hypothesis) + 1)
    ]
    for reference_index, reference_word in enumerate(reference):
        current = [(reference_index + 1, 0, 0, reference_index + 1)]
        for hypothesis_index, hypothesis_word in enumerate(hypothesis):
            deletion = previous[hypothesis_index + 1]
            insertion = current[hypothesis_index]
            diagonal = previous[hypothesis_index]
            candidates = [
                (
                    deletion[0] + 1,
                    deletion[1],
                    deletion[2],
                    deletion[3] + 1,
                ),
                (
                    insertion[0] + 1,
                    insertion[1],
                    insertion[2] + 1,
                    insertion[3],
                ),
                (
                    diagonal[0] + (reference_word != hypothesis_word),
                    diagonal[1] + (reference_word != hypothesis_word),
                    diagonal[2],
                    diagonal[3],
                ),
            ]
            current.append(min(candidates, key=lambda item: item[0]))
        previous = current
    _, substitutions, insertions, deletions = previous[-1]
    return substitutions, insertions, deletions


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = math.ceil(fraction * len(ordered)) - 1
    return ordered[max(0, min(index, len(ordered) - 1))]


def duration_bucket(duration: float) -> str:
    if duration < 15:
        return "under15s"
    if duration < 30:
        return "15to30s"
    return "30sAndOver"


def score_row(
    row: dict[str, object],
    hypothesis_field: str,
) -> dict[str, object]:
    reference_text = str(row["referenceRawText"])
    hypothesis_text = str(row[hypothesis_field])
    reference_words = words(reference_text)
    hypothesis_words = words(hypothesis_text)
    substitutions, insertions, deletions = edit_counts(
        reference_words,
        hypothesis_words,
    )
    errors = substitutions + insertions + deletions
    reference_numbers = NUMBER.findall(reference_text)
    hypothesis_numbers = NUMBER.findall(hypothesis_text)
    matched_numbers = sum(
        min(reference_numbers.count(value), hypothesis_numbers.count(value))
        for value in set(reference_numbers)
    )
    return {
        "id": row["id"],
        "language": row.get("language") or "unknown",
        "duration": float(row.get("audioDurationSeconds") or 0),
        "wer": errors / max(len(reference_words), 1),
        "substitutions": substitutions,
        "insertions": insertions,
        "deletions": deletions,
        "referenceWordCount": len(reference_words),
        "referenceNumberCount": len(reference_numbers),
        "matchedNumberCount": matched_numbers,
        "latency": float(row.get("inferenceMilliseconds") or 0),
        "peakMemory": row.get("mlxPeakMemoryBytes"),
    }


def summarize(scored: list[dict[str, object]]) -> dict[str, object]:
    reference_words = sum(int(row["referenceWordCount"]) for row in scored)
    errors = sum(
        int(row["substitutions"]) + int(row["insertions"]) + int(row["deletions"])
        for row in scored
    )
    reference_numbers = sum(int(row["referenceNumberCount"]) for row in scored)
    matched_numbers = sum(int(row["matchedNumberCount"]) for row in scored)
    latencies = [float(row["latency"]) for row in scored]
    memories = [
        int(row["peakMemory"])
        for row in scored
        if isinstance(row.get("peakMemory"), int)
    ]
    return {
        "count": len(scored),
        "microWER": errors / max(reference_words, 1),
        "macroWER": statistics.mean(float(row["wer"]) for row in scored) if scored else None,
        "substitutions": sum(int(row["substitutions"]) for row in scored),
        "insertions": sum(int(row["insertions"]) for row in scored),
        "deletions": sum(int(row["deletions"]) for row in scored),
        "numericTokenRecall": matched_numbers / max(reference_numbers, 1),
        "latencyMilliseconds": {
            "p50": percentile(latencies, 0.50),
            "p95": percentile(latencies, 0.95),
            "p99": percentile(latencies, 0.99),
        },
        "maximumMLXPeakMemoryBytes": max(memories, default=None),
    }


def grouped_summary(
    scored: list[dict[str, object]],
    key,
) -> dict[str, object]:
    groups: dict[str, list[dict[str, object]]] = {}
    for row in scored:
        groups.setdefault(str(key(row)), []).append(row)
    return {name: summarize(rows) for name, rows in sorted(groups.items())}


def main() -> None:
    args = parse_args()
    if args.campaign_manifest:
        compare_campaign(args)
        return
    if args.stage != "raw":
        raise ValueError("Non-ASR stages require --campaign-manifest")
    baseline_rows = read_jsonl(args.baseline)
    baseline_by_id = {str(row["id"]): row for row in baseline_rows}
    if not baseline_rows or len(baseline_by_id) != len(baseline_rows):
        raise ValueError("Historical baseline must be nonempty with unique IDs")
    candidate_paths: dict[str, Path] = {}
    for value in args.candidate:
        name, separator, path = value.partition("=")
        if not separator or not name or not path:
            raise ValueError("--candidate must use NAME=PATH")
        if name in candidate_paths:
            raise ValueError("Duplicate candidate name")
        candidate_paths[name] = Path(path)

    report: dict[str, object] = {
        "schemaVersion": 1,
        "referenceKind": "wispr-raw-teacher-not-human-ground-truth",
        "promotionAllowed": False,
        "candidates": {},
    }
    for name, path in candidate_paths.items():
        all_candidate_rows = read_jsonl(path)
        candidate_by_id = {str(row["id"]): row for row in all_candidate_rows}
        if len(candidate_by_id) != len(all_candidate_rows) or not candidate_by_id.keys() <= baseline_by_id.keys():
            raise ValueError("Unknown or duplicate candidate ID")
        for identifier, row in candidate_by_id.items():
            baseline = baseline_by_id[identifier]
            if row.get("referenceRawText") not in (None, baseline["referenceRawText"]):
                raise ValueError("Candidate reference differs from the fixed baseline reference")
        common_ids = list(baseline_by_id)
        baseline_scored = [
            score_row(baseline_by_id[item_id], "parakeetText")
            for item_id in common_ids
        ]
        candidate_scored = [
            score_row({**baseline_by_id[item_id],
                       "transcript": candidate_by_id.get(item_id, {}).get("transcript", "")
                           if candidate_by_id.get(item_id, {}).get("status", "ok") == "ok" else "",
                       "inferenceMilliseconds": candidate_by_id.get(item_id, {}).get("inferenceMilliseconds"),
                       "mlxPeakMemoryBytes": candidate_by_id.get(item_id, {}).get("mlxPeakMemoryBytes")}, "transcript")
            for item_id in common_ids
        ]
        baseline_wer = {str(row["id"]): float(row["wer"]) for row in baseline_scored}
        deltas = [
            float(row["wer"]) - baseline_wer[str(row["id"])]
            for row in candidate_scored
        ]
        candidate_summary = summarize(candidate_scored)
        baseline_summary = summarize(baseline_scored)
        report["candidates"][name] = {
            "coverage": {
                "scored": len(common_ids),
                "baselineTotal": len(baseline_rows),
                "errors": sum(row.get("status", "ok") != "ok" for row in all_candidate_rows),
                "missing": len(baseline_by_id.keys() - candidate_by_id.keys()),
                "complete": baseline_by_id.keys() == candidate_by_id.keys(),
                "denominatorPolicy": "every baseline ID; errors and missing predictions are empty hypotheses",
            },
            "baselineOnSameRows": baseline_summary,
            "candidate": candidate_summary,
            "byLanguage": grouped_summary(
                candidate_scored,
                lambda row: row["language"],
            ),
            "byDuration": grouped_summary(
                candidate_scored,
                lambda row: duration_bucket(float(row["duration"])),
            ),
            "versusParakeet": {
                "macroWERDelta": (
                    float(candidate_summary["macroWER"])
                    - float(baseline_summary["macroWER"])
                ),
                "relativeMacroWERChange": (
                    float(candidate_summary["macroWER"])
                    / float(baseline_summary["macroWER"])
                    - 1
                    if float(baseline_summary["macroWER"]) > 0
                    else None
                ),
                "improvedCount": sum(delta < -1e-12 for delta in deltas),
                "equalCount": sum(abs(delta) <= 1e-12 for delta in deltas),
                "worsenedCount": sum(delta > 1e-12 for delta in deltas),
            },
        }

    campaign.write_json(args.output, report)
    print(args.output)


def load_run(directory: Path, items: list[dict]) -> tuple[dict, list[dict]]:
    config = json.loads((directory / "run.json").read_text())
    path = directory / "predictions.jsonl"
    rows = campaign.read_jsonl(path) if path.is_file() else []
    campaign.validate_results(rows, items, config)
    return config, rows


def paired_difference(items: list[dict], baseline: dict, candidate: dict) -> dict:
    baseline_by_id = {row["id"]: row for row in baseline["rows"]}
    candidate_by_id = {row["id"]: row for row in candidate["rows"]}
    groups = {}
    changes = []
    for item in items:
        before, after = baseline_by_id[item["id"]], candidate_by_id[item["id"]]
        group = groups.setdefault(item["sourceGroup"], [0, 0, 0])
        group[0] += before["errors"]
        group[1] += after["errors"]
        group[2] += before["referenceWords"]
        changes.append({"id": item["id"], "baselineErrors": before["errors"], "candidateErrors": after["errors"],
                        "errorDelta": after["errors"] - before["errors"],
                        "baselineCorrectRegressed": before["errors"] == 0 and after["errors"] > 0,
                        "newNumericSequenceAlert": not before["numericDifference"] and after["numericDifference"],
                        "newNegationSequenceAlert": not before["negationDifference"] and after["negationDifference"]})
    rng = random.Random(1729)
    draws = []
    values = list(groups.values())
    if len(values) > 1:
        for _ in range(1000):
            sample = rng.choices(values, k=len(values))
            draws.append(sum(row[1] - row[0] for row in sample) / max(1, sum(row[2] for row in sample)))
    before, after = baseline["summary"]["errors"], candidate["summary"]["errors"]
    return {"relativeErrorReduction": (before - after) / before if before else None,
            "lexicalWERDelta": candidate["summary"]["lexicalWER"] - baseline["summary"]["lexicalWER"],
            "pairedGroupBootstrapDelta95CI": [campaign.percentile(draws, .025), campaign.percentile(draws, .975)],
            "improved": sum(row["errorDelta"] < 0 for row in changes),
            "worsened": sum(row["errorDelta"] > 0 for row in changes),
            "unchanged": sum(row["errorDelta"] == 0 for row in changes),
            "previouslyCorrectRegressions": sum(row["baselineCorrectRegressed"] for row in changes),
            "newNumericSequenceAlerts": sum(row["newNumericSequenceAlert"] for row in changes),
            "newNegationSequenceAlerts": sum(row["newNegationSequenceAlert"] for row in changes),
            "changes": changes}


def compare_campaign(args: argparse.Namespace) -> None:
    os.umask(0o077)
    manifest = json.loads(args.campaign_manifest.read_text())
    items = campaign.select(manifest, args.split)
    config, rows = load_run(args.baseline, items)
    if config.get("manifestSHA256") != manifest["manifestSHA256"]:
        raise ValueError("Baseline was run against a different campaign")
    baseline = campaign.score(items, rows, config, args.stage)
    report = {"schemaVersion": campaign.SCHEMA, "stage": args.stage, "sourceKind": manifest.get("sourceKind"),
              "manifestSHA256": manifest["manifestSHA256"], "split": args.split, "promotionAllowed": False,
              "scorerSHA256": campaign.file_digest(Path(__file__)),
              "contractSHA256": campaign.file_digest(Path(campaign.__file__)),
              "baseline": baseline, "candidates": {},
              "limitations": ["diagnostic comparison; the reserved final control is not exposed",
                              "literal numeric/negation alerts are not semantic fact validation",
                              "historical AI references may share candidate ancestry",
                              "candidate-only quality is not retained product quality"]}
    for entry in args.candidate:
        name, separator, path = entry.partition("=")
        if not separator or not name or not path or name in report["candidates"]:
            raise ValueError("Unique --candidate NAME=RUN_DIRECTORY entries are required")
        candidate_config, candidate_rows = load_run(Path(path), items)
        if candidate_config.get("manifestSHA256") != manifest["manifestSHA256"]:
            raise ValueError("Candidate was run against a different campaign")
        scored = campaign.score(items, candidate_rows, candidate_config, args.stage)
        report["candidates"][name] = {"score": scored, "versusBaseline": paired_difference(items, baseline, scored)}
    campaign.write_json(args.output, report)
    print(args.output)
    for name, value in report["candidates"].items():
        print(name, json.dumps({k: v for k, v in value["versusBaseline"].items() if k != "changes"}))


if __name__ == "__main__":
    main()
