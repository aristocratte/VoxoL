#!/usr/bin/env python3

from __future__ import annotations

import copy
import json
from pathlib import Path
import unittest

from validate_review_output_v2 import seal_input, validate_review


ROOT = Path(__file__).resolve().parent
SCHEMA = json.loads((ROOT / "review-output.schema.v2.json").read_text(encoding="utf-8"))


def sample_input() -> dict:
    return seal_input(
        {
            "schema_version": "voxol-text-refining-input-v2",
            "id": "segment-1",
            "raw": "Je vais chiper une feature.",
            "wispr_edited_candidate": "Je vais shipper une feature.",
        }
    )


def sample_review(input_data: dict) -> dict:
    return {
        "schema_version": "voxol-text-refining-review-v2",
        "id": input_data["id"],
        "input_sha256": input_data["input_sha256"],
        "decision": "accept_wispr_edited",
        "refined_edited": input_data["wispr_edited_candidate"],
        "confidence": "high",
        "recoverable_from_raw": True,
        "usable_for_polisher": True,
        "raw_content_preserved": True,
        "runtime_support": "raw_only",
        "boundary_status": "complete",
        "edit_types": ["anglicism"],
        "transformations": [
            {
                "raw_surface": "chiper",
                "refined_surface": "shipper",
                "type": "anglicism",
                "basis": "raw_only",
                "confidence": "high",
                "runtime_support": "raw_only",
            }
        ],
        "formatting": ["none"],
        "review_flags": [],
        "evidence_urls": [],
        "review_note": "La graphie francisée est corrigée sans changer le sens.",
    }


class ReviewValidatorTests(unittest.TestCase):
    def test_valid_accept(self) -> None:
        input_data = sample_input()
        result = validate_review(input_data, sample_review(input_data), SCHEMA)
        self.assertTrue(result["valid"], result)

    def test_tampered_input_fails_its_seal(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        input_data["raw"] = "Texte altéré."
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])
        self.assertTrue(
            any("input file integrity failure" in error for error in result["errors"])
        )

    def test_review_must_echo_input_hash(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        review["input_sha256"] = "0" * 64
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])
        self.assertTrue(any("input_sha256 mismatch" in error for error in result["errors"]))

    def test_accept_requires_exact_candidate(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        review["refined_edited"] += " "
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])
        self.assertTrue(
            any("requires refined_edited to equal" in error for error in result["errors"])
        )

    def test_replace_requires_a_real_change(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        review["decision"] = "replace_wispr_edited"
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])
        self.assertTrue(
            any("requires a result different" in error for error in result["errors"])
        )

    def test_low_confidence_cannot_be_usable(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        review["confidence"] = "low"
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])

    def test_context_dependent_target_cannot_be_usable(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        review["runtime_support"] = "raw_plus_product_context"
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])

    def test_html_is_rejected(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        review["decision"] = "replace_wispr_edited"
        review["refined_edited"] = "<p>Je vais shipper une feature.</p>"
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])
        self.assertTrue(any("contains HTML" in error for error in result["errors"]))

    def test_public_reference_requires_https_evidence(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        review["transformations"][0]["basis"] = "public_spelling_reference"
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])

    def test_none_is_exclusive(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        review["edit_types"] = ["none", "anglicism"]
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])

    def test_required_second_review_must_be_flagged(self) -> None:
        input_data = sample_input()
        input_data["quality_control"] = {"second_review_required": True}
        input_data = seal_input(input_data)
        review = sample_review(input_data)
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])

        review["review_flags"] = ["requires_second_review"]
        valid_result = validate_review(input_data, review, SCHEMA)
        self.assertTrue(valid_result["valid"], valid_result)

    def test_discovered_sensitive_edit_requires_second_review(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        review["edit_types"] = ["proper_noun"]
        review["transformations"][0]["type"] = "proper_noun"
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])
        self.assertTrue(
            any("sensitive_edit:proper_noun" in error for error in result["errors"])
        )

        review["review_flags"] = ["requires_second_review"]
        valid_result = validate_review(input_data, review, SCHEMA)
        self.assertTrue(valid_result["valid"], valid_result)

    def test_incomplete_boundary_requires_second_review(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        review["boundary_status"] = "continues_into_next"
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])

        review["review_flags"] = ["requires_second_review"]
        valid_result = validate_review(input_data, review, SCHEMA)
        self.assertTrue(valid_result["valid"], valid_result)

    def test_exclude_requires_null_target(self) -> None:
        input_data = sample_input()
        review = sample_review(input_data)
        review.update(
            {
                "decision": "exclude_unrecoverable",
                "recoverable_from_raw": False,
                "usable_for_polisher": False,
                "raw_content_preserved": False,
            }
        )
        result = validate_review(input_data, review, SCHEMA)
        self.assertFalse(result["valid"])

        valid_review = copy.deepcopy(review)
        valid_review["refined_edited"] = None
        valid_review["runtime_support"] = "not_recoverable_at_runtime"
        valid_review["confidence"] = "low"
        valid_review["edit_types"] = ["none"]
        valid_review["transformations"] = []
        valid_review["review_flags"] = ["requires_second_review"]
        valid_review["review_note"] = "Le raw ne permet pas une cible fiable."
        valid_result = validate_review(input_data, valid_review, SCHEMA)
        self.assertTrue(valid_result["valid"], valid_result)


if __name__ == "__main__":
    unittest.main()
