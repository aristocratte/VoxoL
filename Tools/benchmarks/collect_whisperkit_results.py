#!/usr/bin/env python3
"""Convert WhisperKit CLI reports into VoxoL challenger JSONL rows."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--reports", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def main() -> None:
    args = parse_args()
    baseline = read_jsonl(args.baseline)
    report_paths = {
        path.stem: path
        for path in args.reports.glob("*.json")
        if path.is_file()
    }

    rows: list[dict[str, object]] = []
    for item in baseline:
        item_id = str(item["id"])
        report_path = report_paths.get(item_id)
        if report_path is None:
            rows.append(
                {
                    **item,
                    "model": "whisperkit-large-v3-626mb",
                    "status": "error",
                    "error": "missing WhisperKit report",
                }
            )
            continue

        report = json.loads(report_path.read_text(encoding="utf-8"))
        timings = report.get("timings") or {}
        rows.append(
            {
                **item,
                "model": "whisperkit-large-v3-626mb",
                "status": "ok",
                "transcript": str(report.get("text") or "").strip(),
                "detectedLanguage": report.get("language"),
                "inferenceMilliseconds": (
                    float(timings.get("fullPipeline") or 0) * 1_000
                ),
                "audioDurationSeconds": float(
                    timings.get("inputAudioSeconds")
                    or item.get("audioDurationSeconds")
                    or 0
                ),
                "coldModelLoadingMilliseconds": (
                    float(timings.get("modelLoading") or 0) * 1_000
                ),
                "encodingMilliseconds": (
                    float(timings.get("encoding") or 0) * 1_000
                ),
                "logMelMilliseconds": (
                    float(timings.get("logmels") or 0) * 1_000
                ),
                "decodingMilliseconds": (
                    float(timings.get("decodingLoop") or 0) * 1_000
                ),
            }
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        "".join(
            json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            for row in rows
        ),
        encoding="utf-8",
    )
    print(args.output)


if __name__ == "__main__":
    main()
