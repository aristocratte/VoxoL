#!/usr/bin/env python3
"""Tests for the reviewed Qwen correction curriculum."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("build_qwen_correction_curriculum.py")
SPEC = importlib.util.spec_from_file_location(
    "build_qwen_correction_curriculum",
    SCRIPT,
)
assert SPEC is not None and SPEC.loader is not None
BUILDER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BUILDER
SPEC.loader.exec_module(BUILDER)


class QwenCorrectionCurriculumTests(unittest.TestCase):
    def test_curriculum_is_balanced_train_only_and_does_not_leak_goldens(self) -> None:
        rows = BUILDER.build()
        fixture = json.loads(BUILDER.DEFAULT_FORBIDDEN_SUITE.read_text(encoding="utf-8"))
        forbidden_transcripts = {case["transcript"] for case in fixture["cases"]}
        forbidden_targets = {case["expected"] for case in fixture["cases"]}

        self.assertGreaterEqual(len(rows), 300)
        self.assertTrue(all(row["split"] == "train" for row in rows))
        self.assertTrue(all(row["approved"] for row in rows))
        self.assertEqual(len({row["id"] for row in rows}), len(rows))
        self.assertEqual(
            len(
                {
                    (row["language"], row["raw_transcript"], row["target_text"])
                    for row in rows
                }
            ),
            len(rows),
        )
        self.assertFalse(
            any(row["raw_transcript"] in forbidden_transcripts for row in rows)
        )
        self.assertFalse(any(row["target_text"] in forbidden_targets for row in rows))

        counts = {
            language: sum(row["language"] == language for row in rows)
            for language in ("en", "fr")
        }
        self.assertLessEqual(abs(counts["en"] - counts["fr"]), 12)
        categories = {row["operations"][0] for row in rows}
        self.assertTrue(
            {
                "agreement",
                "spelling",
                "question",
                "protected_facts",
                "noop",
            }.issubset(categories)
        )

    def test_output_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rows = BUILDER.build()
            first = root / "first.jsonl"
            second = root / "second.jsonl"
            BUILDER.write_jsonl(first, rows)
            BUILDER.write_jsonl(second, BUILDER.build())
            self.assertEqual(first.read_bytes(), second.read_bytes())


if __name__ == "__main__":
    unittest.main()
