#!/usr/bin/env python3
"""Build an experimental Qwen corpus from matching VoxoL and Wispr audio clips.

The Wispr text and the text-only Luna review remain silver targets. This tool
never grants human approval or promotes its test split to a benchmark.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re

from prepare_wispr_qwen_dataset import quality_reasons, normalized_text


HTML_TAG = re.compile(r"</?[A-Za-z][^>]*>")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def read_rows(path: Path) -> list[dict[str, object]]:
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
    if not rows or any(not isinstance(row, dict) for row in rows):
        raise ValueError(f"Empty or invalid JSONL: {path}")
    ids = [str(row.get("id", "")) for row in rows]
    if "" in ids or len(ids) != len(set(ids)):
        raise ValueError(f"Missing or duplicate IDs: {path}")
    return rows


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.partial.{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(temporary, path)


def write_json(path: Path, value: dict[str, object]) -> None:
    temporary = path.with_name(f"{path.name}.partial.{os.getpid()}")
    temporary.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def split_map(path: Path) -> dict[str, str]:
    report = json.loads(path.read_text(encoding="utf-8"))
    result: dict[str, str] = {}
    for group in report["groups"]:
        split = str(group["split"])
        if split not in {"train", "validation", "test"}:
            raise ValueError(f"Invalid split: {split}")
        for recording in group["recordings"]:
            key = str(recording)
            if key in result:
                raise ValueError(f"Recording assigned twice: {key}")
            result[key] = split
    return result


def reviewed_targets(
    teacher_rows: list[dict[str, object]],
    review_rows: list[dict[str, object]],
    warning_ids: set[str],
    splits: dict[str, str],
) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    reviews = {str(row["id"]): row for row in review_rows}
    eligible: list[dict[str, object]] = []
    excluded: list[dict[str, object]] = []
    for teacher in teacher_rows:
        identifier = str(teacher["id"])
        reasons: list[str] = []
        if teacher.get("raw_http_status") != "200" or not normalized_text(teacher.get("raw")):
            reasons.append("wispr_raw_unavailable")
        if teacher.get("edited_http_status") != "200" or not normalized_text(teacher.get("edited")):
            reasons.append("wispr_edited_unavailable")
        if teacher.get("requested_language") != teacher.get("detected_language"):
            reasons.append("language_mismatch")
        recording = str(teacher.get("recording_id", ""))
        if recording not in splits:
            reasons.append("missing_split")
        review = reviews.get(identifier)
        if teacher.get("edited_http_status") == "200":
            if review is None:
                reasons.append("missing_luna_review")
            else:
                if (
                    review.get("audio_sha256") != teacher.get("audio_sha256")
                    or review.get("audio_path") != teacher.get("audio_path")
                ):
                    raise ValueError(f"Luna audio identity mismatch: {identifier}")
                if (
                    review.get("raw_original") != teacher.get("raw")
                    or review.get("edited_original") != teacher.get("edited")
                ):
                    reasons.append("stale_luna_review")
                if review.get("approved") is not False or review.get("humanReviewed") is not False:
                    raise ValueError(f"Unexpected review approval: {identifier}")
                if review.get("decision") not in {"correct", "keep", "needs_audio"}:
                    raise ValueError(f"Unknown Luna decision: {identifier}")
                if review["decision"] == "needs_audio":
                    reasons.append("needs_audio_review")
                if identifier in warning_ids:
                    reasons.append("luna_numeric_warning")
        if reasons:
            excluded.append({"id": identifier, "reasons": sorted(set(reasons))})
            continue
        assert review is not None
        target = str(review["proposed_text"] if review["decision"] == "correct" else teacher["edited"])
        if not normalized_text(target) or HTML_TAG.search(target):
            excluded.append({"id": identifier, "reasons": ["empty_or_markup_target"]})
            continue
        eligible.append({
            "teacher": teacher,
            "review": review,
            "target": target,
            "split": splits[recording],
        })
    return eligible, excluded


def prepare(
    teacher_path: Path,
    review_path: Path,
    audit_path: Path,
    split_path: Path,
    prediction_path: Path,
    runtime_report_path: Path,
    dataset_root: Path,
    output_root: Path,
) -> dict[str, object]:
    teacher_rows = read_rows(teacher_path)
    review_rows = read_rows(review_path)
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    if audit.get("reviewed_rows") != len(review_rows) or not audit.get("snapshot_complete"):
        raise ValueError("Luna review audit is incomplete")
    warning_ids = {str(row["id"]) for row in audit.get("warnings", [])}
    eligible, excluded = reviewed_targets(
        teacher_rows, review_rows, warning_ids, split_map(split_path)
    )
    runtime_report = json.loads(runtime_report_path.read_text(encoding="utf-8"))
    required_hashes = {
        "teacher_sha256": digest(teacher_path),
        "luna_review_sha256": digest(review_path),
        "luna_audit_sha256": digest(audit_path),
        "split_report_sha256": digest(split_path),
        "predictions_sha256": digest(prediction_path),
    }
    if any(runtime_report.get(key) != value for key, value in required_hashes.items()):
        raise ValueError("Runtime report does not match the frozen Qwen inputs")
    if runtime_report.get("labels_seen_by_asr") is not False:
        raise ValueError("Runtime inference provenance is not audio-only")
    if runtime_report.get("eligible_item_count") != len(eligible):
        raise ValueError("Runtime inference eligibility differs from current review")
    prediction_rows = read_rows(prediction_path)
    if runtime_report.get("prediction_count") != len(prediction_rows):
        raise ValueError("Runtime prediction count differs from its report")
    predictions = {str(row["id"]): row for row in prediction_rows}
    eligible_ids = {str(item["teacher"]["id"]) for item in eligible}
    unexpected = predictions.keys() - eligible_ids
    if unexpected:
        raise ValueError("Runtime predictions contain IDs outside the eligible review")

    examples: list[dict[str, object]] = []
    provenance: list[dict[str, object]] = []
    seen_pairs: set[tuple[str, str, str]] = set()
    root = dataset_root.resolve()
    for item in sorted(eligible, key=lambda value: str(value["teacher"]["id"])):
        teacher = item["teacher"]
        review = item["review"]
        identifier = str(teacher["id"])
        prediction = predictions.get(identifier)
        if prediction is None:
            excluded.append({"id": identifier, "reasons": ["missing_runtime_prediction"]})
            continue
        relative = Path(str(teacher["audio_path"]))
        audio = (root / relative).resolve()
        if relative.is_absolute() or not audio.is_relative_to(root) or digest(audio) != teacher["audio_sha256"]:
            raise ValueError(f"Audio integrity mismatch: {identifier}")
        raw = normalized_text(prediction.get("rawText"))
        target = normalized_text(item["target"])
        quality_row = dict(teacher, raw=raw, edited=target)
        reasons, ratio, edit_rate = quality_reasons(
            quality_row,
            minimum_length_ratio=0.80,
            maximum_length_ratio=1.20,
            maximum_word_edit_rate=0.35,
            minimum_words=3,
            maximum_words=160,
        )
        pair = (str(teacher["requested_language"]), raw, target)
        if pair in seen_pairs:
            reasons.append("duplicate_pair")
        if reasons:
            excluded.append({"id": identifier, "reasons": sorted(set(reasons)),
                             "lengthRatio": round(ratio, 6), "wordEditRate": round(edit_rate, 6)})
            continue
        seen_pairs.add(pair)
        examples.append({
            "after_cursor": "",
            "app_category": "other",
            "approved": False,
            "humanReviewed": False,
            "audio_verified": False,
            "before_cursor": "",
            "dictionary": [],
            "id": identifier,
            "language": teacher["requested_language"],
            "mode": "faithful",
            "operations": ["faithful_cleanup"],
            "profile": "document",
            "protected_tokens": [],
            "raw_transcript": raw,
            "source": "ai-curated-experimental",
            "split": item["split"],
            "split_group": str(teacher["source_video_id"]),
            "target_text": target,
        })
        provenance.append({
            "id": identifier,
            "audio_path": relative.as_posix(),
            "audio_sha256": teacher["audio_sha256"],
            "luna_decision": review["decision"],
            "target_origin": "luna_text_only_candidate" if review["decision"] == "correct" else "wispr_edited",
            "approved": False,
            "humanReviewed": False,
            "audio_verified": False,
            "runtime_raw_sha256": hashlib.sha256(raw.encode()).hexdigest(),
            "target_sha256": hashlib.sha256(target.encode()).hexdigest(),
        })
    excluded.sort(key=lambda item: str(item["id"]))
    output_root.mkdir(parents=True, exist_ok=True)
    write_jsonl(output_root / "source.jsonl", examples)
    write_jsonl(output_root / "provenance.jsonl", provenance)
    write_jsonl(output_root / "excluded.jsonl", excluded)
    reasons = Counter(reason for row in excluded for reason in row["reasons"])
    report: dict[str, object] = {
        "schema": "voxol-wispr-youtube-qwen-experimental-v1",
        "source_rows": len(teacher_rows),
        "luna_review_rows": len(review_rows),
        "eligible_before_runtime": len(eligible),
        "runtime_prediction_rows": len(prediction_rows),
        "unused_runtime_prediction_count": len(unexpected),
        "example_count": len(examples),
        "excluded_count": len(excluded),
        "excluded_by_reason": dict(sorted(reasons.items())),
        "splits": dict(sorted(Counter(str(row["split"]) for row in examples).items())),
        "input_sha256": {name: digest(path) for name, path in {
            "teacher": teacher_path, "luna_review": review_path,
            "luna_audit": audit_path, "split_report": split_path,
            "runtime_predictions": prediction_path, "runtime_report": runtime_report_path,
        }.items()},
        "output_sha256": {name: digest(output_root / f"{name}.jsonl") for name in (
            "source", "provenance", "excluded"
        )},
        "review_policy": "ai-curated-experimental",
        "approved": False,
        "humanReviewed": False,
        "audio_verified": False,
        "complete_for_eligible_runtime_inputs": "missing_runtime_prediction" not in reasons,
        "test_status": "silver control; not independent human benchmark",
    }
    write_json(output_root / "report.json", report)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teacher", type=Path, required=True)
    parser.add_argument("--luna-review", type=Path, required=True)
    parser.add_argument("--luna-audit", type=Path, required=True)
    parser.add_argument("--split-report", type=Path, required=True)
    parser.add_argument("--runtime-predictions", type=Path, required=True)
    parser.add_argument("--runtime-report", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(
        args.teacher, args.luna_review, args.luna_audit, args.split_report,
        args.runtime_predictions, args.runtime_report, args.dataset_root, args.output_root,
    ), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
