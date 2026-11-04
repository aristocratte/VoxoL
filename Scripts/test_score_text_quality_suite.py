import copy
import importlib.util
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "score_text_quality_suite", Path(__file__).with_name("score-text-quality-suite.py")
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class TextQualityScoreTests(unittest.TestCase):
    def setUp(self):
        self.suite = {"cases": [{"id": "one", "language": "fr", "category": "preserve",
                                "expected": "Ouvre 3 fichiers."}]}
        self.report = {"results": [{"id": "one", "expected": "Ouvre 3 fichiers.",
                                   "finalText": "Ouvre 3 fichiers.", "durationMilliseconds": 0}]}

    def test_scores_final_output_even_when_candidate_is_correct(self):
        self.report["results"][0].update(candidate="Ouvre 3 fichiers.", finalText="Ouvre 4 fichiers.")
        result = MODULE.score(self.suite, self.report)
        self.assertEqual(result["cleanReferenceMatchCount"], 0)
        self.assertEqual(result["literalDigitCodeMismatchCount"], 1)

    def test_accents_are_not_silently_folded(self):
        self.suite["cases"][0]["expected"] = "Il est où ?"
        self.report["results"][0].update(expected="Il est où ?", finalText="Il est ou ?")
        self.assertEqual(MODULE.score(self.suite, self.report)["lexicalMatchCount"], 0)

    def test_unrequested_italics_are_not_a_clean_match(self):
        self.report["results"][0]["finalText"] = "*Ouvre 3 fichiers.*"
        result = MODULE.score(self.suite, self.report)
        self.assertEqual(result["lexicalMatchCount"], 1)
        self.assertEqual(result["cleanReferenceMatchCount"], 0)
        self.assertEqual(result["unrequestedMarkdownCount"], 1)

    def test_zero_duration_and_failed_fallback_remain_in_statistics(self):
        self.report["results"][0]["failure"] = "timeout"
        result = MODULE.score(self.suite, self.report)
        self.assertEqual(result["meanMilliseconds"], 0)
        self.assertEqual(result["failedCalls"], 1)
        self.assertEqual(result["cleanReferenceMatchCount"], 1)

    def test_literal_match_is_not_a_semantic_guarantee(self):
        self.report["results"][0]["finalText"] = "Ouvre le fichier 3."
        result = MODULE.score(self.suite, self.report)
        self.assertEqual(result["literalDigitCodeMismatchCount"], 0)
        self.assertEqual(result["cleanReferenceMatchCount"], 0)
        self.assertEqual(result["changedPreservationCases"], ["one"])

    def test_missing_duplicate_or_changed_reference_fails_closed(self):
        for alteration in ("missing", "duplicate", "reference", "suite_duplicate", "negative_time"):
            suite, report = copy.deepcopy(self.suite), copy.deepcopy(self.report)
            if alteration == "missing":
                report["results"] = []
            elif alteration == "duplicate":
                report["results"] *= 2
            elif alteration == "reference":
                report["results"][0]["expected"] = "Other reference"
            elif alteration == "suite_duplicate":
                suite["cases"] *= 2
            else:
                report["results"][0]["durationMilliseconds"] = -1
            with self.subTest(alteration=alteration), self.assertRaises(ValueError):
                MODULE.score(suite, report)

    def test_repository_corpus_is_frozen_disjoint_and_synthetic(self):
        root = Path(__file__).resolve().parents[1] / "Data/corpus/text-quality-synthetic-v1"
        result = MODULE.validate_frozen_corpus(root)
        self.assertEqual(result["countsBySplit"], {"development": 48, "holdout": 48})


if __name__ == "__main__":
    unittest.main()
