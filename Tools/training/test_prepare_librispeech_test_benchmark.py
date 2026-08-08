#!/usr/bin/env python3
"""Tests for the LibriSpeech benchmark archive parser."""

from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "Scripts" / "prepare-librispeech-test-benchmark.py"


def load_module() -> object:
    specification = importlib.util.spec_from_file_location("prepare_librispeech", SCRIPT)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class LibriSpeechPreparationTests(unittest.TestCase):
    def test_extract_split_pairs_audio_and_transcript(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "test-clean.tar.gz"
            with tarfile.open(archive_path, "w:gz") as archive:
                transcript = b"123-456-0001 HELLO WORLD\n"
                transcript_info = tarfile.TarInfo(
                    "LibriSpeech/test-clean/123/456/123-456.trans.txt"
                )
                transcript_info.size = len(transcript)
                archive.addfile(transcript_info, io.BytesIO(transcript))
                audio = b"fake-flac"
                audio_info = tarfile.TarInfo(
                    "LibriSpeech/test-clean/123/456/123-456-0001.flac"
                )
                audio_info.size = len(audio)
                archive.addfile(audio_info, io.BytesIO(audio))

            output_root = root / "output"
            items = module.extract_split(archive_path, "test-clean", output_root)

            self.assertEqual(len(items), 1)
            self.assertEqual(items[0]["speakerID"], "librispeech-123")
            self.assertEqual(items[0]["sessionID"], "librispeech-123-456")
            self.assertEqual(items[0]["reference"]["verbatim"], "HELLO WORLD")
            audio_path = output_root / "audio" / items[0]["audioPath"]
            self.assertEqual(audio_path.read_bytes(), audio)


if __name__ == "__main__":
    unittest.main()
