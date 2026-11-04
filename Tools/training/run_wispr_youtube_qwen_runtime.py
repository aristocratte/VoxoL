#!/usr/bin/env python3
"""Resume audio-only VoxoL raw inference for eligible YouTube Qwen candidates.

The source labels never enter the ASR inference manifest. Completed shards are
bound to their exact manifest, model report and executable before reuse.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

from prepare_wispr_youtube_qwen import (
    digest, read_rows, reviewed_targets, split_map, write_json, write_jsonl,
)


SAFE_VIDEO_ID = re.compile(r"[A-Za-z0-9_-]{6,32}\Z")


def model_fingerprint(root: Path) -> str:
    value = hashlib.sha256()
    files = sorted(path for path in root.rglob("*") if path.is_file())
    if not files:
        raise ValueError(f"Empty model root: {root}")
    for path in files:
        value.update(path.relative_to(root).as_posix().encode())
        value.update(b"\0")
        value.update(bytes.fromhex(digest(path)))
    return value.hexdigest()


def shard_items(eligible: list[dict[str, object]], maximum: int) -> list[tuple[str, list[dict[str, object]]]]:
    by_video: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in eligible:
        teacher = row["teacher"]
        video = str(teacher["source_video_id"])
        if not SAFE_VIDEO_ID.fullmatch(video):
            raise ValueError(f"Unsafe video ID: {video!r}")
        by_video[video].append({
            "id": str(teacher["id"]),
            "audioPath": str(teacher["audio_path"]),
            "audioSHA256": str(teacher["audio_sha256"]),
        })
    result = []
    for video, items in sorted(by_video.items()):
        items.sort(key=lambda item: item["id"])
        for offset in range(0, len(items), maximum):
            result.append((f"{video}-{offset // maximum:03d}", items[offset:offset + maximum]))
    return result


def run(
    teacher_path: Path,
    review_path: Path,
    audit_path: Path,
    split_path: Path,
    dataset_root: Path,
    model_root: Path,
    binary: Path,
    output_root: Path,
    maximum_per_shard: int,
) -> dict[str, object]:
    if not 1 <= maximum_per_shard <= 500:
        raise ValueError("--maximum-per-shard must be between 1 and 500")
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f"Missing executable: {binary}")
    model_report = model_root / "quantization-report.json"
    if not model_report.is_file():
        raise ValueError(f"Missing model report: {model_report}")
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    review_rows = read_rows(review_path)
    if not audit.get("snapshot_complete") or audit.get("reviewed_rows") != len(review_rows):
        raise ValueError("Luna audit incomplete")
    eligible, excluded = reviewed_targets(
        read_rows(teacher_path), review_rows,
        {str(item["id"]) for item in audit.get("warnings", [])},
        split_map(split_path),
    )
    shards = shard_items(eligible, maximum_per_shard)
    if not shards:
        raise ValueError("No eligible audio clips")
    manifest_dir = output_root / "manifests"
    prediction_dir = output_root / "predictions"
    log_dir = output_root / "logs"
    for directory in (manifest_dir, prediction_dir, log_dir):
        directory.mkdir(parents=True, exist_ok=True)
    teacher_hash = digest(teacher_path)
    binary_hash = digest(binary)
    model_hash = digest(model_report)
    weights_hash = model_fingerprint(model_root)
    combined: list[dict[str, object]] = []
    for index, (name, items) in enumerate(shards, 1):
        manifest_path = manifest_dir / f"{name}.json"
        manifest = {
            "schemaVersion": 1,
            "sourceManifestSHA256": teacher_hash,
            "items": items,
        }
        expected_text = json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
        if manifest_path.exists() and manifest_path.read_text(encoding="utf-8") != expected_text:
            raise ValueError(f"Inference shard manifest changed: {manifest_path}")
        if not manifest_path.exists():
            write_json(manifest_path, manifest)
        expected = {str(item["id"]) for item in items}
        prediction_path = prediction_dir / f"{name}.jsonl"
        marker_path = prediction_dir / f"{name}.complete.json"
        marker_expected = {
            "manifest_sha256": digest(manifest_path),
            "binary_sha256": binary_hash,
            "model_report_sha256": model_hash,
            "model_tree_sha256": weights_hash,
            "model_root": str(model_root.resolve()),
        }
        if marker_path.exists():
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            if any(marker.get(key) != value for key, value in marker_expected.items()):
                raise ValueError(f"Completed shard provenance changed: {name}")
            if marker.get("prediction_sha256") != digest(prediction_path):
                raise ValueError(f"Completed shard predictions changed: {name}")
            predictions = read_rows(prediction_path)
            if {str(row["id"]) for row in predictions} != expected:
                raise ValueError(f"Completed shard IDs changed: {name}")
            print(f"[{index}/{len(shards)}] reuse {name}: {len(predictions)}", flush=True)
        else:
            if prediction_path.exists():
                raise ValueError(f"Unmarked predictions need inspection: {prediction_path}")
            temporary = prediction_dir / f"{name}.running.jsonl"
            if temporary.exists():
                stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
                temporary.rename(prediction_dir / f"{name}.incomplete-{stamp}.jsonl")
            log_path = log_dir / f"{name}.log"
            print(f"[{index}/{len(shards)}] infer {name}: {len(items)}", flush=True)
            with log_path.open("w", encoding="utf-8") as log:
                completed = subprocess.run([
                    str(binary), "infer-parakeet", "--manifest", str(manifest_path),
                    "--audio-root", str(dataset_root), "--model-root", str(model_root),
                    "--compute-units", "all", "--output", str(temporary),
                ], stdout=log, stderr=subprocess.STDOUT, check=False)
            if completed.returncode:
                raise RuntimeError(f"ASR inference failed for {name} (exit {completed.returncode}); see {log_path}")
            predictions = read_rows(temporary)
            if {str(row["id"]) for row in predictions} != expected:
                raise ValueError(f"Incomplete ASR predictions for {name}")
            os.replace(temporary, prediction_path)
            write_json(marker_path, {
                **marker_expected,
                "prediction_sha256": digest(prediction_path),
                "prediction_count": len(predictions),
            })
        combined.extend(predictions)
    combined.sort(key=lambda row: str(row["id"]))
    combined_path = output_root / "runtime-predictions.jsonl"
    write_jsonl(combined_path, combined)
    report: dict[str, object] = {
        "schema": "voxol-youtube-qwen-runtime-v1",
        "teacher_sha256": teacher_hash,
        "luna_review_sha256": digest(review_path),
        "luna_audit_sha256": digest(audit_path),
        "split_report_sha256": digest(split_path),
        "binary_sha256": binary_hash,
        "model_report_sha256": model_hash,
        "model_tree_sha256": weights_hash,
        "model_root": str(model_root.resolve()),
        "eligible_item_count": len(eligible),
        "excluded_before_inference": len(excluded),
        "shard_count": len(shards),
        "prediction_count": len(combined),
        "predictions_sha256": digest(combined_path),
        "labels_seen_by_asr": False,
        "review_policy": "ai-curated-experimental",
    }
    write_json(output_root / "runtime-report.json", report)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teacher", type=Path, required=True)
    parser.add_argument("--luna-review", type=Path, required=True)
    parser.add_argument("--luna-audit", type=Path, required=True)
    parser.add_argument("--split-report", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--model-root", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--maximum-per-shard", type=int, default=128)
    args = parser.parse_args()
    print(json.dumps(run(
        args.teacher, args.luna_review, args.luna_audit, args.split_report,
        args.dataset_root, args.model_root, args.binary, args.output_root,
        args.maximum_per_shard,
    ), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
