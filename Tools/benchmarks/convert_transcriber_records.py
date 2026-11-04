#!/usr/bin/env python3
"""Convert Gemini or Wispr records into VoxoL benchmark predictions."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def joined_transcript(record: dict[str, object], field: str) -> str:
    pieces = []
    for chunk in record.get("results") or []:
        text = str(chunk.get(field) or "").strip()
        if text:
            pieces.append(text)
    return " ".join(pieces)


def joined_final_transcript(record: dict[str, object]) -> str:
    pieces = []
    for chunk in record.get("results") or []:
        raw = str(chunk.get("raw") or "").strip()
        edited = str(chunk.get("edited") or "").strip()
        polished_quality = (chunk.get("quality") or {}).get("polished") or {}
        if polished_quality and polished_quality.get("status") != "pass":
            edited = ""
        text = edited or raw
        if text:
            pieces.append(text)
    return " ".join(pieces)


def records_by_source_sha(records: Path, capture_profile: str | None) -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    for path in sorted(records.glob("*/record.json")):
        record = json.loads(path.read_text(encoding="utf-8"))
        profile = str((record.get("collection") or {}).get("capture_profile") or "")
        if capture_profile and profile != capture_profile:
            continue
        digest = str((record.get("source") or {}).get("sha256") or "")
        if not digest:
            continue
        if digest in result:
            raise SystemExit(
                f"Multiple records match source SHA-256 {digest}; select --capture-profile"
            )
        result[digest] = record
    return result


def convert(
    manifest: dict[str, object],
    audio_root: Path,
    records: dict[str, dict[str, object]],
) -> list[dict[str, object]]:
    rows = []
    for item in manifest.get("items") or []:
        audio = audio_root / str(item["audioPath"])
        digest = sha256(audio)
        record = records.get(digest)
        if record is None:
            raise SystemExit(f"No transcriber record matches {item['id']} ({digest})")
        raw = joined_transcript(record, "raw")
        final = joined_final_transcript(record)
        rows.append(
            {
                "id": item["id"],
                "rawText": raw,
                "finalText": final,
                "inferenceMilliseconds": 0,
                "confidence": {
                    "blankDecisionRatio": 0.0,
                    "emittedTokenCount": len(raw.split()),
                    "inferenceAttemptCount": 1,
                    "lowerDecileDurationLogitMargin": 0.0,
                    "lowerDecileTokenLogitMargin": 0.0,
                    "maximumFramesWithoutEmission": 0,
                    "meanDurationLogitMargin": 0.0,
                    "meanTokenLogitMargin": 0.0,
                    "usedFallbackSegmentation": False,
                },
            }
        )
    return rows


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--manifest", type=Path, required=True)
    result.add_argument("--audio-root", type=Path, required=True)
    result.add_argument("--records", type=Path, required=True)
    result.add_argument("--capture-profile")
    result.add_argument("--output", type=Path, required=True)
    return result


def main() -> int:
    arguments = parser().parse_args()
    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    rows = convert(
        manifest,
        arguments.audio_root,
        records_by_source_sha(arguments.records, arguments.capture_profile),
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows),
        encoding="utf-8",
    )
    print(f"predictions: {len(rows)} -> {arguments.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
