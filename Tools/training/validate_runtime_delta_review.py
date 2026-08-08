#!/usr/bin/env python3
"""Validate one runtime-aware VoxoL delta review."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

from jsonschema import Draft202012Validator

from validate_review_output_v2 import input_sha256


def validate_delta_review(
    input_data: dict[str, Any],
    review: dict[str, Any],
    schema: dict[str, Any],
) -> list[str]:
    errors = [
        f"schema:{'/'.join(map(str, error.path)) or '<root>'}: {error.message}"
        for error in sorted(
            Draft202012Validator(schema).iter_errors(review),
            key=lambda value: [str(part) for part in value.path],
        )
    ]
    expected_hash = input_sha256(input_data)
    if input_data.get("input_sha256") != expected_hash:
        errors.append("input file integrity failure")
    if review.get("id") != input_data.get("id"):
        errors.append("id mismatch")
    if review.get("input_sha256") != expected_hash:
        errors.append("input_sha256 mismatch")

    decision = review.get("decision")
    target = review.get("final_target")
    baseline = input_data.get("deterministic_baseline")
    candidate = input_data.get("gpt_target_candidate")
    if decision == "keep_deterministic_baseline" and target != baseline:
        errors.append("keep_deterministic_baseline requires the exact baseline")
    if decision == "accept_gpt_target" and target != candidate:
        errors.append("accept_gpt_target requires the exact candidate")
    if decision == "replace_with_better_target":
        if not isinstance(target, str) or not target.strip():
            errors.append("replace_with_better_target requires non-empty text")
        elif target in {baseline, candidate}:
            errors.append("replace_with_better_target must differ from both supplied texts")
    if decision == "exclude_unrecoverable" and target is not None:
        errors.append("exclude_unrecoverable requires final_target=null")
    if isinstance(target, str):
        if "VOXOLP" in target:
            errors.append("final_target must contain restored values, not placeholders")
        raw = str(input_data.get("raw", ""))
        if len(target) > int(len(raw) * 1.5) + 64:
            errors.append("final_target is implausibly longer than raw")
    return list(dict.fromkeys(errors))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--review", required=True, type=Path)
    parser.add_argument("--schema", required=True, type=Path)
    arguments = parser.parse_args()
    input_data = json.loads(arguments.input.read_text(encoding="utf-8"))
    review = json.loads(arguments.review.read_text(encoding="utf-8"))
    schema = json.loads(arguments.schema.read_text(encoding="utf-8"))
    errors = validate_delta_review(input_data, review, schema)
    print(json.dumps({"valid": not errors, "errors": errors}, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
