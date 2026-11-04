#!/usr/bin/env python3
"""Finish a silver ASR package after an independently running Wispr batch exits."""

from __future__ import annotations

import argparse
from collections import Counter
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time


SCRIPT_DIR = Path(__file__).resolve().parent


def batch_running(jobs_dir: Path) -> bool:
    lock_path = jobs_dir / "collector.lock"
    with lock_path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(lock, fcntl.LOCK_UN)
    return False


def read_job(jobs_dir: Path, expected_job: str) -> dict[str, object]:
    latest = json.loads((jobs_dir / "latest.json").read_text(encoding="utf-8"))
    if latest.get("job_file") != expected_job or Path(expected_job).name != expected_job:
        raise RuntimeError(f"Latest Wispr job changed; expected {expected_job}")
    job = json.loads((jobs_dir / expected_job).read_text(encoding="utf-8"))
    statuses = Counter(str(item.get("status", "pending")) for item in job.get("items", []))
    if statuses["running"] or statuses["pending"]:
        raise RuntimeError(f"Batch stopped with unfinished items: {dict(statuses)}")
    return job


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collection-root", type=Path, required=True)
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--jobs-dir", type=Path, required=True)
    parser.add_argument("--expected-job", required=True)
    parser.add_argument("--maximum-wait-hours", type=float, default=24)
    parser.add_argument("--asr-quarantine", type=Path)
    args = parser.parse_args()
    collection_root = args.collection_root.expanduser().resolve()
    sources = args.sources.expanduser().resolve()
    jobs_dir = args.jobs_dir.expanduser().resolve()
    prepared = collection_root / "prepared"
    importer = prepared / "import"
    asr = prepared / "asr-silver"
    archive = prepared / "asr-silver.tar.gz"
    deadline = time.monotonic() + args.maximum_wait_hours * 3600

    print(f"Waiting for Wispr job {args.expected_job}", flush=True)
    while batch_running(jobs_dir):
        if time.monotonic() >= deadline:
            raise RuntimeError("Timed out waiting for Wispr collection")
        time.sleep(20)
    job = read_job(jobs_dir, args.expected_job)

    subprocess.run(
        [sys.executable, str(SCRIPT_DIR / "build_wispr_youtube_campaign.py"),
         "--collection-root", str(collection_root), "--source-table", str(sources),
         "--jobs-dir", str(jobs_dir), "--output-root", str(importer)],
        check=True,
    )
    asr_command = [
        sys.executable, str(SCRIPT_DIR / "prepare_wispr_teacher_asr.py"),
        "--input", str(importer / "teacher-all.jsonl"),
        "--dataset-root", str(collection_root / "dataset"),
        "--output-root", str(asr), "--archive", str(archive),
        "--freeze-timestamp", "2026-09-24T00:00:00Z",
    ]
    if args.asr_quarantine:
        asr_command.extend(["--quarantine-jsonl", str(args.asr_quarantine.resolve())])
    subprocess.run(asr_command, check=True)
    if batch_running(jobs_dir):
        raise RuntimeError("A new Wispr batch started during finalization; refresh the package later")
    read_job(jobs_dir, args.expected_job)
    import_report = json.loads((importer / "import-report.json").read_text(encoding="utf-8"))
    asr_report = json.loads((asr / "split-report.json").read_text(encoding="utf-8"))
    archive_report = json.loads((asr / "archive-info.json").read_text(encoding="utf-8"))
    report = {
        "schema_version": "voxol-wispr-youtube-finalization-v1",
        "job_file": args.expected_job,
        "job_complete": bool(job.get("complete")),
        "job_statuses": dict(Counter(str(item.get("status", "pending")) for item in job["items"])),
        "source_video_count": import_report["source_video_count"],
        "present_source_count": import_report["present_source_count"],
        "teacher_chunk_count": import_report["teacher_chunk_count"],
        "asr_included_count": asr_report["filter"]["includedItemCount"],
        "asr_excluded_count": asr_report["filter"]["excludedItemCount"],
        "asr_quarantine_count": asr_report["filter"]["quarantinedItemCount"],
        "asr_quarantine_sha256": asr_report["filter"]["quarantineManifestSHA256"],
        "qwen_edited_target_count": import_report["qwen_edited_target_count"],
        "archive": archive_report,
        "label_status": "silver; not human gold or an independent benchmark",
    }
    temporary = prepared / f"finalization-report.json.partial.{os.getpid()}"
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, prepared / "finalization-report.json")
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
