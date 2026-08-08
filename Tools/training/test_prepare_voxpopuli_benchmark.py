#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).parents[2] / "Scripts" / "prepare-voxpopuli-fr-en-benchmark.py"
SPEC = importlib.util.spec_from_file_location("prepare_voxpopuli", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class PrepareVoxPopuliBenchmarkTests(unittest.TestCase):
    def test_selection_is_deterministic_and_caps_speakers_first(self) -> None:
        rows = [
            {
                "audio_id": f"audio-{index}",
                "speaker_id": "dominant" if index < 10 else f"speaker-{index}",
            }
            for index in range(20)
        ]

        first = MODULE.select_rows(rows, "en", limit=12)
        second = MODULE.select_rows(list(reversed(rows)), "en", limit=12)

        self.assertEqual(
            [row["audio_id"] for row in first],
            [row["audio_id"] for row in second],
        )
        self.assertLessEqual(
            sum(row["speaker_id"] == "dominant" for row in first),
            MODULE.MAXIMUM_PER_SPEAKER,
        )

    def test_source_urls_are_pinned(self) -> None:
        self.assertIn(MODULE.DATASET_REVISION, MODULE.source_url("fr"))


if __name__ == "__main__":
    unittest.main()
