import unittest

from apply_runtime_delta_reviews import apply_reviews


class ApplyRuntimeDeltaReviewsTests(unittest.TestCase):
    def test_applies_targets_preserves_split_and_excludes(self) -> None:
        sources = [
            {
                "id": "keep",
                "operations": ["punctuation"],
                "source": "first-pass",
                "split": "train",
                "target_text": "candidate keep",
            },
            {
                "id": "replace",
                "operations": [],
                "source": "first-pass",
                "split": "validation",
                "target_text": "candidate replace",
            },
            {
                "id": "exclude",
                "operations": [],
                "source": "first-pass",
                "split": "test",
                "target_text": "candidate exclude",
            },
            {
                "id": "untouched",
                "operations": ["noop"],
                "source": "first-pass",
                "split": "train",
                "target_text": "same",
            },
        ]
        inputs = {
            "keep": {"split": "train"},
            "replace": {"split": "validation"},
            "exclude": {"split": "test"},
        }
        reviews = {
            "keep": {
                "decision": "keep_deterministic_baseline",
                "final_target": "baseline keep",
            },
            "replace": {
                "decision": "replace_with_better_target",
                "final_target": "better replace",
            },
            "exclude": {
                "decision": "exclude_unrecoverable",
                "final_target": None,
            },
        }

        outputs, report = apply_reviews(sources, inputs, reviews)

        self.assertEqual([row["id"] for row in outputs], ["keep", "replace", "untouched"])
        self.assertEqual(outputs[0]["target_text"], "baseline keep")
        self.assertEqual(outputs[1]["target_text"], "better replace")
        self.assertEqual(outputs[2], sources[3])
        self.assertEqual(report["changedTargetCount"], 2)
        self.assertEqual(report["excludedIDs"], ["exclude"])

    def test_rejects_frozen_split_mismatch(self) -> None:
        sources = [
            {
                "id": "item",
                "operations": [],
                "source": "first-pass",
                "split": "train",
                "target_text": "candidate",
            }
        ]
        inputs = {"item": {"split": "test"}}
        reviews = {
            "item": {
                "decision": "accept_gpt_target",
                "final_target": "candidate",
            }
        }

        with self.assertRaisesRegex(RuntimeError, "Frozen split mismatch"):
            apply_reviews(sources, inputs, reviews)


if __name__ == "__main__":
    unittest.main()
