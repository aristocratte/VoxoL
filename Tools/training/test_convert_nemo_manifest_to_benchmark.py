#!/usr/bin/env python3
"""Tests for converting NeMo manifests into VoxoL benchmarks."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("convert_nemo_manifest_to_benchmark.py")
SPEC = importlib.util.spec_from_file_location(
    "convert_nemo_manifest_to_benchmark",
    SCRIPT,
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ConvertNeMoManifestTests(unittest.TestCase):
    def test_detected_language_from_wispr_teacher_row(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "validation.jsonl"
            output = root / "manifest.json"
            source.write_text(
                json.dumps(
                    {
                        "audio_path": "records/source/audio/chunk.wav",
                        "detected_language": "en",
                        "id": "chunk",
                        "text": "Hello.",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            payload = MODULE.convert(source, output, "teacher-validation", root)

        self.assertEqual(payload["items"][0]["language"], "english")
        self.assertFalse(payload["items"][0]["reference"]["reviewed"])

    def test_trusted_teacher_reference_is_marked_reviewed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "validation.jsonl"
            output = root / "manifest.json"
            source.write_text(
                json.dumps(
                    {
                        "audio_path": "audio/fr/chunk.wav",
                        "language": "fr",
                        "text": "Bonjour.",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            payload = MODULE.convert(
                source,
                output,
                "teacher-validation",
                root,
                trust_reference=True,
            )

        self.assertTrue(payload["items"][0]["reference"]["reviewed"])

    def test_relative_teacher_row_preserves_identity_and_language(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "validation.jsonl"
            output = root / "manifest.json"
            source.write_text(
                json.dumps(
                    {
                        "audio_path": "audio/source/chunk.wav",
                        "duration": 12.5,
                        "id": "chunk",
                        "language": "fr",
                        "recording_id": "source",
                        "speaker_id": "speaker",
                        "text": "Bonjour.",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            payload = MODULE.convert(source, output, "teacher-validation", root)

        self.assertEqual(payload["items"][0]["id"], "chunk")
        self.assertEqual(payload["items"][0]["language"], "french")
        self.assertEqual(
            payload["items"][0]["audioPath"],
            "audio/source/chunk.wav",
        )
        self.assertNotIn("durationSeconds", payload["items"][0])

    def test_absolute_fleurs_path_infers_english(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio = root / "audio" / "en_us" / "dev" / "sample.wav"
            source = root / "validation.jsonl"
            output = root / "manifest.json"
            source.write_text(
                json.dumps(
                    {
                        "audio_filepath": str(audio),
                        "duration": 3,
                        "text": "A sample.",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            payload = MODULE.convert(source, output, "fleurs-dev", root)

        self.assertEqual(payload["items"][0]["language"], "english")
        self.assertEqual(
            payload["items"][0]["audioPath"],
            "audio/en_us/dev/sample.wav",
        )


if __name__ == "__main__":
    unittest.main()
