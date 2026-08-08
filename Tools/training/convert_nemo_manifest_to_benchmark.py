#!/usr/bin/env python3
"""Convert a NeMo JSONL manifest into an unfrozen VoxoL ASR benchmark."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


LANGUAGES = {
    "en": "english",
    "en_us": "english",
    "english": "english",
    "fr": "french",
    "fr_fr": "french",
    "french": "french",
}


def infer_language(row: dict[str, object], audio_path: Path) -> str:
    for field in ("language", "detected_language", "requested_language"):
        explicit = str(row.get(field, "")).lower()
        if explicit in LANGUAGES:
            return LANGUAGES[explicit]
    for part in audio_path.parts:
        if part.lower() in LANGUAGES:
            return LANGUAGES[part.lower()]
    raise SystemExit(f"Could not infer language for {audio_path}")


def identifier(row: dict[str, object], audio_path: Path) -> str:
    if row.get("id"):
        return str(row["id"])
    digest = hashlib.sha256(
        (
            audio_path.as_posix()
            + "\0"
            + str(row.get("text", ""))
        ).encode()
    ).hexdigest()[:16]
    return f"nemo-{digest}"


def convert(
    input_path: Path,
    output_path: Path,
    benchmark_id: str,
    audio_root: Path | None,
    trust_reference: bool = False,
) -> dict[str, object]:
    items = []
    seen = set()
    for line_number, line in enumerate(
        input_path.read_text(encoding="utf-8").splitlines(),
        1,
    ):
        if not line.strip():
            continue
        row = json.loads(line)
        raw_audio_path = row.get("audio_path", row.get("audio_filepath"))
        if not raw_audio_path:
            raise SystemExit(f"Missing audio path at {input_path}:{line_number}")
        source_audio_path = Path(str(raw_audio_path))
        if audio_root is not None and source_audio_path.is_absolute():
            try:
                benchmark_audio_path = source_audio_path.relative_to(audio_root)
            except ValueError as error:
                raise SystemExit(
                    f"Audio is outside --audio-root at {input_path}:{line_number}"
                ) from error
        else:
            benchmark_audio_path = source_audio_path
        item_id = identifier(row, source_audio_path)
        if item_id in seen:
            raise SystemExit(f"Duplicate id at {input_path}:{line_number}: {item_id}")
        seen.add(item_id)
        text = str(row.get("text", "")).strip()
        if not text:
            raise SystemExit(f"Missing reference at {input_path}:{line_number}")
        language = infer_language(row, source_audio_path)
        items.append(
            {
                "id": item_id,
                "audioPath": benchmark_audio_path.as_posix(),
                "speakerID": str(row.get("speaker_id", "unknown")),
                "sessionID": str(row.get("recording_id", benchmark_id)),
                "split": "development",
                "language": language,
                "microphone": "source-unknown",
                "environment": "source-unknown",
                "tags": ["development", "converted-from-nemo"],
                "reference": {
                    "verbatim": text,
                    "clean": text,
                    "criticalSpans": [],
                    "reviewed": trust_reference or bool(row.get("reviewed", False)),
                },
            }
        )
    if not items:
        raise SystemExit(f"Empty NeMo manifest: {input_path}")
    payload = {
        "schemaVersion": 1,
        "benchmarkID": benchmark_id,
        "normalizationVersion": "voxol-asr-normalizer-v1",
        "items": items,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return payload


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--benchmark-id", required=True)
    parser.add_argument("--audio-root", type=Path)
    parser.add_argument(
        "--trust-reference",
        action="store_true",
        help="Mark teacher transcripts as reviewed benchmark references.",
    )
    arguments = parser.parse_args()
    payload = convert(
        arguments.input.resolve(),
        arguments.output.resolve(),
        arguments.benchmark_id,
        arguments.audio_root.resolve() if arguments.audio_root else None,
        arguments.trust_reference,
    )
    print(json.dumps({"itemCount": len(payload["items"])}, sort_keys=True))


if __name__ == "__main__":
    main()
