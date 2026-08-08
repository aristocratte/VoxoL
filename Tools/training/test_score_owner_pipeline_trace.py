#!/usr/bin/env python3
"""Tests for raw-ASR versus final-text attribution."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).with_name("score_owner_pipeline_trace.py")
SPEC = importlib.util.spec_from_file_location("score_owner_pipeline_trace", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(SCRIPT.parent))
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ScoreOwnerPipelineTraceTests(unittest.TestCase):
    def test_attributes_repairs_and_regressions(self) -> None:
        manifest = {
            "benchmarkID": "test",
            "items": [
                {
                    "id": "repair",
                    "group": "french",
                    "verbatim": "Bonjour Harris",
                    "clean": "Bonjour Aris",
                    "criticalSpans": [
                        {
                            "kind": "person",
                            "rawAccepted": ["Aris"],
                            "finalAccepted": ["Aris"],
                        }
                    ],
                },
                {
                    "id": "regression",
                    "group": "english",
                    "verbatim": "review the document",
                    "clean": "Review the document.",
                    "criticalSpans": [
                        {
                            "kind": "object",
                            "rawAccepted": ["the document"],
                            "finalAccepted": ["the document"],
                        }
                    ],
                },
            ],
        }
        traces = {
            "traces": [
                {
                    "rawTranscript": "Bonjour Harris",
                    "finalText": "Bonjour Aris",
                },
                {
                    "rawTranscript": "review the document",
                    "finalText": "review it",
                },
            ]
        }

        report = MODULE.score_pipeline(manifest, traces)

        self.assertEqual(report["criticalSpans"]["deterministicRepairCount"], 1)
        self.assertEqual(report["criticalSpans"]["deterministicRegressionCount"], 1)
        self.assertFalse(
            report["criticalSpans"]["zeroProcessingCriticalRegressionPassed"]
        )
        self.assertEqual(report["textProcessingImpact"]["improvedItemCount"], 1)
        self.assertEqual(report["textProcessingImpact"]["regressedItemCount"], 1)

    def test_attributes_qwen_regression_from_processing_route(self) -> None:
        manifest = {
            "benchmarkID": "test",
            "items": [
                {
                    "id": "qwen",
                    "group": "english",
                    "verbatim": "twenty twenty six",
                    "clean": "twenty twenty six",
                    "criticalSpans": [
                        {
                            "kind": "date",
                            "rawAccepted": ["twenty twenty six"],
                            "finalAccepted": ["twenty twenty six"],
                        }
                    ],
                }
            ],
        }
        traces = {
            "traces": [
                {
                    "rawTranscript": "twenty twenty six",
                    "finalText": "twenty six",
                    "processingRoute": "qwen",
                }
            ]
        }

        report = MODULE.score_pipeline(manifest, traces)

        self.assertEqual(report["criticalSpans"]["qwenRegressionCount"], 1)
        self.assertEqual(report["criticalSpans"]["deterministicRegressionCount"], 0)

    def test_requires_the_complete_ordered_gate(self) -> None:
        manifest = {"benchmarkID": "test", "items": [{"id": "one"}]}

        with self.assertRaisesRegex(ValueError, "Expected 1 traces"):
            MODULE.score_pipeline(manifest, {"traces": []})

    def test_critical_span_matching_uses_whole_normalized_phrases(self) -> None:
        self.assertTrue(MODULE.contains_any("Port: 8080.", ["8080"]))
        self.assertFalse(MODULE.contains_any("Port: 80800.", ["8080"]))


if __name__ == "__main__":
    unittest.main()
