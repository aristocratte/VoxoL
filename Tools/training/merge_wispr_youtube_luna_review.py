#!/usr/bin/env python3
"""Freeze a complete Luna text-review snapshot after a Wispr retry changes rows."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

from prepare_wispr_youtube_qwen import digest, read_rows, write_json, write_jsonl


def source_matches(review: dict[str, object], teacher: dict[str, object]) -> bool:
    return all((review.get(left) == teacher.get(right)) for left, right in (
        ("audio_sha256", "audio_sha256"),
        ("audio_path", "audio_path"),
        ("raw_original", "raw"),
        ("edited_original", "edited"),
    ))


def make_review(teacher: dict[str, object], addendum: dict[str, object], dataset_root: Path) -> dict[str, object]:
    decision = addendum.get("decision")
    if decision not in {"keep", "correct", "needs_audio"}:
        raise ValueError(f"Invalid decision: {teacher['id']}")
    proposal = addendum.get("proposed_text")
    if decision == "correct" and (not isinstance(proposal, str) or not proposal.strip()):
        raise ValueError(f"Missing correction: {teacher['id']}")
    if decision != "correct":
        proposal = teacher["edited"]
    raw = str(teacher["raw"])
    edited = str(teacher["edited"])
    return {
        "id": teacher["id"],
        "source_video_id": teacher["source_video_id"],
        "audio_path": teacher["audio_path"],
        "audio_path_absolute": str((dataset_root / str(teacher["audio_path"])).resolve()),
        "audio_sha256": teacher["audio_sha256"],
        "start_seconds": teacher["start_seconds"],
        "end_seconds": teacher["end_seconds"],
        "requested_language": teacher["requested_language"],
        "detected_language": teacher["detected_language"],
        "raw_original": raw,
        "raw_sha256": hashlib.sha256(raw.encode()).hexdigest(),
        "edited_original": edited,
        "edited_sha256": hashlib.sha256(edited.encode()).hexdigest(),
        "proposed_text": proposal,
        "decision": decision,
        "issues": addendum["issues"],
        "rationale": addendum["rationale"],
        "confidence": addendum["confidence"],
        "review_model": "gpt-6-luna",
        "review_effort": "max",
        "source": "ai-curated-experimental",
        "approved": False,
        "humanReviewed": False,
        "audio_verified": False,
    }


def merge(
    teacher_path: Path,
    original_review_path: Path,
    original_audit_path: Path,
    addendum_path: Path,
    dataset_root: Path,
    output_root: Path,
) -> dict[str, object]:
    teacher_rows = read_rows(teacher_path)
    prior_rows = read_rows(original_review_path)
    additions = read_rows(addendum_path)
    prior = {str(row["id"]): row for row in prior_rows}
    addendum = {str(row["id"]): row for row in additions}
    edited_rows = [row for row in teacher_rows if row.get("edited_http_status") == "200"]
    edited_ids = {str(row["id"]) for row in edited_rows}
    if addendum.keys() - edited_ids:
        raise ValueError("Addendum includes IDs without edited Wispr text")
    full = []
    for teacher in edited_rows:
        identifier = str(teacher["id"])
        if identifier in addendum:
            review = make_review(teacher, addendum[identifier], dataset_root)
        else:
            review = prior.get(identifier)
            if review is None or not source_matches(review, teacher):
                raise ValueError(f"Review missing or stale: {identifier}")
        if review.get("approved") is not False or review.get("humanReviewed") is not False or review.get("audio_verified") is not False:
            raise ValueError(f"Unexpected approval status: {identifier}")
        full.append(review)
    old_audit = json.loads(original_audit_path.read_text(encoding="utf-8"))
    warnings = [row for row in old_audit.get("warnings", []) if str(row["id"]) not in addendum]
    for review in full:
        if str(review["id"]) not in addendum:
            continue
        before = [word for word in str(review["edited_original"]).split() if any(char.isdigit() for char in word)]
        after = [word for word in str(review["proposed_text"]).split() if any(char.isdigit() for char in word)]
        if before != after:
            warnings.append({"id": review["id"], "issue": "number_tokens_changed"})
    output_root.mkdir(parents=True, exist_ok=True)
    full_path = output_root / "all-reviewed-ai-silver.jsonl"
    write_jsonl(full_path, full)
    audit: dict[str, object] = {
        "schema": "wispr-luna-catchup-audit-v1",
        "source_sha256": digest(teacher_path),
        "source_rows": len(teacher_rows),
        "eligible_edited_rows": len(edited_rows),
        "reviewed_rows": len(full),
        "coverage_percent": 100.0,
        "remaining_rows": 0,
        "decisions": dict(sorted(Counter(str(row["decision"]) for row in full).items())),
        "catchup_review_rows": len(additions),
        "source_review_sha256": digest(original_review_path),
        "addendum_sha256": digest(addendum_path),
        "full_review_sha256": digest(full_path),
        "warnings": warnings,
        "snapshot_complete": True,
        "approved": False,
        "humanReviewed": False,
        "audio_verified": False,
    }
    write_json(output_root / "full-campaign-audit.json", audit)
    return audit


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--teacher", type=Path, required=True)
    parser.add_argument("--original-review", type=Path, required=True)
    parser.add_argument("--original-audit", type=Path, required=True)
    parser.add_argument("--addendum", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(merge(
        args.teacher, args.original_review, args.original_audit,
        args.addendum, args.dataset_root, args.output_root,
    ), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
