import unittest

from prepare_final_refining_qwen_dataset import (
    base_exclusion_reasons,
    dictionary_terms,
    gold_deferral_reasons,
    source_example,
)


class PrepareFinalRefiningQwenDatasetTests(unittest.TestCase):
    def input(self):
        return {
            "entity_lexicon": [
                {"canonical": "Qwen"},
                {"canonical": "Absent term"},
            ],
            "id": "example",
            "language": "en",
            "quality_control": {
                "second_review_required": False,
                "training_rights_status": "verified",
            },
            "raw": "We use Qwen locally",
        }

    def review(self):
        return {
            "boundary_status": "complete",
            "confidence": "high",
            "decision": "replace_wispr_edited",
            "edit_types": ["punctuation"],
            "formatting": ["none"],
            "raw_content_preserved": True,
            "recoverable_from_raw": True,
            "refined_edited": "We use Qwen locally.",
            "review_flags": [],
            "runtime_support": "raw_only",
            "usable_for_polisher": True,
        }

    def test_gold_pair_has_no_exclusion_or_deferral(self):
        self.assertEqual(base_exclusion_reasons(self.input(), self.review()), [])
        self.assertEqual(gold_deferral_reasons(self.input(), self.review(), []), [])

    def test_rights_and_unrecoverable_pair_are_excluded(self):
        input_data = self.input()
        input_data["quality_control"]["training_rights_status"] = "hold"
        review = self.review()
        review.update(
            {
                "confidence": "low",
                "decision": "exclude_unrecoverable",
                "raw_content_preserved": False,
                "recoverable_from_raw": False,
                "refined_edited": None,
                "usable_for_polisher": False,
            }
        )
        reasons = base_exclusion_reasons(input_data, review)
        self.assertIn("rights_hold", reasons)
        self.assertIn("review_excluded_unrecoverable", reasons)
        self.assertIn("empty_target", reasons)

    def test_second_review_and_warning_defer_gold(self):
        input_data = self.input()
        input_data["quality_control"]["second_review_required"] = True
        review = self.review()
        review["review_flags"] = ["requires_second_review"]
        reasons = gold_deferral_reasons(input_data, review, ["warning"])
        self.assertEqual(
            reasons,
            [
                "input_requires_second_review",
                "output_requires_second_review",
                "validator_warning",
            ],
        )

    def test_source_uses_only_shared_dictionary_terms(self):
        input_data = self.input()
        review = self.review()
        self.assertEqual(dictionary_terms(input_data, review["refined_edited"]), ["Qwen"])
        result = source_example(
            input_data,
            review,
            split="train",
            split_group="speaker",
            tier="gold",
        )
        self.assertEqual(result["dictionary"], ["Qwen"])
        self.assertEqual(result["split_group"], "speaker")


if __name__ == "__main__":
    unittest.main()
