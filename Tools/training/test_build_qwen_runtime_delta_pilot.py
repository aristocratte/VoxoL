import unittest

from build_qwen_runtime_delta_pilot import (
    build_pilot,
    canonical_baseline,
    canonical_target_boundary,
)


def source(
    identifier: str,
    target: str,
    *,
    split: str = "train",
    language: str = "en",
) -> dict[str, object]:
    return {
        "id": identifier,
        "language": language,
        "operations": [],
        "raw_transcript": target,
        "source": "review",
        "split": split,
        "target_text": target,
    }


class BuildQwenRuntimeDeltaPilotTests(unittest.TestCase):
    def test_canonicalizes_only_capture_boundaries(self) -> None:
        baseline = "This starts here and ends here."
        self.assertEqual(
            canonical_target_boundary("this starts here and ends here", baseline),
            baseline,
        )
        self.assertEqual(canonical_baseline("An incomplete clause,."), "An incomplete clause.")
        self.assertEqual(
            canonical_target_boundary("An incomplete clause,", "An incomplete clause,."),
            "An incomplete clause.",
        )

    def test_preserves_internal_edit_and_question_mark(self) -> None:
        self.assertEqual(
            canonical_target_boundary("i i fixed it", "I I fixed it."),
            "I i fixed it.",
        )
        self.assertEqual(
            canonical_target_boundary("is this ready ?", "Is this ready."),
            "Is this ready ?",
        )

    def test_builds_train_only_curriculum_and_isolated_evaluation(self) -> None:
        sources = [
            source("boundary", "same words"),
            source("edit", "I fixed it"),
            source("validation", "Is this ready ?", split="validation"),
            source("rejected", "Excluded target"),
        ]
        prepared = [
            {"id": "boundary", "normalized_text": "Same words."},
            {"id": "edit", "normalized_text": "I I fixed it."},
            {"id": "validation", "normalized_text": "Is this ready."},
            {"id": "rejected", "normalized_text": "Excluded baseline."},
        ]
        curriculum = [
            {
                "id": "curated",
                "language": "fr",
                "operations": ["noop"],
                "split": "train",
                "target_text": "Déjà propre.",
            }
        ]

        outputs, report = build_pilot(
            sources,
            prepared,
            {"rejected"},
            curriculum,
        )

        self.assertEqual(report["nominalRuntimeDeltaCount"], 3)
        self.assertEqual(report["boundaryOnlyArtifactCount"], 1)
        self.assertEqual([row["id"] for row in outputs["product_train"]], ["edit"])
        self.assertEqual(
            [row["id"] for row in outputs["product_evaluation"]],
            ["validation"],
        )
        self.assertEqual(
            outputs["product_references"],
            [
                {
                    "case_type": "edit",
                    "id": "validation",
                    "language": "en",
                    "recording_id": "validation",
                    "split": "validation",
                    "split_group": "validation",
                }
            ],
        )
        self.assertEqual(
            [row["id"] for row in outputs["combined"]],
            ["curated", "edit"],
        )

    def test_rejects_non_train_curriculum(self) -> None:
        curriculum = [source("curated", "Target", split="test")]
        with self.assertRaisesRegex(RuntimeError, "train-only"):
            build_pilot([], [], set(), curriculum)


if __name__ == "__main__":
    unittest.main()
