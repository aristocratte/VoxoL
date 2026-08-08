#!/usr/bin/env python3
"""Tests for the legacy Wispr teacher benchmark adapter."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("adapt_wispr_teacher_benchmark.py")
SPEC = importlib.util.spec_from_file_location("adapt_wispr_teacher_benchmark", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def source_manifest() -> dict[str, object]:
    manifest: dict[str, object] = {
        "schemaVersion": 1,
        "benchmarkID": "teacher",
        "normalizationVersion": "voxol-asr-v1",
        "frozenAt": "2026-08-01T18:30:00Z",
        "items": [
            {
                "audioPath": "audio/recording/chunk.wav",
                "durationSeconds": 4.2,
                "id": "chunk",
                "language": "french",
                "recordingID": "recording",
                "reference": {"clean": "Bonjour.", "verbatim": "Bonjour."},
                "speakerID": "speaker",
                "split": "test",
            }
        ],
    }
    manifest["contentSHA256"] = MODULE.sha256_bytes(
        MODULE.canonical_source_bytes(manifest)
    )
    return manifest


class AdaptWisprTeacherBenchmarkTests(unittest.TestCase):
    def test_adapts_metadata_without_changing_scored_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            output = root / "adapted.json"
            report = root / "report.json"
            payload = source_manifest()
            source.write_text(json.dumps(payload), encoding="utf-8")

            result = MODULE.adapt(source, output, report)
            adapted = json.loads(output.read_text(encoding="utf-8"))

        item = adapted["items"][0]
        self.assertEqual(item["sessionID"], "recording")
        self.assertEqual(item["split"], "blind")
        self.assertEqual(item["reference"]["verbatim"], "Bonjour.")
        self.assertTrue(item["reference"]["reviewed"])
        self.assertEqual(result["itemCount"], 1)
        self.assertNotIn("contentSHA256", adapted)

    def test_rejects_modified_frozen_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            payload = source_manifest()
            payload["items"][0]["reference"]["verbatim"] = "Modifié."
            source.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "contentSHA256"):
                MODULE.adapt(source, root / "adapted.json", root / "report.json")


if __name__ == "__main__":
    unittest.main()
