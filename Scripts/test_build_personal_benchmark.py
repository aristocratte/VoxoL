#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("build-personal-benchmark.py")
SPEC = importlib.util.spec_from_file_location("build_personal_benchmark", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BuildPersonalBenchmarkTests(unittest.TestCase):
    def test_loading_capture_does_not_create_a_reference(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session = root / "sessions" / "unreviewed"
            session.mkdir(parents=True)
            (session / "audio.wav").write_bytes(b"audio")
            (session / "meta.json").write_text(json.dumps({"finalText": "Unverified output."}))
            MODULE.sessions_in(root)
            self.assertFalse((session / "corrected.txt").exists())

    def test_unreviewed_capture_is_not_marked_reviewed(self) -> None:
        session = {
            "name": "pending", "meta": {}, "audioPath": "sessions/pending/audio.wav",
            "reference_tier": "unverified-capture", "reference_ready": False,
            "human_reviewed": False, "verbatim_reference": "raw",
            "clean_reference": "Raw.",
        }
        self.assertFalse(MODULE.manifest_for([session])["items"][0]["reference"]["reviewed"])

    def test_extracts_product_critical_spans_without_overlap(self) -> None:
        spans = MODULE.critical_spans(
            "Do not send 42 requests to APIClient with --force or https://voxol.test."
        )

        self.assertEqual(
            {(span["kind"], span["expected"]) for span in spans},
            {
                ("negation", "not"),
                ("number", "42"),
                ("code", "APIClient"),
                ("command", "--force"),
                ("url", "https://voxol.test"),
            },
        )

    def test_uses_separate_adjudicated_verbatim_and_clean_references(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session = root / "sessions" / "one"
            session.mkdir(parents=True)
            (session / "audio.wav").write_bytes(b"audio")
            (session / "verbatim.txt").write_text("um keep 42", encoding="utf-8")
            (session / "faithful.txt").write_text("Keep exactly 42.", encoding="utf-8")
            (session / "corrected.txt").write_text("Keep 42.", encoding="utf-8")
            (session / "meta.json").write_text(
                json.dumps(
                    {
                        "rawText": "keep forty two",
                        "finalText": "Keep forty two.",
                        "language": "en",
                        "engine": "parakeetAutomatic",
                    }
                ),
                encoding="utf-8",
            )
            (session / "review.json").write_text(
                json.dumps(
                    {
                        "status": "accepted",
                        "provenance": {
                            "tier": "ensemble-adjudicated",
                            "human_reviewed": False,
                        },
                    }
                ),
                encoding="utf-8",
            )

            sessions = MODULE.sessions_in(root)
            manifest = MODULE.manifest_for(sessions)

            self.assertEqual(sessions[0]["reference_tier"], "ensemble-adjudicated")
            self.assertEqual(manifest["items"][0]["reference"]["verbatim"], "um keep 42")
            self.assertEqual(
                manifest["items"][0]["reference"]["clean"], "Keep exactly 42."
            )
            self.assertIn("reference-ensemble-adjudicated", manifest["items"][0]["tags"])


if __name__ == "__main__":
    unittest.main()
