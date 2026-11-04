#!/usr/bin/env python3
"""Inventory every YouTube audio and stage Wispr silver labels without losing failures."""

from __future__ import annotations

import argparse
from collections import Counter
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re


VIDEO_URL = re.compile(r"https://www\.youtube\.com/watch\?v=([A-Za-z0-9_-]{11})")
AUDIO_SUFFIXES = {".mp3", ".wav", ".m4a", ".flac", ".ogg", ".opus"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.partial.{os.getpid()}")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.partial.{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(temporary, path)


def source_table(path: Path) -> list[dict[str, object]]:
    if path.suffix.lower() == ".json":
        payload = json.loads(path.read_text(encoding="utf-8"))
        videos = payload.get("videos", [])
        if not isinstance(videos, list) or not videos:
            raise ValueError(f"No video rows found in {path}")
        seen = set()
        result = []
        for video in videos:
            video_id = str(video["video_id"])
            url_match = VIDEO_URL.fullmatch(str(video["url"]))
            if (video_id in seen or video["language_hint"] not in {"fr", "en"}
                    or not url_match or url_match.group(1) != video_id):
                raise ValueError(f"Invalid or duplicate video in {path}: {video_id}")
            seen.add(video_id)
            result.append({key: video[key] for key in (
                "video_id", "url", "language_hint", "title_from_table", "trainability_claim_from_table"
            )})
        return result
    language = ""
    videos = []
    seen = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("### Français"):
            language = "fr"
        elif line.startswith("### Anglais"):
            language = "en"
        if not language or not re.match(r"^\|\s*\d+\s*\|", line):
            continue
        match = VIDEO_URL.search(line)
        if not match:
            raise ValueError(f"Video row without a YouTube ID: {line[:100]}")
        video_id = match.group(1)
        if video_id in seen:
            raise ValueError(f"Duplicate video ID in source table: {video_id}")
        seen.add(video_id)
        title = re.search(r"\|\s*\d+\s*\|\s*\[([^]]+)\]", line)
        trainability = re.search(r"`(All|None)`", line)
        videos.append(
            {
                "video_id": video_id,
                "url": match.group(0),
                "language_hint": language,
                "title_from_table": title.group(1) if title else "",
                "trainability_claim_from_table": trainability.group(1) if trainability else "unknown",
            }
        )
    if not videos:
        raise ValueError(f"No video rows found in {path}")
    return videos


def job_states(jobs_dir: Path) -> dict[str, str]:
    states = {}
    for path in sorted(jobs_dir.glob("job-*.json"), key=lambda item: (item.stat().st_mtime, item.name)):
        job = json.loads(path.read_text(encoding="utf-8"))
        for item in job.get("items", []):
            states[str(item.get("video_id", ""))] = str(item.get("status", "unknown"))
    return states


def require_idle_collection(jobs_dir: Path) -> None:
    lock_path = jobs_dir / "collector.lock"
    if not lock_path.is_file():
        return
    with lock_path.open("r") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Wispr collection is still running; wait before freezing this dataset") from error
        fcntl.flock(lock, fcntl.LOCK_UN)


def safe_audio_path(record_dir: Path, value: object) -> Path:
    relative = Path(str(value))
    if relative.is_absolute() or ".." in relative.parts or relative.suffix.lower() not in AUDIO_SUFFIXES:
        raise ValueError(f"Unsafe audio path in {record_dir}: {relative}")
    return record_dir / relative


def build(collection_root: Path, table_path: Path, output_root: Path, jobs_dir: Path | None = None) -> dict[str, object]:
    dataset_root = collection_root / "dataset"
    records_dir = dataset_root / "records"
    cache_dir = collection_root / "youtube-audio"
    videos = source_table(table_path)
    expected = {str(video["video_id"]): video for video in videos}
    actual_jobs_dir = jobs_dir or collection_root / "youtube-jobs"
    require_idle_collection(actual_jobs_dir)
    jobs = job_states(actual_jobs_dir)
    records = {}
    for path in sorted(records_dir.glob("*/record.json")):
        record = json.loads(path.read_text(encoding="utf-8"))
        video_id = str(record["source"]["youtube"]["video_id"])
        if video_id not in expected or video_id in records:
            raise ValueError(f"Unexpected or duplicate record video ID: {video_id}")
        records[video_id] = (path.parent, record)

    record_owners = {record_dir.name: video_id for video_id, (record_dir, _) in records.items()}
    segment_hashes = {}
    for video_id, (record_dir, record) in records.items():
        for result in record.get("results", []):
            audio = safe_audio_path(record_dir, result.get("audio_path"))
            if audio in segment_hashes:
                raise ValueError(f"Duplicate segment audio path: {audio}")
            segment_hashes[audio] = (video_id, result.get("audio_sha256"))

    inventory = []
    integrity = {}
    for path in sorted((*cache_dir.rglob("*"), *records_dir.rglob("*"))):
        # ExFAT can create AppleDouble ._ files beside copied media. They are
        # metadata sidecars, not playable audio.
        if path.name.startswith("._") or not path.is_file() or path.suffix.lower() not in AUDIO_SUFFIXES:
            continue
        relative = path.relative_to(collection_root).as_posix()
        digest = sha256(path)
        expected_hash = None
        video_id = None
        role = "unindexed_audio"
        if path.parent == cache_dir and path.name.startswith("youtube-"):
            video_id = path.stem.removeprefix("youtube-")
            role = "downloaded_source"
            sidecar = path.with_suffix(".source.json")
            if sidecar.is_file():
                expected_hash = json.loads(sidecar.read_text(encoding="utf-8")).get("audio_sha256")
        elif path in segment_hashes:
            video_id, expected_hash = segment_hashes[path]
            role = "segment_audio"
        elif path.is_relative_to(records_dir):
            video_id = record_owners.get(path.relative_to(records_dir).parts[0])
            role = "intermediate_full_audio" if path.name == "source-16k.wav" else "unindexed_audio"
        valid = expected_hash is None or digest == expected_hash
        inventory.append(
            {
                "path": relative,
                "bytes": path.stat().st_size,
                "sha256": digest,
                "expected_sha256": expected_hash,
                "integrity_ok": valid,
                "role": role,
                "video_id": video_id,
            }
        )
        integrity[relative] = valid

    by_path = {str(item["path"]): item for item in inventory}
    teacher_rows = []
    qwen_targets = []
    catalog = []
    missing_segments = []
    for video in videos:
        video_id = str(video["video_id"])
        source_path = cache_dir / f"youtube-{video_id}.mp3"
        source_rel = source_path.relative_to(collection_root).as_posix()
        record_entry = records.get(video_id)
        item = dict(video)
        item["job_status"] = jobs.get(video_id, "not_in_job")
        item["source_audio_path"] = source_rel if source_path.is_file() else None
        item["recording_id"] = record_entry[1]["recording_id"] if record_entry else None
        item["teacher_complete"] = bool(record_entry and record_entry[1].get("summary", {}).get("complete"))
        item["source_present"] = source_rel in by_path
        item["source_matches_record"] = None
        if record_entry and item["source_present"]:
            record_hash = str(record_entry[1].get("source", {}).get("sha256", ""))
            item["source_matches_record"] = bool(record_hash and by_path[source_rel]["sha256"] == record_hash)
            if not item["source_matches_record"]:
                by_path[source_rel]["integrity_ok"] = False
        item["raw_failed_chunks"] = sum(
            str(result.get("raw_http_status")) != "200"
            for result in record_entry[1].get("results", [])
        ) if record_entry else None
        item["edited_failed_chunks"] = sum(
            str(result.get("edited_http_status")) != "200"
            for result in record_entry[1].get("results", [])
        ) if record_entry else None
        item["language_mismatch_chunks"] = sum(
            str(result.get("detected_language", "")) != video["language_hint"]
            for result in record_entry[1].get("results", [])
        ) if record_entry else None
        catalog.append(item)
        if record_entry is None:
            continue
        record_dir, record = record_entry
        speaker_id = str(record.get("collection", {}).get("speaker_id", ""))
        for result in record.get("results", []):
            audio = safe_audio_path(record_dir, result.get("audio_path"))
            audio_rel = audio.relative_to(collection_root).as_posix()
            if audio_rel not in by_path:
                missing_segments.append(audio_rel)
                inventory.append(
                    {"path": audio_rel, "bytes": None, "sha256": None,
                     "expected_sha256": result.get("audio_sha256"), "integrity_ok": False,
                     "role": "missing_segment_audio", "video_id": video_id}
                )
            row = dict(result)
            row.update(
                {
                    "id": f"{record['recording_id']}-chunk-{int(result['chunk']):04d}",
                    "audio_path": audio.relative_to(dataset_root).as_posix(),
                    "duration": result.get("duration_seconds"),
                    "recording_id": record["recording_id"],
                    "speaker_id": speaker_id,
                    "requested_language": video["language_hint"],
                    "collection_requested_language": record.get("collection", {}).get("requested_language"),
                    "source_video_id": video_id,
                    "source_url": video["url"],
                    "source": "ai-curated-experimental",
                    "label_status": "silver-wispr",
                    "approved": False,
                    "humanReviewed": False,
                    "usable_for_asr": (
                        str(result.get("raw_http_status")) == "200"
                        and bool(str(result.get("raw") or "").strip())
                        and integrity.get(audio_rel, False)
                        and item["source_matches_record"] is True
                    ),
                }
            )
            teacher_rows.append(row)
            if str(result.get("edited_http_status")) == "200" and str(result.get("edited") or "").strip():
                qwen_targets.append(
                    {
                        "id": row["id"], "recording_id": row["recording_id"],
                        "source_video_id": video_id, "language_hint": video["language_hint"],
                        "audio_path": row["audio_path"], "target_text": result["edited"],
                        "target_provenance": "silver-wispr-edited",
                        "input_requirement": "exact VoxoL final runtime raw transcript of this audio",
                        "input_status": "pending", "approved": False, "humanReviewed": False,
                    }
                )

    if len({str(row["id"]) for row in teacher_rows}) != len(teacher_rows):
        raise ValueError("Duplicate chunk IDs")
    inventory.sort(key=lambda item: str(item["path"]))
    source_document = json.loads(table_path.read_text(encoding="utf-8")) if table_path.suffix.lower() == ".json" else {}
    write_json(output_root / "source-catalog.json", {
        "source_input_sha256": sha256(table_path),
        "source_table_sha256": source_document.get("source_table_sha256", sha256(table_path)),
        "claim_status": "user-supplied table; not independently verified live",
        "videos": catalog,
    })
    write_jsonl(output_root / "audio-inventory.jsonl", inventory)
    write_jsonl(output_root / "teacher-all.jsonl", teacher_rows)
    write_jsonl(output_root / "qwen-targets-pending.jsonl", qwen_targets)
    report = {
        "schema_version": "voxol-wispr-youtube-campaign-v1",
        "collection_root": str(collection_root),
        "source_video_count": len(videos),
        "present_source_count": sum(bool(item["source_present"]) for item in catalog),
        "missing_source_video_ids": [item["video_id"] for item in catalog if not item["source_present"]],
        "recording_count": len(records),
        "incomplete_recording_count": sum(not item["teacher_complete"] for item in catalog if item["recording_id"]),
        "teacher_chunk_count": len(teacher_rows),
        "asr_raw_available_count": sum(bool(row["usable_for_asr"]) for row in teacher_rows),
        "qwen_edited_target_count": len(qwen_targets),
        "audio_present_count": sum(item["bytes"] is not None for item in inventory),
        "audio_missing_segment_paths": missing_segments,
        "audio_integrity_mismatch_paths": [item["path"] for item in inventory if item["bytes"] is not None and not item["integrity_ok"]],
        "raw_http_statuses": dict(Counter(str(row.get("raw_http_status")) for row in teacher_rows)),
        "edited_http_statuses": dict(Counter(str(row.get("edited_http_status")) for row in teacher_rows)),
        "label_status": "silver; no human gold; Qwen inputs pending exact VoxoL runtime predictions",
        "files_sha256": {name: sha256(output_root / name) for name in (
            "source-catalog.json", "audio-inventory.jsonl", "teacher-all.jsonl", "qwen-targets-pending.jsonl"
        )},
    }
    write_json(output_root / "import-report.json", report)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collection-root", type=Path, required=True)
    parser.add_argument("--source-table", type=Path, required=True)
    parser.add_argument("--jobs-dir", type=Path, help="Live local job directory, if separate from the SSD corpus")
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    report = build(
        args.collection_root.expanduser().resolve(), args.source_table.expanduser().resolve(),
        args.output_root.expanduser().resolve(),
        args.jobs_dir.expanduser().resolve() if args.jobs_dir else None,
    )
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
