#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("convert_transcriber_records.py")
SPEC = importlib.util.spec_from_file_location("convert_transcriber_records", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ConvertTranscriberRecordsTests(unittest.TestCase):
    def test_matches_source_by_audio_hash_and_keeps_raw_and_edited_separate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.wav"
            audio.write_bytes(b"audio")
            digest = MODULE.sha256(audio)
            manifest = {"items": [{"id": "one", "audioPath": "audio.wav"}]}
            records = {
                digest: {
                    "results": [
                        {"raw": "raw one", "edited": "edited one"},
                        {"raw": "raw two", "edited": "edited two"},
                    ]
                }
            }

            rows = MODULE.convert(manifest, root, records)

            self.assertEqual(rows[0]["id"], "one")
            self.assertEqual(rows[0]["rawText"], "raw one raw two")
            self.assertEqual(rows[0]["finalText"], "edited one edited two")

    def test_final_text_falls_back_to_raw_when_no_polished_output_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.wav"
            audio.write_bytes(b"audio")
            digest = MODULE.sha256(audio)
            rows = MODULE.convert(
                {"items": [{"id": "one", "audioPath": "audio.wav"}]},
                root,
                {digest: {"results": [{"raw": "verbatim", "edited": ""}]}},
            )

            self.assertEqual(rows[0]["finalText"], "verbatim")

    def test_final_text_falls_back_per_chunk_without_dropping_audio(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.wav"
            audio.write_bytes(b"audio")
            digest = MODULE.sha256(audio)
            rows = MODULE.convert(
                {"items": [{"id": "one", "audioPath": "audio.wav"}]},
                root,
                {
                    digest: {
                        "results": [
                            {"raw": "raw one", "edited": "edited one"},
                            {"raw": "raw two", "edited": ""},
                        ]
                    }
                },
            )

            self.assertEqual(rows[0]["finalText"], "edited one raw two")

    def test_final_text_rejects_a_polished_candidate_that_needs_review(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.wav"
            audio.write_bytes(b"audio")
            digest = MODULE.sha256(audio)
            rows = MODULE.convert(
                {"items": [{"id": "one", "audioPath": "audio.wav"}]},
                root,
                {
                    digest: {
                        "results": [
                            {
                                "raw": "faithful words",
                                "edited": "unrelated rewrite",
                                "quality": {"polished": {"status": "review"}},
                            }
                        ]
                    }
                },
            )

            self.assertEqual(rows[0]["finalText"], "faithful words")


if __name__ == "__main__":
    unittest.main()
