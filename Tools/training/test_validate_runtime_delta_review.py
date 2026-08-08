import json
from pathlib import Path
import unittest

from build_runtime_delta_review_package import build_inputs
from validate_review_output_v2 import seal_input
from validate_runtime_delta_review import validate_delta_review


class ValidateRuntimeDeltaReviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = json.loads(
            Path(__file__).with_name("runtime-delta-review.schema.v1.json").read_text()
        )

    def input(self):
        return seal_input(
            {
                "id": "one",
                "raw": "um send it",
                "deterministic_baseline": "Send it.",
                "gpt_target_candidate": "Um, send it.",
            }
        )

    def review(self):
        input_data = self.input()
        return {
            "schema_version": "voxol-runtime-delta-review-v1",
            "id": "one",
            "input_sha256": input_data["input_sha256"],
            "decision": "keep_deterministic_baseline",
            "final_target": "Send it.",
            "confidence": "high",
            "review_flags": ["baseline_is_already_best"],
            "review_note": "The candidate restores a filler.",
        }

    def test_accepts_exact_baseline_decision(self):
        self.assertEqual(
            validate_delta_review(self.input(), self.review(), self.schema), []
        )

    def test_rejects_mismatched_target(self):
        review = self.review()
        review["final_target"] = "Different."
        errors = validate_delta_review(self.input(), review, self.schema)
        self.assertIn("keep_deterministic_baseline requires the exact baseline", errors)

    def test_package_builder_skips_previously_reviewed_ids(self):
        outputs = build_inputs(
            campaign_inputs={"item": {}},
            reviews={"item": {}},
            source_rows=[
                {
                    "id": "item",
                    "language": "en",
                    "split": "train",
                    "target_text": "Better text.",
                }
            ],
            prepared_rows={
                "item": {
                    "normalized_text": "Baseline text.",
                    "protected_tokens": [],
                    "should_use_polisher": True,
                }
            },
            rejected_ids=set(),
            previously_reviewed_ids={"item"},
        )

        self.assertEqual(outputs, [])


if __name__ == "__main__":
    unittest.main()
