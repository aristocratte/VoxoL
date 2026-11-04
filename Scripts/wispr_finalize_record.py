#!/usr/bin/env python3
"""Atomically assemble one Wispr record from resumable per-chunk states."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path


def write_atomic(path: Path, content: str) -> None:
    temporary = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    temporary.write_text(content, encoding="utf-8")
    os.replace(temporary, path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def finalize(
    record_dir: Path,
    source: Path,
    source_sha256: str,
    duration: float,
    requested_language: str,
    app_type: str,
    speaker_id: str,
    session_id: str,
    youtube_url: str = "",
    youtube_video_id: str = "",
) -> dict[str, object]:
    segmentation = json.loads((record_dir / "segmentation.json").read_text(encoding="utf-8"))
    recording_id = record_dir.name
    results: list[dict[str, object]] = []
    for chunk in segmentation["chunks"]:
        index = int(chunk["chunk"])
        audio_path = str(chunk["audio_file"])
        audio_sha = sha256(record_dir / audio_path)
        state_file = record_dir / "results" / f"chunk_{index:04d}.state.json"
        state: dict[str, object] = {}
        if state_file.exists():
            try:
                candidate = json.loads(state_file.read_text(encoding="utf-8"))
                if (
                    candidate.get("audio_sha256") == audio_sha
                    and candidate.get("requested_language") == requested_language
                    and candidate.get("app_type") == app_type
                    and candidate.get("recording_id") == recording_id
                ):
                    state = candidate
            except (OSError, ValueError, AttributeError):
                pass
        result = {
            "chunk": index,
            "audio_path": audio_path,
            "audio_sha256": audio_sha,
            "start_seconds": chunk["start_seconds"],
            "end_seconds": chunk["end_seconds"],
            "duration_seconds": chunk["duration_seconds"],
            "raw": state.get("raw", ""),
            "raw_http_status": state.get("raw_http_status", "pending"),
            "edited": state.get("edited", ""),
            "edited_http_status": state.get("edited_http_status", "pending"),
            "detected_language": state.get("detected_language", ""),
            "requested_language": requested_language,
            "app_type": app_type,
            "recording_id": recording_id,
        }
        results.append(result)

    if not youtube_url:
        sidecar = source.with_suffix(".source.json")
        if sidecar.exists():
            try:
                metadata = json.loads(sidecar.read_text(encoding="utf-8"))
                if metadata.get("audio_sha256") == source_sha256:
                    youtube_url = str(metadata.get("url", ""))
                    youtube_video_id = str(metadata.get("video_id", ""))
            except (OSError, ValueError, AttributeError):
                pass
    source_info: dict[str, object] = {
        "name": source.name,
        "sha256": source_sha256,
        "bytes": source.stat().st_size,
        "duration_seconds": duration,
    }
    if youtube_url and youtube_video_id:
        source_info["youtube"] = {"url": youtube_url, "video_id": youtube_video_id}

    usable = sum(row["raw_http_status"] == "200" and bool(row["raw"]) for row in results)
    failed = sum(
        row["raw_http_status"] != "200" or row["edited_http_status"] != "200"
        for row in results
    )
    record = {
        "schema_version": "voxol-wispr-teacher-v1",
        "recording_id": recording_id,
        "source": source_info,
        "collection": {
            "speaker_id": speaker_id,
            "session_id": session_id,
            "requested_language": requested_language,
        },
        "teacher": {
            "provider": "Wispr Flow",
            "raw_endpoint": "/llm/asr",
            "edited_endpoint": "/llm/api",
            "note": "raw and edited are independent requests over the same audio chunk",
        },
        "segmentation": segmentation,
        "results": results,
        "summary": {
            "chunk_count": len(results),
            "usable_chunk_count": usable,
            "failed_chunk_count": failed,
            "complete": bool(results) and failed == 0,
        },
    }
    write_atomic(record_dir / "raw.txt", " ".join(str(row["raw"]) for row in results if row["raw_http_status"] == "200").strip() + "\n")
    write_atomic(record_dir / "edited.txt", " ".join(str(row["edited"]) for row in results if row["edited_http_status"] == "200").strip() + "\n")
    write_atomic(record_dir / "record.json", json.dumps(record, indent=2, ensure_ascii=False) + "\n")
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record-dir", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--duration", type=float, required=True)
    parser.add_argument("--language", required=True)
    parser.add_argument("--app-type", required=True)
    parser.add_argument("--speaker-id", default="")
    parser.add_argument("--session-id", default="")
    parser.add_argument("--youtube-url", default="")
    parser.add_argument("--youtube-video-id", default="")
    arguments = parser.parse_args()
    record = finalize(
        arguments.record_dir, arguments.source, arguments.source_sha256, arguments.duration,
        arguments.language, arguments.app_type, arguments.speaker_id, arguments.session_id,
        arguments.youtube_url, arguments.youtube_video_id,
    )
    summary = record["summary"]
    print(json.dumps({"record": str(arguments.record_dir / 'record.json'), **summary}, ensure_ascii=False))
    return 0 if summary["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
