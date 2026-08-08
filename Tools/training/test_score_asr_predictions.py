#!/usr/bin/env python3
"""Tests for VoxoL's ASR scoring contract."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).with_name("score_asr_predictions.py")
SPEC = importlib.util.spec_from_file_location("score_asr_predictions", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ScoreASRPredictionsTests(unittest.TestCase):
    def test_edit_operation_counts_reconstruct_the_edit_distance(self) -> None:
        reference = "one two three".split()
        hypothesis = "one too".split()

        substitutions, deletions, insertions = MODULE.edit_operation_counts(
            reference,
            hypothesis,
        )

        self.assertEqual((substitutions, deletions, insertions), (1, 1, 0))
        self.assertEqual(
            substitutions + deletions + insertions,
            MODULE.edit_distance(reference, hypothesis),
        )

    def test_score_reports_deletion_rate_by_language(self) -> None:
        items = [
            {
                "id": "one",
                "language": "english",
                "reference": {"verbatim": "keep the final clause"},
            }
        ]
        predictions = {
            "one": {
                "rawText": "keep the",
                "inferenceMilliseconds": 10,
            }
        }

        report = MODULE.score_items(items, predictions)

        self.assertEqual(report["wordErrors"]["deletions"], 2)
        self.assertEqual(report["wordErrors"]["referenceWords"], 4)
        self.assertEqual(report["wordErrors"]["deletionRate"], 0.5)
        self.assertEqual(
            report["byLanguage"]["english"]["wordErrors"]["deletions"],
            2,
        )


if __name__ == "__main__":
    unittest.main()
