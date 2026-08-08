#!/usr/bin/env python3
"""Tests for checkpoint selection priorities."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).with_name("select_qwen_checkpoint.py")
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("select_qwen_checkpoint", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SELECTOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SELECTOR
SPEC.loader.exec_module(SELECTOR)


class QwenCheckpointSelectionTests(unittest.TestCase):
    def test_fidelity_precedes_edit_rate(self) -> None:
        faithful = {
            "metrics": {
                "protectedTokenRecall": 1.0,
                "microWordEditRate": 0.10,
                "unexpectedWordRate": 0.01,
            }
        }
        unsafe = {
            "metrics": {
                "protectedTokenRecall": 0.9,
                "microWordEditRate": 0.05,
                "unexpectedWordRate": 0.0,
            }
        }

        self.assertLess(
            SELECTOR.selection_key(faithful),
            SELECTOR.selection_key(unsafe),
        )


if __name__ == "__main__":
    unittest.main()
