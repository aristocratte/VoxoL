#!/usr/bin/env python3
"""Tests for compact Qwen dataset preparation."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from compact_polisher_edits import apply_compact_edits
from prepare_compact_qwen_dataset import prepare, transform_record


class CompactQwenDatasetTests(unittest.TestCase):
    def test_transform_is_lossless_and_changes_the_instruction(self) -> None:
        record = {
            "messages": [
                {
                    "role": "system",
                    "content": "You correct English dictation. Return only final text.",
                },
                {
                    "role": "user",
                    "content": "LANGUAGE: en\nDICTATION TO CLEAN:\nhello world",
                },
                {"role": "assistant", "content": "Hello, world."},
            ]
        }

        transformed, _, _ = transform_record(record)
        payload = transformed["messages"][2]["content"]

        self.assertEqual(apply_compact_edits("hello world", payload), "Hello, world.")
        self.assertIn("JSON array", transformed["messages"][0]["content"])

    def test_training_edits_only_keeps_validation_noops(self) -> None:
        edit = {
            "messages": [
                {"role": "system", "content": "You correct English dictation."},
                {
                    "role": "user",
                    "content": "LANGUAGE: en\nDICTATION TO CLEAN:\nhello world",
                },
                {"role": "assistant", "content": "Hello, world."},
            ]
        }
        noop = {
            "messages": [
                {"role": "system", "content": "You correct English dictation."},
                {
                    "role": "user",
                    "content": "LANGUAGE: en\nDICTATION TO CLEAN:\nAlready clean.",
                },
                {"role": "assistant", "content": "Already clean."},
            ]
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            output = root / "output"
            source.mkdir()
            for name, rows in (
                ("train.jsonl", [noop, edit]),
                ("valid.jsonl", [noop]),
                ("test.jsonl", [noop]),
            ):
                (source / name).write_text(
                    "".join(json.dumps(row) + "\n" for row in rows),
                    encoding="utf-8",
                )
            (source / "summary.json").write_text(
                json.dumps({"train": 2, "validation": 1, "test": 1}),
                encoding="utf-8",
            )

            report = prepare(source, output, training_edits_only=True)

            self.assertEqual(report["droppedTrainingNoopCount"], 1)
            self.assertEqual(report["splits"]["train.jsonl"]["exampleCount"], 1)
            self.assertEqual(report["splits"]["valid.jsonl"]["exampleCount"], 1)
            self.assertEqual(
                json.loads((output / "summary.json").read_text())["train"],
                1,
            )


if __name__ == "__main__":
    unittest.main()
