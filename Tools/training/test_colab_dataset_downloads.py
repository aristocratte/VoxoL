#!/usr/bin/env python3
"""Regression tests for Colab dataset cache recovery."""

from __future__ import annotations

import hashlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_ROOT = REPOSITORY_ROOT / "Scripts"
PREPARATION_SCRIPT = SCRIPTS_ROOT / "prepare-parakeet-fleurs-finetune.py"
sys.path.insert(0, str(SCRIPTS_ROOT))


def load_preparation_module() -> object:
    specification = importlib.util.spec_from_file_location(
        "prepare_parakeet_fleurs_finetune",
        PREPARATION_SCRIPT,
    )
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class DatasetDownloadRecoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_preparation_module()
        self.expected = b"verified-dataset-content"
        self.expected_sha256 = hashlib.sha256(self.expected).hexdigest()

    def subprocess_module(self) -> object:
        helper = getattr(self.module, "resumable_dataset_download", self.module)
        return helper.subprocess

    def test_corrupt_completed_cache_is_replaced(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "train.tsv"
            destination.write_bytes(b"x" * len(self.expected))

            def download(command: list[str], check: bool) -> None:
                self.assertTrue(check)
                output = Path(command[command.index("--output") + 1])
                output.write_bytes(self.expected)

            with mock.patch.object(
                self.subprocess_module(),
                "run",
                side_effect=download,
            ):
                result = self.module.download(
                    "en_us",
                    "train.tsv",
                    self.expected_sha256,
                    destination,
                    len(self.expected),
                )

            self.assertEqual(result, destination)
            self.assertEqual(destination.read_bytes(), self.expected)

    def test_corrupt_partial_download_retries_from_zero_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "train.tsv"
            partial = destination.with_suffix(".tsv.partial")
            partial.write_bytes(b"incomplete")
            attempts = 0

            def download(command: list[str], check: bool) -> None:
                nonlocal attempts
                self.assertTrue(check)
                attempts += 1
                output = Path(command[command.index("--output") + 1])
                output.write_bytes(
                    b"wrong-dataset-content!"
                    if attempts == 1
                    else self.expected
                )

            with mock.patch.object(
                self.subprocess_module(),
                "run",
                side_effect=download,
            ):
                result = self.module.download(
                    "en_us",
                    "train.tsv",
                    self.expected_sha256,
                    destination,
                    len(self.expected),
                )

            self.assertEqual(attempts, 2)
            self.assertEqual(result.read_bytes(), self.expected)
            self.assertFalse(partial.exists())


if __name__ == "__main__":
    unittest.main()
