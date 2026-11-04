#!/usr/bin/env python3
"""Rebuild Wispr teacher manifests from durable per-record results."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def write_atomic(path: Path, value: object, *, jsonl: bool = False) -> None:
    temporary = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    if jsonl:
        content = "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in value)
    else:
        content = json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n"
    temporary.write_text(content, encoding="utf-8")
    os.replace(temporary, path)


def rebuild(dataset_dir: Path) -> dict[str, object]:
    records_dir = dataset_dir / "records"
    dataset_dir.mkdir(parents=True, exist_ok=True)
    everything: list[dict[str, object]] = []
    asr: list[dict[str, object]] = []
    polisher: list[dict[str, object]] = []
    languages: dict[str, int] = {}
    broken: list[str] = []
    recording_count = incomplete_count = 0
    seconds = 0.0

    for record_path in sorted(records_dir.glob("*/record.json")):
        try:
            record = json.loads(record_path.read_text(encoding="utf-8"))
            chunks = record["results"]
            if not isinstance(chunks, list) or not chunks:
                raise ValueError("empty results")
        except (OSError, ValueError, KeyError, TypeError) as error:
            broken.append(f"{record_path}: {error}")
            continue
        recording_count += 1
        complete = all(
            chunk.get("raw_http_status") == "200"
            and chunk.get("edited_http_status") == "200"
            for chunk in chunks
        )
        incomplete_count += not complete
        for chunk in chunks:
            everything.append(chunk)
            seconds += float(chunk.get("duration_seconds") or 0)
            language = str(chunk.get("detected_language") or "unknown")
            languages[language] = languages.get(language, 0) + 1
            if chunk.get("raw_http_status") == "200" and chunk.get("raw"):
                asr.append(
                    {
                        "audio": str(record_path.parent / str(chunk["audio_path"])),
                        "text": chunk["raw"],
                        "duration": chunk.get("duration_seconds"),
                    }
                )
                if chunk.get("edited_http_status") == "200" and chunk.get("edited"):
                    polisher.append({"raw": chunk["raw"], "edited": chunk["edited"]})

    write_atomic(dataset_dir / "all-manifest.jsonl", everything, jsonl=True)
    write_atomic(dataset_dir / "asr-manifest.jsonl", asr, jsonl=True)
    write_atomic(dataset_dir / "polisher-manifest.jsonl", polisher, jsonl=True)
    summary = {
        "schema_version": "voxol-wispr-teacher-summary-v1",
        "recording_count": recording_count,
        "incomplete_recording_count": incomplete_count,
        "invalid_record_count": len(broken),
        "chunk_count": len(everything),
        "duration_hours": round(seconds / 3600, 6),
        "languages": languages,
        "usable_asr_count": len(asr),
        "usable_polisher_count": len(polisher),
        "split_status": "unassigned; group by speaker/source before train/dev/test",
    }
    write_atomic(dataset_dir / "dataset-summary.json", summary)
    if broken:
        write_atomic(dataset_dir / "manifest-errors.json", broken)
    else:
        (dataset_dir / "manifest-errors.json").unlink(missing_ok=True)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-dir", type=Path, required=True)
    arguments = parser.parse_args()
    summary = rebuild(arguments.dataset_dir.expanduser())
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 1 if summary["invalid_record_count"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
