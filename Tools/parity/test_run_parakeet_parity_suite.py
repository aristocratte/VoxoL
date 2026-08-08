#!/usr/bin/env python3
"""Unit tests for the resumable Parakeet parity suite."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("run_parakeet_parity_suite.py")
SPEC = importlib.util.spec_from_file_location("run_parakeet_parity_suite", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SUITE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SUITE
SPEC.loader.exec_module(SUITE)


class ParakeetParitySuiteTests(unittest.TestCase):
    def test_select_items_accepts_training_manifest_duration(self) -> None:
        rows = [
            {"id": "long", "duration": 31.0},
            {"id": "fixed-window-overflow", "duration": 30.0},
            {"id": "sample-overflow", "duration": 29.9925},
            {"id": "fixed-window-maximum", "duration": 29.99},
            {"id": "short", "duration": 4.0},
            {"id": "medium", "audioDurationSeconds": 12.0},
        ]

        selected = SUITE.select_items(rows, 10)

        self.assertEqual(
            [row["id"] for row in selected],
            ["short", "medium", "fixed-window-maximum"],
        )

    def test_audio_resolver_supports_local_dataset_layout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio = root / "records" / "session-a" / "audio" / "chunk.wav"
            audio.parent.mkdir(parents=True)
            audio.touch()

            resolved = SUITE.resolve_audio_path(
                root,
                "audio/session-a/chunk.wav",
            )

            self.assertEqual(resolved, audio)


if __name__ == "__main__":
    unittest.main()
