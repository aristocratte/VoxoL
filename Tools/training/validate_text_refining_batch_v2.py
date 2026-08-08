#!/usr/bin/env python3
"""Validate and conservatively normalize one VoxoL GPT Pro review batch."""

from __future__ import annotations

import argparse
from collections import Counter
import copy
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
from typing import Any
import zipfile

from validate_review_output_v2 import second_review_reasons, validate_review


ASSET_ROOT = Path(__file__).resolve().parent
DEFAULT_SCHEMA = ASSET_ROOT / "review-output.schema.v2.json"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--batch", required=True, type=Path)
    parser.add_argument("--reviews", required=True, type=Path)
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--normalized-output", type=Path)
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def safe_members(archive: zipfile.ZipFile) -> list[str]:
    if bad_member := archive.testzip():
        raise RuntimeError(f"Corrupt ZIP member: {bad_member}")
    names = archive.namelist()
    for name in names:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts:
            raise RuntimeError(f"Unsafe ZIP member: {name}")
    return names


def read_batch_inputs(path: Path) -> dict[str, dict[str, Any]]:
    inputs: dict[str, dict[str, Any]] = {}
    with zipfile.ZipFile(path) as archive:
        for name in safe_members(archive):
            if not name.endswith("/input.json"):
                continue
            value = json.loads(archive.read(name))
            segment_id = str(value["id"])
            if segment_id in inputs:
                raise RuntimeError(f"Duplicate batch input id: {segment_id}")
            inputs[segment_id] = value
    return inputs


def read_reviews(path: Path) -> tuple[dict[str, dict[str, Any]], list[dict[str, str]]]:
    reviews: dict[str, dict[str, Any]] = {}
    parse_errors: list[dict[str, str]] = []
    with zipfile.ZipFile(path) as archive:
        for name in safe_members(archive):
            if name.endswith("/") or not name.endswith(".json"):
                continue
            try:
                value = json.loads(archive.read(name))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                parse_errors.append({"file": name, "error": str(error)})
                continue
            if not isinstance(value, dict):
                parse_errors.append({"file": name, "error": "JSON root is not an object"})
                continue
            segment_id = str(value.get("id") or "")
            if not segment_id:
                parse_errors.append({"file": name, "error": "Missing id"})
                continue
            if segment_id in reviews:
                parse_errors.append({"file": name, "error": f"Duplicate id: {segment_id}"})
                continue
            value["_source_filename"] = name
            reviews[segment_id] = value
    return reviews, parse_errors


def normalized_review(
    input_data: dict[str, Any],
    review: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    value = copy.deepcopy(review)
    value.pop("_source_filename", None)
    reasons = second_review_reasons(value)
    quality_control = input_data.get("quality_control") or {}
    if quality_control.get("second_review_required") is True:
        reasons = ["input_quality_control", *reasons]
    reasons = list(dict.fromkeys(reasons))
    flags = list(value.get("review_flags", []))
    if reasons and "requires_second_review" not in flags:
        flags.append("requires_second_review")
        value["review_flags"] = flags
        return value, reasons
    return value, []


def write_normalized_zip(path: Path, reviews: dict[str, dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + ".partial")
    with zipfile.ZipFile(
        partial,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        strict_timestamps=False,
    ) as archive:
        for segment_id in sorted(reviews):
            text = json.dumps(
                reviews[segment_id],
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            ) + "\n"
            archive.writestr(
                f"review-results/{segment_id}.json",
                text.encode("utf-8"),
            )
    partial.replace(path)
    with zipfile.ZipFile(path) as archive:
        if bad_member := archive.testzip():
            raise RuntimeError(f"Corrupt normalized ZIP member: {bad_member}")


def main() -> int:
    arguments = parse_arguments()
    schema = json.loads(arguments.schema.read_text(encoding="utf-8"))
    inputs = read_batch_inputs(arguments.batch)
    source_reviews, parse_errors = read_reviews(arguments.reviews)
    missing_ids = sorted(set(inputs) - set(source_reviews))
    extra_ids = sorted(set(source_reviews) - set(inputs))
    filename_mismatches: list[dict[str, str]] = []
    normalized_reviews: dict[str, dict[str, Any]] = {}
    items: list[dict[str, Any]] = []

    for segment_id in sorted(set(inputs) & set(source_reviews)):
        input_data = inputs[segment_id]
        source_review = source_reviews[segment_id]
        source_filename = str(source_review["_source_filename"])
        expected_filename = str(input_data["expected_response_filename"])
        if PurePosixPath(source_filename).name != expected_filename:
            filename_mismatches.append(
                {
                    "id": segment_id,
                    "expected": expected_filename,
                    "actual": PurePosixPath(source_filename).name,
                }
            )

        original = copy.deepcopy(source_review)
        original.pop("_source_filename", None)
        original_result = validate_review(input_data, original, schema)
        normalized, normalization_reasons = normalized_review(input_data, source_review)
        normalized_result = validate_review(input_data, normalized, schema)
        normalized_reviews[segment_id] = normalized
        items.append(
            {
                "id": segment_id,
                "decision": normalized.get("decision"),
                "confidence": normalized.get("confidence"),
                "usable_for_polisher": normalized.get("usable_for_polisher"),
                "runtime_support": normalized.get("runtime_support"),
                "boundary_status": normalized.get("boundary_status"),
                "metadata_normalization": (
                    {"added_flag": "requires_second_review", "reasons": normalization_reasons}
                    if normalization_reasons
                    else None
                ),
                "original_valid": original_result["valid"],
                "original_errors": original_result["errors"],
                "normalized_valid": normalized_result["valid"],
                "errors": normalized_result["errors"],
                "warnings": normalized_result["warnings"],
            }
        )

    if arguments.normalized_output:
        write_normalized_zip(arguments.normalized_output, normalized_reviews)

    decisions = Counter(item["decision"] for item in items)
    confidences = Counter(item["confidence"] for item in items)
    report = {
        "schema_version": "voxol-text-refining-batch-validation-v2",
        "batch": {
            "path": str(arguments.batch),
            "sha256": sha256_file(arguments.batch),
            "input_count": len(inputs),
        },
        "reviews": {
            "path": str(arguments.reviews),
            "sha256": sha256_file(arguments.reviews),
            "parsed_count": len(source_reviews),
            "parse_errors": parse_errors,
        },
        "normalized_output": (
            {
                "path": str(arguments.normalized_output),
                "sha256": sha256_file(arguments.normalized_output),
            }
            if arguments.normalized_output
            else None
        ),
        "summary": {
            "missing_ids": missing_ids,
            "extra_ids": extra_ids,
            "filename_mismatches": filename_mismatches,
            "original_valid_count": sum(item["original_valid"] for item in items),
            "normalized_valid_count": sum(item["normalized_valid"] for item in items),
            "invalid_count": sum(not item["normalized_valid"] for item in items),
            "metadata_normalized_count": sum(
                item["metadata_normalization"] is not None for item in items
            ),
            "warning_count": sum(len(item["warnings"]) for item in items),
            "decisions": dict(sorted(decisions.items())),
            "confidence": dict(sorted(confidences.items())),
            "usable_count": sum(item["usable_for_polisher"] is True for item in items),
            "second_review_required_count": sum(
                "requires_second_review" in normalized_reviews[item["id"]].get("review_flags", [])
                for item in items
            ),
        },
        "items": items,
    }
    arguments.report.parent.mkdir(parents=True, exist_ok=True)
    arguments.report.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report["summary"], ensure_ascii=False, indent=2))
    handoff_errors = (
        parse_errors
        or missing_ids
        or extra_ids
        or filename_mismatches
        or any(not item["normalized_valid"] for item in items)
    )
    return 1 if handoff_errors else 0


if __name__ == "__main__":
    sys.exit(main())
