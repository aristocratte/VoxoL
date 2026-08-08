#!/usr/bin/env python3
"""Turn Wispr teacher records into a VoxoL predictions file.

Every comparison against Wispr so far has used Wispr's own output as the
reference, which structurally prevents VoxoL from ever winning: the best
possible score is "identical to the teacher, mistakes included". Scoring both
systems against an independent human reference is the only measurement that can
answer whether VoxoL is actually better.

This converts a `wispr-transcribe.sh` dataset into the JSONL the benchmark CLI
consumes, so both systems go through the same normalisation and the same
scorer. Item ids are rebuilt from the audio file name, which is what the frozen
manifests key on.

Usage:
    ./convert_wispr_records_to_predictions.py \\
        --records <dataset/records> --id-prefix mediaspeech-fr \\
        --output <predictions.jsonl>
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--records", type=Path, required=True)
    result.add_argument(
        "--id-prefix",
        default="",
        help="Prepended to the audio stem to rebuild the manifest item id.",
    )
    result.add_argument("--output", type=Path, required=True)
    result.add_argument(
        "--field",
        choices=("raw", "edited"),
        default="raw",
        help="Wispr exposes a verbatim transcript and an LLM-edited one; the "
        "frozen benchmarks carry verbatim references, so raw is the fair "
        "comparison.",
    )
    return result


def transcript(record: dict, field: str) -> str:
    """Join a recording's chunks in order, as the collector segmented them."""
    pieces = []
    for chunk in record.get("results") or []:
        if chunk.get(f"{field}_http_status") != "200":
            continue
        text = str(chunk.get(field) or "").strip()
        if text:
            pieces.append(text)
    return " ".join(pieces)


def main() -> int:
    arguments = parser().parse_args()
    rows = []
    skipped = 0
    for path in sorted(arguments.records.glob("*/record.json")):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            skipped += 1
            continue
        name = str((record.get("source") or {}).get("name") or "")
        if not name:
            skipped += 1
            continue
        stem = Path(name).stem
        text = transcript(record, arguments.field)
        if not text:
            skipped += 1
            continue
        rows.append(
            {
                "id": f"{arguments.id_prefix}-{stem}" if arguments.id_prefix else stem,
                "rawText": text,
                "finalText": text,
                # The scorer decodes confidence as VoxoL's decoder telemetry.
                # A foreign system has no equivalent, so the fields are present
                # and neutral: they feed no scoring path, only the report's
                # optional diagnostics.
                "confidence": {
                    "blankDecisionRatio": 0.0,
                    "emittedTokenCount": len(text.split()),
                    "inferenceAttemptCount": 1,
                    "lowerDecileDurationLogitMargin": 0.0,
                    "lowerDecileTokenLogitMargin": 0.0,
                    "maximumFramesWithoutEmission": 0,
                    "meanDurationLogitMargin": 0.0,
                    "meanTokenLogitMargin": 0.0,
                    "usedFallbackSegmentation": False,
                },
                "inferenceMilliseconds": 0,
            }
        )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows),
        encoding="utf-8",
    )
    print(f"predictions: {len(rows)}  skipped: {skipped}  -> {arguments.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
