#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT_PATH = Path(__file__).with_name("quantize_voxol_coreml_candidate.py")
SPEC = importlib.util.spec_from_file_location(
    "quantize_voxol_coreml_candidate",
    SCRIPT_PATH,
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class QuantizeVoxoLCoreMLCandidateTests(unittest.TestCase):
    def test_accepts_the_feature_runtime_contract_and_delta(self) -> None:
        MODULE.validate_source_metadata(
            {
                "voxol.delta_sha256": "abc",
                "voxol.runtime_contract": "encoder-3000x128-to-375x640-v1",
            },
            "abc",
        )

    def test_accepts_the_waveform_runtime_contract_and_delta(self) -> None:
        MODULE.validate_source_metadata(
            {
                "voxol.delta_sha256": "abc",
                "voxol.runtime_contract": "waveform-479840-to-375x640-v1",
            },
            "abc",
        )

    def test_accepts_the_exact_thirty_second_waveform_contract(self) -> None:
        MODULE.validate_source_metadata(
            {
                "voxol.delta_sha256": "abc",
                "voxol.runtime_contract": "waveform-480000-to-376x640-v2",
            },
            "abc",
        )

    def test_rejects_a_different_delta(self) -> None:
        with self.assertRaisesRegex(ValueError, "delta mismatch"):
            MODULE.validate_source_metadata(
                {
                    "voxol.delta_sha256": "old",
                    "voxol.runtime_contract": "encoder-3000x128-to-375x640-v1",
                },
                "new",
            )

    def test_rejects_an_incompatible_runtime_contract(self) -> None:
        with self.assertRaisesRegex(ValueError, "runtime contract"):
            MODULE.validate_source_metadata(
                {
                    "voxol.delta_sha256": "abc",
                    "voxol.runtime_contract": "other",
                },
                "abc",
            )


if __name__ == "__main__":
    unittest.main()
