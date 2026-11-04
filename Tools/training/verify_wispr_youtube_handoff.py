#!/usr/bin/env python3
"""Check the frozen Wispr/MLX handoff before an experimental training run."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path

from transformers import AutoTokenizer
import yaml

try:
    from Tools.training.prepare_wispr_youtube_handoff import load_global_approval, read_jsonl, sha256, write_json
except ModuleNotFoundError:
    from prepare_wispr_youtube_handoff import load_global_approval, read_jsonl, sha256, write_json


def require_sha(path: Path, expected: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(path)
    actual = sha256(path)
    if actual != expected:
        raise ValueError(f"SHA-256 changed: {path}: {actual}")


def verify(root: Path) -> dict[str, object]:
    handoff = json.loads((root / "handoff.json").read_text(encoding="utf-8"))
    approval = load_global_approval(root, handoff)
    require_sha(root / "review-queue.jsonl", handoff["queue_sha256"])
    for artifact in handoff["inputs"].values():
        require_sha(Path(artifact["path"]), artifact["sha256"])
    config_info = handoff["qwen_pilot_config"]
    require_sha(Path(config_info["path"]), config_info["sha256"])
    model_info = handoff["qwen_parent_model"]
    model = Path(model_info["path"])
    for filename, expected in model_info["files_sha256"].items():
        require_sha(model / filename, expected)
    config = yaml.safe_load(Path(config_info["path"]).read_text(encoding="utf-8"))
    if not isinstance(config["learning_rate"], float) or config["train"] is not True:
        raise ValueError("Invalid Qwen pilot configuration")
    if Path(config["model"]).resolve() != model.resolve():
        raise ValueError("Qwen config uses another parent model")
    data = Path(config["data"]).resolve()
    tokenizer = AutoTokenizer.from_pretrained(str(model), local_files_only=True, trust_remote_code=True)
    lengths: dict[str, dict[str, int]] = {}
    for split, filename in (("train", "train.jsonl"), ("validation", "valid.jsonl"), ("test", "test.jsonl")):
        rows = [json.loads(line) for line in (data / filename).read_text(encoding="utf-8").splitlines() if line]
        if not rows or any(not isinstance(row, dict) or "messages" not in row for row in rows):
            raise ValueError(f"Invalid MLX {split} rows")
        tokens = [len(tokenizer.apply_chat_template(row["messages"], tokenize=True)["input_ids"]) for row in rows]
        if max(tokens) > config["max_seq_length"]:
            raise ValueError(f"Qwen {split} examples would be truncated: max={max(tokens)}")
        lengths[split] = {"rows": len(rows), "max_tokens": max(tokens)}
    if sum(value["rows"] for value in lengths.values()) != handoff["qwen_accepted_count"]:
        raise ValueError("MLX split counts differ from accepted source pairs")
    queue = read_jsonl(root / "review-queue.jsonl")
    if len(queue) != handoff["queue_count"]:
        raise ValueError("Queue count changed")
    review_state = json.loads((root / "review-state.json").read_text(encoding="utf-8"))
    if review_state["queue_sha256"] != handoff["queue_sha256"]:
        raise ValueError("Human review state refers to another queue")
    report = {
        "schema": "voxol-youtube-training-handoff-preflight-v1",
        "verified_at_utc": datetime.now(timezone.utc).isoformat(),
        "frozen_inputs_valid": True,
        "globally_user_approved_segments": approval["segment_count"] if approval else 0,
        "experimental_dataset_user_approved": approval is not None,
        "qwen_max_seq_length": config["max_seq_length"],
        "qwen_splits": lengths,
        "asr_archive_sha256": handoff["inputs"]["asr_archive"]["sha256"],
        "qwen_parent_model_weight_sha256": model_info["files_sha256"]["model.safetensors"],
        "human_verified_current": sum(row.get("status") == "verified" for row in review_state["reviews"].values()),
        "human_promotion_ready": False,
        "training_launched": False,
    }
    write_json(root / "preflight.json", report)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--handoff-root", type=Path, required=True)
    args = parser.parse_args()
    report = verify(args.handoff_root)
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
