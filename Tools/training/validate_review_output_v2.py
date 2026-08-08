#!/usr/bin/env python3
"""Validate one VoxoL text-refining review against its sealed input."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

try:
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError as exc:  # pragma: no cover
    raise SystemExit("Missing dependency: python -m pip install 'jsonschema>=4.22,<5'") from exc


HTML_RE = re.compile(r"</?[A-Za-z][^>]*>")
NUMBER_RE = re.compile(r"(?<!\w)[+\-−]?\d+(?:[.,]\d+)*(?:\s?%|\s?[A-Za-z°]+)?(?!\w)")
TOKEN_RE = re.compile(r"[\wÀ-ÖØ-öø-ÿ'+\-−./:@%]+", re.UNICODE)
INPUT_DIGEST_FIELD = "input_sha256"
SECOND_REVIEW_FLAGS = {
    "boundary_incomplete",
    "possible_missing_content",
    "possible_added_content",
    "number_or_entity_risk",
    "code_or_url_risk",
    "language_risk",
    "runtime_context_dependency",
}
SECOND_REVIEW_EDIT_TYPES = {
    "number_or_date",
    "proper_noun",
    "url_or_email",
    "path_command_or_code",
}


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def unsigned_input(input_data: dict[str, Any]) -> dict[str, Any]:
    value = dict(input_data)
    value.pop(INPUT_DIGEST_FIELD, None)
    return value


def input_sha256(input_data: dict[str, Any]) -> str:
    """Hash the canonical input while excluding its self-describing digest field."""

    return hashlib.sha256(canonical_json_bytes(unsigned_input(input_data))).hexdigest()


def seal_input(input_data: dict[str, Any]) -> dict[str, Any]:
    """Return a copy containing the digest that reviewers must echo."""

    value = unsigned_input(input_data)
    value[INPUT_DIGEST_FIELD] = input_sha256(value)
    return value


def normalized_tokens(text: str) -> list[str]:
    return [token.casefold() for token in TOKEN_RE.findall(text or "")]


def word_ratio(raw: str, refined: str) -> float:
    raw_count = len(normalized_tokens(raw))
    refined_count = len(normalized_tokens(refined))
    if raw_count == 0:
        return 1.0 if refined_count == 0 else float("inf")
    return refined_count / raw_count


def add_error(errors: list[str], message: str) -> None:
    if message not in errors:
        errors.append(message)


def add_warning(warnings: list[str], message: str) -> None:
    if message not in warnings:
        warnings.append(message)


def second_review_reasons(review: dict[str, Any]) -> list[str]:
    reasons: list[str] = []
    review_flags = set(review.get("review_flags", []))
    edit_types = set(review.get("edit_types", []))
    transformation_types = {
        item.get("type")
        for item in review.get("transformations", [])
        if isinstance(item, dict)
    }
    if review.get("confidence") == "low":
        reasons.append("low_confidence")
    if review.get("boundary_status") != "complete":
        reasons.append("incomplete_or_uncertain_boundary")
    if review.get("runtime_support") != "raw_only":
        reasons.append("runtime_context_dependency")
    reasons.extend(sorted(review_flags & SECOND_REVIEW_FLAGS))
    reasons.extend(
        f"sensitive_edit:{value}"
        for value in sorted((edit_types | transformation_types) & SECOND_REVIEW_EDIT_TYPES)
    )
    return list(dict.fromkeys(reasons))


def validate_cross_fields(
    input_data: dict[str, Any],
    review: dict[str, Any],
) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []

    expected_id = input_data.get("id")
    if review.get("id") != expected_id:
        add_error(errors, f"id mismatch: expected {expected_id!r}")

    expected_hash = input_sha256(input_data)
    declared_hash = input_data.get(INPUT_DIGEST_FIELD)
    if declared_hash != expected_hash:
        add_error(
            errors,
            f"input file integrity failure: declared {declared_hash!r}, expected {expected_hash}",
        )
    if review.get(INPUT_DIGEST_FIELD) != expected_hash:
        add_error(errors, f"input_sha256 mismatch: expected {expected_hash}")

    raw = input_data.get("raw") or ""
    candidate = input_data.get("wispr_edited_candidate")
    if candidate is None:
        candidate = input_data.get("edited") or ""
    refined = review.get("refined_edited")
    decision = review.get("decision")

    if decision == "accept_wispr_edited" and refined != candidate:
        add_error(
            errors,
            "accept_wispr_edited requires refined_edited to equal the input candidate exactly",
        )
    if decision == "replace_wispr_edited" and refined == candidate:
        add_error(
            errors,
            "replace_wispr_edited requires a result different from the input candidate",
        )
    if decision == "exclude_unrecoverable" and refined is not None:
        add_error(errors, "exclude_unrecoverable requires refined_edited=null")

    if review.get("confidence") == "low" and review.get("usable_for_polisher") is True:
        add_error(errors, "low confidence output cannot be usable_for_polisher")

    for field in ("edit_types", "formatting"):
        values = review.get(field, [])
        if "none" in values and len(values) != 1:
            add_error(errors, f"{field}: 'none' must be exclusive")

    quality_control = input_data.get("quality_control") or {}
    review_reasons = second_review_reasons(review)
    input_requires_review = quality_control.get("second_review_required") is True
    if (
        (input_requires_review or review_reasons)
        and "requires_second_review" not in review.get("review_flags", [])
    ):
        reasons = ["input_quality_control"] if input_requires_review else []
        reasons.extend(review_reasons)
        add_error(
            errors,
            "review_flags must include requires_second_review: "
            + ", ".join(dict.fromkeys(reasons)),
        )

    evidence_urls = review.get("evidence_urls", [])
    if any(not url.startswith("https://") for url in evidence_urls):
        add_error(errors, "evidence_urls must contain HTTPS URLs only")

    public_ref_used = any(
        item.get("basis") == "public_spelling_reference"
        for item in review.get("transformations", [])
        if isinstance(item, dict)
    )
    if public_ref_used and not evidence_urls:
        add_error(errors, "public_spelling_reference requires at least one evidence URL")

    if isinstance(refined, str):
        if HTML_RE.search(refined):
            add_error(errors, "refined_edited contains HTML; the VoxoL target must be plain text")

        ratio = word_ratio(raw, refined)
        if ratio < 0.75:
            add_warning(warnings, f"large deletion risk: refined/raw token ratio={ratio:.3f}")
        elif ratio > 1.25 and ratio != float("inf"):
            add_warning(warnings, f"large expansion risk: refined/raw token ratio={ratio:.3f}")

        raw_numbers = NUMBER_RE.findall(raw)
        refined_numbers = NUMBER_RE.findall(refined)
        if raw_numbers != refined_numbers:
            has_number_transform = (
                "number_or_date" in review.get("edit_types", [])
                or any(
                    item.get("type") == "number_or_date"
                    for item in review.get("transformations", [])
                    if isinstance(item, dict)
                )
            )
            if not has_number_transform:
                add_warning(
                    warnings,
                    "numeric surfaces differ but no number_or_date transformation is declared: "
                    f"raw={raw_numbers!r}, refined={refined_numbers!r}",
                )

        if (
            raw.rstrip().endswith(("...", "…", ",", ":", ";"))
            and review.get("boundary_status") == "complete"
        ):
            add_warning(
                warnings,
                "raw appears boundary-incomplete but boundary_status is complete",
            )

    raw_casefold = raw.casefold()
    for index, transformation in enumerate(review.get("transformations", [])):
        raw_surface = transformation.get("raw_surface", "")
        if raw_surface and raw_surface.casefold() not in raw_casefold:
            add_warning(
                warnings,
                f"transformation[{index}].raw_surface is not an exact substring of raw",
            )
        if (
            transformation.get("runtime_support") == "not_recoverable_at_runtime"
            and review.get("usable_for_polisher") is True
        ):
            add_error(
                errors,
                "a runtime-unrecoverable transformation cannot be usable_for_polisher",
            )

    if review.get("runtime_support") != "raw_only" and review.get("usable_for_polisher") is True:
        add_error(
            errors,
            "the current raw-only runtime accepts only runtime_support=raw_only",
        )

    return errors, warnings


def validate_review(
    input_data: dict[str, Any],
    review: dict[str, Any],
    schema: dict[str, Any],
) -> dict[str, Any]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    schema_errors = sorted(
        validator.iter_errors(review),
        key=lambda error: [str(part) for part in error.path],
    )
    errors = [
        f"schema:{'/'.join(str(part) for part in error.path) or '<root>'}: {error.message}"
        for error in schema_errors
    ]
    cross_errors, warnings = validate_cross_fields(input_data, review)
    errors.extend(cross_errors)
    return {
        "valid": not errors,
        "id": review.get("id"),
        "input_sha256_expected": input_sha256(input_data),
        "errors": errors,
        "warnings": warnings,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--review", required=True, type=Path)
    parser.add_argument("--schema", required=True, type=Path)
    args = parser.parse_args()

    input_data = json.loads(args.input.read_text(encoding="utf-8"))
    review = json.loads(args.review.read_text(encoding="utf-8"))
    schema = json.loads(args.schema.read_text(encoding="utf-8"))
    result = validate_review(input_data, review, schema)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    sys.exit(main())
