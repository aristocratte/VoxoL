#!/usr/bin/env python3
"""Freeze the partial YouTube teacher lot and make every clip reviewable.

This prepares experimental inputs only. It never starts training or grants
human approval to Wispr, Luna, or VoxoL text.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path

import yaml


MODEL_FILES = ("config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_global_approval(root: Path, handoff: dict[str, object]) -> dict[str, object] | None:
    """Read owner consent for this snapshot without asserting audio review."""
    path = root / "user-approval.json"
    if not path.exists():
        return None
    receipt = json.loads(path.read_text(encoding="utf-8"))
    if (
        receipt.get("schema") != "voxol-youtube-global-user-approval-v1"
        or receipt.get("approved") is not True
        or receipt.get("scope") != "all_segments_in_frozen_queue"
        or receipt.get("queue_sha256") != handoff["queue_sha256"]
        or receipt.get("segment_count") != handoff["queue_count"]
        or receipt.get("inputs") != handoff.get("inputs", {})
        or receipt.get("qwen_pilot_config") != handoff.get("qwen_pilot_config")
    ):
        raise ValueError("Global user approval does not match this frozen handoff")
    return receipt


def read_jsonl(path: Path) -> list[dict[str, object]]:
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
    if any(not isinstance(row, dict) for row in rows):
        raise ValueError(f"Expected JSONL objects: {path}")
    ids = [str(row.get("id", "")) for row in rows]
    if "" in ids or len(ids) != len(set(ids)):
        raise ValueError(f"Missing or duplicate IDs: {path}")
    return rows


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.partial.{os.getpid()}")
    temporary.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.partial.{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as output:
        for row in rows:
            output.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(temporary, path)


def split_by_recording(report: dict[str, object]) -> dict[str, str]:
    result: dict[str, str] = {}
    for group in report["groups"]:
        split = str(group["split"])
        if split not in {"train", "validation", "test"}:
            raise ValueError(f"Unknown split: {split}")
        for recording in group["recordings"]:
            key = str(recording)
            if key in result:
                raise ValueError(f"Recording is in more than one split: {key}")
            result[key] = split
    return result


def priority(split: str, candidate_status: str, flags: list[str]) -> int:
    heldout = split in {"validation", "test"}
    if candidate_status == "accepted":
        return 0 if heldout else 1
    if any(flag in flags for flag in ("luna_needs_audio", "luna_numeric_warning", "asr_quarantine")):
        return 2 if heldout else 3
    if split == "unassigned":
        return 6
    if "wispr_edited_failed" in flags or "wispr_raw_failed" in flags:
        return 5
    return 4 if heldout else 5


def build_queue(
    teacher: list[dict[str, object]],
    luna: list[dict[str, object]],
    predictions: list[dict[str, object]],
    candidate_rows: list[dict[str, object]],
    rejected_ids: set[str],
    warning_ids: set[str],
    quarantine_ids: set[str],
    split_map: dict[str, str],
    dataset_root: Path,
) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    reviews = {str(row["id"]): row for row in luna}
    runtime = {str(row["id"]): row for row in predictions}
    candidates = {str(row["id"]): row for row in candidate_rows}
    if not set(reviews).issubset({str(row["id"]) for row in teacher}):
        raise ValueError("Luna review contains IDs absent from teacher data")
    if not set(candidates).issubset(set(runtime)):
        raise ValueError("Qwen candidates lack their matching runtime prediction")
    if not rejected_ids.issubset(set(candidates)):
        raise ValueError("Builder rejected IDs absent from source candidates")
    root = dataset_root.resolve()
    queue: list[dict[str, object]] = []
    failures: list[dict[str, object]] = []
    for row in teacher:
        identifier = str(row["id"])
        review = reviews.get(identifier)
        prediction = runtime.get(identifier)
        candidate = candidates.get(identifier)
        if review and (review.get("audio_sha256") != row.get("audio_sha256") or review.get("raw_original") != row.get("raw") or review.get("edited_original") != row.get("edited")):
            raise ValueError(f"Stale Luna review: {identifier}")
        relative = Path(str(row["audio_path"]))
        audio = (root / relative).resolve()
        if relative.is_absolute() or not audio.is_relative_to(root) or not audio.is_file():
            raise ValueError(f"Missing or unsafe clip: {identifier}")
        if not isinstance(row.get("audio_sha256"), str) or len(str(row["audio_sha256"])) != 64:
            raise ValueError(f"Missing audio digest: {identifier}")
        split = split_map.get(str(row["recording_id"]), "unassigned")
        flags: list[str] = []
        if row.get("raw_http_status") != "200":
            flags.append("wispr_raw_failed")
        if row.get("edited_http_status") != "200":
            flags.append("wispr_edited_failed")
        if review and review.get("decision") == "needs_audio":
            flags.append("luna_needs_audio")
        if identifier in warning_ids:
            flags.append("luna_numeric_warning")
        if identifier in quarantine_ids:
            flags.append("asr_quarantine")
        if split == "unassigned":
            flags.append("missing_frozen_split")
        candidate_status = "not_candidate"
        if candidate:
            candidate_status = "rejected" if identifier in rejected_ids else "accepted"
            if candidate_status == "rejected":
                flags.append("qwen_builder_rejected")
        item = {
            "id": identifier,
            "audio_path": relative.as_posix(),
            "audio_sha256": row["audio_sha256"],
            "duration_seconds": row.get("duration_seconds"),
            "source_video_id": row["source_video_id"],
            "source_url": row.get("source_url"),
            "recording_id": row["recording_id"],
            "chunk": row["chunk"],
            "start_seconds": row.get("start_seconds"),
            "end_seconds": row.get("end_seconds"),
            "language": row.get("requested_language"),
            "split": split,
            "flags": flags,
            "priority": priority(split, candidate_status, flags),
            "qwen_candidate_status": candidate_status,
            "wispr_raw_status": row.get("raw_http_status"),
            "wispr_edited_status": row.get("edited_http_status"),
            "wispr_raw": row.get("raw") or "",
            "wispr_edited": row.get("edited") or "",
            "luna_decision": review.get("decision") if review else None,
            "luna_proposed": review.get("proposed_text") if review else "",
            "luna_issues": review.get("issues", []) if review else [],
            "voxol_raw": prediction.get("rawText", "") if prediction else "",
            "qwen_silver_target": candidate.get("target_text", "") if candidate else "",
            "humanReviewed": False,
            "audio_verified": False,
            "approved": False,
        }
        queue.append(item)
        if "wispr_raw_failed" in flags or "wispr_edited_failed" in flags:
            failures.append({
                "id": identifier,
                "audio_path": relative.as_posix(),
                "audio_sha256": row["audio_sha256"],
                "source_video_id": row["source_video_id"],
                "raw_http_status": row.get("raw_http_status"),
                "edited_http_status": row.get("edited_http_status"),
                "split": split,
                "flags": [flag for flag in flags if flag.startswith("wispr_")],
            })
    queue.sort(key=lambda item: (int(item["priority"]), str(item["language"]), str(item["source_video_id"]), int(item["chunk"])))
    failures.sort(key=lambda item: (str(item["source_video_id"]), str(item["id"])))
    return queue, failures


def pilot_config(model: Path, data: Path, adapter: Path) -> str:
    values = {
        "model": str(model.resolve()),
        "train": True,
        "data": str(data.resolve()),
        "fine_tune_type": "lora",
        "optimizer": "adamw",
        "mask_prompt": True,
        "adapter_path": str(adapter.resolve()),
        "num_layers": 4,
        "batch_size": 1,
        "grad_accumulation_steps": 8,
        "learning_rate": 2.0e-5,
        "iters": 80,
        "steps_per_report": 10,
        "steps_per_eval": 20,
        "save_every": 20,
        "val_batches": -1,
        "max_seq_length": 768,
        "seed": 1729,
        "test": False,
        "lora_parameters": {
            "keys": ["self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj", "linear_attn.in_proj_qkv", "linear_attn.in_proj_z", "linear_attn.out_proj"],
            "rank": 4,
            "scale": 8.0,
            "dropout": 0.05,
        },
    }
    return yaml.safe_dump(values, allow_unicode=True, sort_keys=False)


def prepare(collection_root: Path, output_root: Path, model_path: Path) -> dict[str, object]:
    if (output_root / "user-approval.json").exists():
        raise RuntimeError("This handoff has user approval; use a new output root for a new snapshot")
    root = collection_root.resolve()
    prepared = root / "prepared"
    qwen = prepared / "qwen-youtube-experimental-20260925"
    sources = {
        "teacher": prepared / "import/teacher-all.jsonl",
        "luna": prepared / "luna-edited-review-20260925/all-reviewed-ai-silver.jsonl",
        "luna_audit": prepared / "luna-edited-review-20260925/full-campaign-audit.json",
        "predictions": qwen / "runtime/runtime-predictions.jsonl",
        "qwen_candidates": qwen / "source/source.jsonl",
        "builder_summary": qwen / "mlx-data/summary.json",
        "split_report": prepared / "asr-silver/split-report.json",
        "asr_quarantine": prepared / "asr-risk-quarantine-20260925.jsonl",
        "asr_archive": prepared / "asr-silver.tar.gz",
        "readiness": prepared / "training-readiness-20260925.json",
        "qwen_train": qwen / "mlx-data/train.jsonl",
        "qwen_valid": qwen / "mlx-data/valid.jsonl",
        "qwen_test": qwen / "mlx-data/test.jsonl",
    }
    for name, path in sources.items():
        if not path.is_file():
            raise FileNotFoundError(f"Missing {name}: {path}")
    for name in MODEL_FILES:
        if not (model_path / name).is_file():
            raise FileNotFoundError(f"Missing local parent model file: {name}")
    readiness = json.loads(sources["readiness"].read_text(encoding="utf-8"))
    if readiness.get("trainingLaunched") is not False or readiness.get("independentHumanBenchmark") is not False:
        raise ValueError("Readiness assumptions changed; review the current state")
    teacher = read_jsonl(sources["teacher"])
    luna = read_jsonl(sources["luna"])
    predictions = read_jsonl(sources["predictions"])
    candidates = read_jsonl(sources["qwen_candidates"])
    builder = json.loads(sources["builder_summary"].read_text(encoding="utf-8"))
    audit = json.loads(sources["luna_audit"].read_text(encoding="utf-8"))
    queue, failures = build_queue(
        teacher, luna, predictions, candidates,
        set(builder["rejected_ids"]),
        {str(row["id"]) for row in audit["warnings"]},
        {str(row["id"]) for row in read_jsonl(sources["asr_quarantine"])},
        split_by_recording(json.loads(sources["split_report"].read_text(encoding="utf-8"))),
        root / "dataset",
    )
    if len(queue) != readiness["teacherChunks"] or len(luna) != readiness["qwenExperimental"]["reviewedTextRows"]:
        raise ValueError("Queue size differs from frozen readiness report")
    expected_accepted = readiness["qwenExperimental"]["acceptedCount"]
    if sum(item["qwen_candidate_status"] == "accepted" for item in queue) != expected_accepted:
        raise ValueError("Accepted Qwen count differs from frozen readiness report")
    output_root.mkdir(parents=True, exist_ok=True)
    queue_path = output_root / "review-queue.jsonl"
    old_state_path = output_root / "review-state.json"
    if old_state_path.exists() and json.loads(old_state_path.read_text(encoding="utf-8")).get("reviews"):
        raise RuntimeError("Review state is nonempty; refusing to replace its queue")
    write_jsonl(queue_path, queue)
    write_jsonl(output_root / "wispr-failed-chunks.jsonl", failures)
    queue_digest = sha256(queue_path)
    state = {"schema": "voxol-youtube-manual-review-state-v1", "queue_sha256": queue_digest, "reviews": {}, "updated_at_utc": None}
    write_json(old_state_path, state)
    config_path = output_root / "qwen-silver-pilot.yaml"
    config_path.write_text(pilot_config(model_path, qwen / "mlx-data", output_root / "artifacts/qwen-silver-pilot"), encoding="utf-8")
    input_hashes = {name: {"path": str(path.resolve()), "sha256": sha256(path)} for name, path in sources.items()}
    if input_hashes["asr_archive"]["sha256"] != readiness["asrSilver"]["sha256"]:
        raise ValueError("ASR archive changed since readiness report")
    model_hashes = {name: sha256(model_path / name) for name in MODEL_FILES}
    counts = Counter(flag for item in queue for flag in item["flags"])
    summary = {
        "schema": "voxol-youtube-training-handoff-v1",
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "status": "experimental_silver_prepared_not_trained",
        "collection_root": str(root),
        "dataset_root": str((root / "dataset").resolve()),
        "queue_count": len(queue),
        "queue_sha256": queue_digest,
        "failed_chunk_count": len(failures),
        "flags": dict(sorted(counts.items())),
        "qwen_accepted_count": expected_accepted,
        "qwen_builder_rejected_count": len(builder["rejected_ids"]),
        "qwen_pilot_config": {"path": str(config_path), "sha256": sha256(config_path)},
        "qwen_parent_model": {"path": str(model_path.resolve()), "files_sha256": model_hashes},
        "inputs": input_hashes,
        "manual_review_state": str(old_state_path),
        "human_gold_count": 0,
        "independent_human_benchmark": False,
        "training_launched": False,
    }
    write_json(output_root / "handoff.json", summary)
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collection-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--model-path", type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.collection_root, args.output_root, args.model_path)
    print(json.dumps({key: result[key] for key in ("status", "queue_count", "failed_chunk_count", "qwen_accepted_count", "human_gold_count")}, sort_keys=True))


if __name__ == "__main__":
    main()
