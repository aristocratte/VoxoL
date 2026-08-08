#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT_PATH = Path(__file__).with_name("export_voxol_nemo_coreml_candidate.py")
SPEC = importlib.util.spec_from_file_location(
    "export_voxol_nemo_coreml_candidate",
    SCRIPT_PATH,
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ExportVoxoLNeMoCoreMLCandidateTests(unittest.TestCase):
    def test_waveform_contract_covers_exactly_thirty_seconds(self) -> None:
        self.assertEqual(MODULE.MAX_AUDIO_SAMPLES, 30 * 16_000)
        self.assertEqual(MODULE.WAVEFORM_OUTPUT_FRAMES, 376)

    def test_accepts_pinned_trace_and_conversion_toolchains(self) -> None:
        MODULE.validate_nemo_toolchain("2.3.1", "2.7.0+cpu")
        MODULE.validate_nemo_toolchain("2.3.1", "2.7.0", "9.0")

    def test_rejects_unpinned_nemo(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "nemo"):
            MODULE.validate_nemo_toolchain("2.4.0", "2.7.0", "9.0")

    def test_rejects_unpinned_coremltools(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "coremltools"):
            MODULE.validate_nemo_toolchain("2.3.1", "2.7.0", "9.1")


if __name__ == "__main__":
    unittest.main()
