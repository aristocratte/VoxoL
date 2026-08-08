#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).with_name("compare_asr_predictions.py")
SPEC = importlib.util.spec_from_file_location("compare_asr_predictions", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(SCRIPT.parent))
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class CompareASRPredictionsTests(unittest.TestCase):
    def test_reports_normalized_disagreement_and_empty_outputs(self) -> None:
        reference = {
            "a": {"rawText": "Bonjour, monde !"},
            "b": {"rawText": ""},
        }
        candidate = {
            "a": {"rawText": "Bonjour le monde."},
            "b": {"rawText": ""},
        }

        report = MODULE.compare(reference, candidate)

        self.assertEqual(report["itemCount"], 2)
        self.assertEqual(report["normalizedDisagreementCount"], 1)
        self.assertEqual(report["emptyReferenceCount"], 1)
        self.assertEqual(report["emptyCandidateCount"], 1)
        self.assertEqual(report["wordErrorCount"], 1)
        self.assertEqual(report["referenceWordCount"], 2)

    def test_rejects_different_identifier_sets(self) -> None:
        with self.assertRaisesRegex(ValueError, "Prediction ids differ"):
            MODULE.compare({"a": {"rawText": "a"}}, {"b": {"rawText": "a"}})


if __name__ == "__main__":
    unittest.main()
