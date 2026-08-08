#!/usr/bin/env python3
"""Regression tests for raw FLEURS TSV quote handling."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_ROOT = REPOSITORY_ROOT / "Scripts"
sys.path.insert(0, str(SCRIPTS_ROOT))
PARSERS = (
    "prepare-parakeet-fleurs-finetune.py",
    "prepare-fleurs-test-benchmark.py",
    "prepare-fleurs-fr-test-benchmark.py",
    "prepare-fleurs-lite-benchmark.py",
)
QUOTED_ROW = (
    '123\tclip.wav\t"Quoted sentence," she said.\t'
    '"quoted sentence she said\t" q u o t e d |\t16000\tFEMALE\n'
)


def load_script(name: str) -> object:
    path = SCRIPTS_ROOT / name
    specification = importlib.util.spec_from_file_location(
        name.removesuffix(".py").replace("-", "_"),
        path,
    )
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class FleursTSVParsingTests(unittest.TestCase):
    def test_literal_quotes_do_not_merge_tsv_columns(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "quoted.tsv"
            source.write_text(QUOTED_ROW, encoding="utf-8")
            for script_name in PARSERS:
                with self.subTest(script=script_name):
                    rows = load_script(script_name).load_rows(source)
                    self.assertEqual(len(rows), 1)
                    self.assertEqual(rows[0]["sentence_id"], "123")


if __name__ == "__main__":
    unittest.main()
