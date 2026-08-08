#!/usr/bin/env python3
"""Adapt the frozen Wispr teacher manifest to ASRBenchmarkKit's current schema.

The source manifest remains immutable and is still used for scoring. This adapter
only supplies the metadata required by the Swift benchmark runner.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


ADAPTER_VERSION = "voxol-wispr-teacher-swift-adapter-v1"


def canonical_source_bytes(manifest: dict[str, object]) -> bytes:
    payload = {
        key: value
        for key, value in manifest.items()
        if key != "contentSHA256"
    }
    return json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def adaptation_identity(items: list[dict[str, object]]) -> str:
    identity = [
        {
            "audioPath": item["audioPath"],
            "id": item["id"],
            "language": item["language"],
            "reference": {
                "clean": item["reference"]["clean"],
                "verbatim": item["reference"]["verbatim"],
            },
            "speakerID": item["speakerID"],
        }
        for item in items
    ]
    return sha256_bytes(
        json.dumps(
            identity,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode()
    )


def adapt(source_path: Path, output_path: Path, report_path: Path) -> dict[str, object]:
    source_bytes = source_path.read_bytes()
    source = json.loads(source_bytes)
    expected_digest = source.get("contentSHA256")
    actual_digest = sha256_bytes(canonical_source_bytes(source))
    if not expected_digest or expected_digest != actual_digest:
        raise ValueError("Source manifest contentSHA256 is missing or invalid.")
    if source.get("normalizationVersion") != "voxol-asr-v1":
        raise ValueError("Source manifest is not the expected legacy Wispr schema.")

    source_items = list(source.get("items", []))
    if not source_items:
        raise ValueError("Source manifest contains no items.")

    adapted_items: list[dict[str, object]] = []
    for item in source_items:
        if item.get("split") != "test":
            raise ValueError(f"Unexpected source split for {item.get('id')!r}.")
        recording_id = str(item.get("recordingID", "")).strip()
        if not recording_id:
            raise ValueError(f"Missing recordingID for {item.get('id')!r}.")
        reference = dict(item.get("reference", {}))
        adapted_items.append(
            {
                "audioPath": item["audioPath"],
                "id": item["id"],
                "speakerID": item["speakerID"],
                "sessionID": recording_id,
                "split": "blind",
                "language": item["language"],
                "microphone": "source-media-unknown",
                "environment": "source-media",
                "tags": ["wispr-teacher", "heldout", ADAPTER_VERSION],
                "reference": {
                    "verbatim": reference["verbatim"],
                    "clean": reference["clean"],
                    "criticalSpans": [],
                    "reviewed": True,
                },
            }
        )

    source_identity = adaptation_identity(source_items)
    adapted_identity = adaptation_identity(adapted_items)
    if source_identity != adapted_identity:
        raise RuntimeError("Adapter changed an ID, audio path, language, speaker, or reference.")

    output = {
        "schemaVersion": 1,
        "benchmarkID": f"{source['benchmarkID']}-swift-adapter-v1",
        "normalizationVersion": "voxol-asr-normalizer-v1",
        "items": adapted_items,
    }
    report = {
        "adapterVersion": ADAPTER_VERSION,
        "itemCount": len(adapted_items),
        "preservedIdentitySHA256": source_identity,
        "sourceBenchmarkID": source["benchmarkID"],
        "sourceContentSHA256": expected_digest,
        "sourceFileSHA256": sha256_bytes(source_bytes),
        "sourceFrozenAt": source.get("frozenAt"),
        "sourcePath": str(source_path),
        "outputPath": str(output_path),
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    arguments = parser.parse_args()
    print(
        json.dumps(
            adapt(arguments.source, arguments.output, arguments.report),
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
