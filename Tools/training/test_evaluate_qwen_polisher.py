#!/usr/bin/env python3
"""Unit tests for content-free Qwen cleanup metrics."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).with_name("evaluate_qwen_polisher.py")
SPEC = importlib.util.spec_from_file_location("evaluate_qwen_polisher", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
EVALUATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = EVALUATOR
SPEC.loader.exec_module(EVALUATOR)


class QwenPolisherEvaluationTests(unittest.TestCase):
    def test_metrics_measure_noop_and_protected_token_fidelity(self) -> None:
        report = EVALUATOR.score_rows(
            [
                {
                    "actual_text": "Keep VOXOLP0 today.",
                    "expected_text": "Keep VOXOLP0 today.",
                    "latency_milliseconds": 100,
                    "output_token_count": 5,
                    "source_text": "Keep VOXOLP0 today.",
                },
                {
                    "actual_text": "Send tomorrow.",
                    "expected_text": "Send VOXOLP1 tomorrow.",
                    "latency_milliseconds": 200,
                    "output_token_count": 4,
                    "source_text": "um send VOXOLP1 tomorrow",
                },
            ]
        )

        self.assertEqual(report["exampleCount"], 2)
        self.assertEqual(report["exactMatchRate"], 0.5)
        self.assertEqual(report["inputCopyRate"], 0.5)
        self.assertEqual(report["protectedTokenRecall"], 0.5)
        self.assertGreater(report["microWordEditRate"], 0)
        self.assertEqual(report["latencyMilliseconds"]["p95"], 200)

    def test_transcript_extraction_supports_both_languages(self) -> None:
        self.assertEqual(
            EVALUATOR.transcript_from_user_message("A\nDICTATION TO CLEAN:\nhello"),
            "hello",
        )
        self.assertEqual(
            EVALUATOR.transcript_from_user_message("A\nDICTÉE À CORRIGER:\nbonjour"),
            "bonjour",
        )

    def test_placeholder_validation_falls_back_without_hiding_raw_metrics(self) -> None:
        rows = [
            {
                "actual_text": "Send tomorrow.",
                "expected_text": "Send VOXOLP1 tomorrow.",
                "latency_milliseconds": 200,
                "output_token_count": 4,
                "source_text": "Send VOXOLP1 tomorrow.",
            },
            {
                "actual_text": "Keep VOXOLP2 today.",
                "expected_text": "Keep VOXOLP2 today.",
                "latency_milliseconds": 100,
                "output_token_count": 5,
                "source_text": "Keep VOXOLP2 today.",
            },
        ]

        validated, validation = EVALUATOR.apply_placeholder_fallback(rows)

        self.assertEqual(validation["fallbackCount"], 1)
        self.assertEqual(validated[0]["actual_text"], rows[0]["source_text"])
        self.assertEqual(
            EVALUATOR.score_rows(validated)["protectedTokenRecall"],
            1.0,
        )
        self.assertEqual(
            EVALUATOR.score_rows(rows)["protectedTokenRecall"],
            0.5,
        )

    def test_compact_generation_fails_closed_to_source(self) -> None:
        actual, valid = EVALUATOR.resolve_generated_text(
            "hello world",
            '[["hello","Hello"],["world","world."]]',
            "compact-edits",
        )
        fallback, fallback_valid = EVALUATOR.resolve_generated_text(
            "hello world",
            "not json",
            "compact-edits",
        )

        self.assertEqual(actual, "Hello world.")
        self.assertTrue(valid)
        self.assertEqual(fallback, "hello world")
        self.assertFalse(fallback_valid)


if __name__ == "__main__":
    unittest.main()
