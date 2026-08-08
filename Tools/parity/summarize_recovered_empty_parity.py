#!/usr/bin/env python3
"""Summarize stage-level parity for MediaSpeech empty outputs recovered upstream."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path


FEATURE_MODES = ("production", "source")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--diagnostic-report", type=Path, required=True)
    parser.add_argument("--parity-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def mean(values: list[float]) -> float:
    return statistics.fmean(values) if values else 0.0


def main() -> None:
    args = parse_args()
    diagnostic = json.loads(args.diagnostic_report.read_text(encoding="utf-8"))
    recovered = [
        item
        for item in diagnostic["items"]
        if item["coreMLScore"]["empty"] and not item["sourceScore"]["empty"]
    ]
    if not recovered:
        raise ValueError("The diagnostic report has no recovered empty outputs")

    modes: dict[str, dict[str, object]] = {}
    item_reports = {
        str(item["id"]): {
            "id": str(item["id"]),
        }
        for item in recovered
    }
    for mode in FEATURE_MODES:
        reports = []
        for item in recovered:
            item_id = str(item["id"])
            report_path = args.parity_root / item_id / f"report-{mode}.json"
            report = json.loads(report_path.read_text(encoding="utf-8"))
            reports.append(report)
            item_report = item_reports[item_id]
            item_report["sourceTranscript"] = report["sourceTranscript"]
            item_report[f"coreMLTranscript_{mode}"] = report[
                "coreMLTranscript"
            ]
            item_report[f"sourceToCoreMLWordErrorRate_{mode}"] = report[
                "sourceToCoreMLWordErrorRate"
            ]

        modes[mode] = {
            "nonemptyOutputCount": sum(
                bool(report["coreMLTranscript"].strip()) for report in reports
            ),
            "transcriptExactCount": sum(
                bool(report["transcriptExact"]) for report in reports
            ),
            "meanSourceToCoreMLWordErrorRate": mean(
                [
                    float(report["sourceToCoreMLWordErrorRate"])
                    for report in reports
                ]
            ),
            "attentionMaskExactCount": sum(
                bool(report["attentionMaskExact"]) for report in reports
            ),
            "meanPowerNormalizedRMSE": mean(
                [
                    float(report["powerSpectrogram"]["normalizedRMSE"])
                    for report in reports
                    if report["powerSpectrogram"] is not None
                ]
            ),
            "meanFeatureNormalizedRMSE": mean(
                [
                    float(report["inputFeatures"]["normalizedRMSE"])
                    for report in reports
                ]
            ),
            "meanEncoderCosineSimilarity": mean(
                [
                    float(report["encoderHidden"]["cosineSimilarity"])
                    for report in reports
                ]
            ),
        }

    output = {
        "schemaVersion": 1,
        "itemCount": len(recovered),
        "selection": "Core ML empty and official source nonempty",
        "modes": modes,
        "items": list(item_reports.values()),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(args.output)


if __name__ == "__main__":
    main()
