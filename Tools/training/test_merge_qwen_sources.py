#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("merge_qwen_sources.py")
SPEC = importlib.util.spec_from_file_location("merge_qwen_sources", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def row(identifier: str, group: str, split: str, raw: str, target: str) -> dict:
    return {
        "id": identifier,
        "language": "en",
        "raw_transcript": raw,
        "split": split,
        "split_group": group,
        "target_text": target,
    }


class MergeQwenSourcesTests(unittest.TestCase):
    def test_merges_sources_and_rebuilds_references(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first.jsonl"
            second = root / "second.jsonl"
            first.write_text(
                json.dumps(row("b", "old", "train", "same", "same")) + "\n"
            )
            second.write_text(
                json.dumps(row("a", "new", "test", "raw", "edited")) + "\n"
            )

            report = MODULE.merge([first, second], root / "merged")

            source = MODULE.read_jsonl(root / "merged" / "source.jsonl")
            references = MODULE.read_jsonl(
                root / "merged" / "evaluation-reference.jsonl"
            )
            self.assertEqual([item["id"] for item in source], ["a", "b"])
            self.assertEqual([item["case_type"] for item in references], ["edit", "noop"])
            self.assertEqual(report["itemCount"], 2)

    def test_rejects_group_split_leakage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.jsonl"
            source.write_text(
                json.dumps(row("a", "speaker", "train", "a", "a"))
                + "\n"
                + json.dumps(row("b", "speaker", "test", "b", "b"))
                + "\n"
            )
            with self.assertRaisesRegex(RuntimeError, "Split leakage"):
                MODULE.merge([source], root / "merged")


if __name__ == "__main__":
    unittest.main()
