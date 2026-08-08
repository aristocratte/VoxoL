#!/usr/bin/env python3

from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import unittest

import numpy as np


SCRIPT_PATH = Path(__file__).with_name("compare_parakeet_snapshots.py")
SPEC = spec_from_file_location("compare_parakeet_snapshots", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MaskedEncoderComparisonTests(unittest.TestCase):
    def test_ignores_padded_encoder_frames(self) -> None:
        source = np.zeros((1, 3, 2), dtype=np.float32)
        candidate = source.copy()
        candidate[:, 1:, :] = 100
        mask = np.array([[1, 0, 0]], dtype=np.int32)

        result = MODULE.masked_encoder_comparison(
            source,
            candidate,
            mask,
            mask,
        )

        self.assertEqual(result["validFrameCount"], 1)
        self.assertEqual(result["maximumAbsoluteError"], 0)
        self.assertEqual(result["normalizedRMSE"], 0)


if __name__ == "__main__":
    unittest.main()
