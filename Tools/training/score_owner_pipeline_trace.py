#!/usr/bin/env python3
"""Attribute owner dictation errors between raw ASR and final text processing."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import statistics
from typing import Any

from score_asr_predictions import edit_distance, normalize


def word_score(reference: str, hypothesis: str) -> tuple[int, int]:
    reference_words = normalize(reference).split()
    hypothesis_words = normalize(hypothesis).split()
    return edit_distance(reference_words, hypothesis_words), len(reference_words)


def contains_any(text: str, alternatives: list[str]) -> bool:
    normalized_text = f" {normalize(text)} "
    return any(
        f" {normalize(alternative)} " in normalized_text
        for alternative in alternatives
        if normalize(alternative)
    )


def aggregate(scores: list[tuple[int, int]]) -> dict[str, float | int]:
    errors = sum(error_count for error_count, _ in scores)
    words = sum(word_count for _, word_count in scores)
    return {
        "wordErrors": errors,
        "referenceWords": words,
        "microWER": errors / words if words else 0.0,
        "macroWER": (
            statistics.fmean(
                error_count / word_count if word_count else 0.0
                for error_count, word_count in scores
            )
            if scores
            else 0.0
        ),
        "exactMatchRate": (
            sum(error_count == 0 for error_count, _ in scores) / len(scores)
            if scores
            else 0.0
        ),
    }


def score_pipeline(
    manifest: dict[str, Any],
    trace_export: dict[str, Any],
) -> dict[str, Any]:
    items = list(manifest["items"])
    traces = list(trace_export["traces"])
    if len(traces) != len(items):
        raise ValueError(
            f"Expected {len(items)} traces in order, received {len(traces)}. "
            "Clear the inspector and dictate the complete gate again."
        )

    raw_scores: list[tuple[int, int]] = []
    raw_clean_scores: list[tuple[int, int]] = []
    final_scores: list[tuple[int, int]] = []
    group_scores: dict[str, dict[str, list[tuple[int, int]]]] = {}
    details = []
    improved = 0
    regressed = 0
    unchanged = 0
    raw_critical_misses = 0
    final_critical_misses = 0
    processing_repairs = 0
    processing_regressions = 0
    qwen_repairs = 0
    qwen_regressions = 0
    deterministic_repairs = 0
    deterministic_regressions = 0
    inherited_critical_failures = 0
    critical_span_count = 0

    for item, trace in zip(items, traces, strict=True):
        raw_text = str(trace["rawTranscript"])
        final_text = str(trace["finalText"])
        processing_route = str(trace.get("processingRoute") or "unknown")
        raw_score = word_score(str(item["verbatim"]), raw_text)
        raw_clean_score = word_score(str(item["clean"]), raw_text)
        final_score = word_score(str(item["clean"]), final_text)
        raw_scores.append(raw_score)
        raw_clean_scores.append(raw_clean_score)
        final_scores.append(final_score)

        group = str(item["group"])
        group_bucket = group_scores.setdefault(
            group,
            {"raw": [], "rawAgainstClean": [], "final": []},
        )
        group_bucket["raw"].append(raw_score)
        group_bucket["rawAgainstClean"].append(raw_clean_score)
        group_bucket["final"].append(final_score)

        if final_score[0] < raw_clean_score[0]:
            impact = "improved"
            improved += 1
        elif final_score[0] > raw_clean_score[0]:
            impact = "regressed"
            regressed += 1
        else:
            impact = "unchanged"
            unchanged += 1

        critical_details = []
        for span_index, span in enumerate(item.get("criticalSpans", []), 1):
            critical_span_count += 1
            raw_passed = contains_any(raw_text, list(span["rawAccepted"]))
            final_passed = contains_any(final_text, list(span["finalAccepted"]))
            raw_critical_misses += not raw_passed
            final_critical_misses += not final_passed
            if not raw_passed and final_passed:
                processing_repairs += 1
                if processing_route == "qwen":
                    attribution = "qwen_repair"
                    qwen_repairs += 1
                else:
                    attribution = "deterministic_repair"
                    deterministic_repairs += 1
            elif raw_passed and not final_passed:
                processing_regressions += 1
                if processing_route == "qwen":
                    attribution = "qwen_regression"
                    qwen_regressions += 1
                else:
                    attribution = "deterministic_regression"
                    deterministic_regressions += 1
            elif not raw_passed and not final_passed:
                attribution = "asr_inherited_failure"
                inherited_critical_failures += 1
            else:
                attribution = "preserved"
            critical_details.append(
                {
                    "index": span_index,
                    "kind": span["kind"],
                    "rawPassed": raw_passed,
                    "finalPassed": final_passed,
                    "attribution": attribution,
                }
            )

        details.append(
            {
                "id": item["id"],
                "group": group,
                "rawTranscript": raw_text,
                "finalText": final_text,
                "rawWER": raw_score[0] / raw_score[1] if raw_score[1] else 0.0,
                "rawAgainstCleanWER": (
                    raw_clean_score[0] / raw_clean_score[1]
                    if raw_clean_score[1]
                    else 0.0
                ),
                "finalWER": (
                    final_score[0] / final_score[1] if final_score[1] else 0.0
                ),
                "textProcessingImpact": impact,
                "criticalSpans": critical_details,
                "speechRecognitionEngine": trace.get("speechRecognitionEngine"),
                "processingRoute": trace.get("processingRoute"),
                "asrMilliseconds": trace.get("asrMilliseconds"),
                "polishingMilliseconds": trace.get("polishingMilliseconds"),
            }
        )

    raw_clean_total = aggregate(raw_clean_scores)
    final_total = aggregate(final_scores)
    return {
        "schemaVersion": 1,
        "benchmarkID": manifest["benchmarkID"],
        "itemCount": len(items),
        "rawASR": aggregate(raw_scores),
        "rawAgainstClean": raw_clean_total,
        "finalText": final_total,
        "textProcessingImpact": {
            "improvedItemCount": improved,
            "regressedItemCount": regressed,
            "unchangedItemCount": unchanged,
            "wordErrorDelta": (
                int(final_total["wordErrors"]) - int(raw_clean_total["wordErrors"])
            ),
        },
        "criticalSpans": {
            "spanCount": critical_span_count,
            "rawMissCount": raw_critical_misses,
            "finalMissCount": final_critical_misses,
            "processingRepairCount": processing_repairs,
            "processingRegressionCount": processing_regressions,
            "qwenRepairCount": qwen_repairs,
            "qwenRegressionCount": qwen_regressions,
            "deterministicRepairCount": deterministic_repairs,
            "deterministicRegressionCount": deterministic_regressions,
            "inheritedASRFailureCount": inherited_critical_failures,
            "zeroProcessingCriticalRegressionPassed": processing_regressions == 0,
        },
        "byGroup": {
            group: {
                "itemCount": len(scores["raw"]),
                "rawASR": aggregate(scores["raw"]),
                "rawAgainstClean": aggregate(scores["rawAgainstClean"]),
                "finalText": aggregate(scores["final"]),
            }
            for group, scores in sorted(group_scores.items())
        },
        "items": details,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--traces", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    manifest_bytes = arguments.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    traces = json.loads(arguments.traces.read_text(encoding="utf-8"))
    report = {
        **score_pipeline(manifest, traces),
        "manifestFileSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
