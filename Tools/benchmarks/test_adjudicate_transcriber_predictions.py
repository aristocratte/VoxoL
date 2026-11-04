#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("adjudicate_transcriber_predictions.py")
SPEC = importlib.util.spec_from_file_location("adjudicate_transcriber_predictions", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AdjudicateTranscriberPredictionsTests(unittest.TestCase):
    def test_external_teacher_consensus_is_accepted_and_applied(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            personal = root / "personal"
            session = personal / "sessions" / "one"
            session.mkdir(parents=True)
            (session / "audio.wav").write_bytes(b"audio")
            (session / "corrected.txt").write_text("old output", encoding="utf-8")
            (session / "meta.json").write_text(
                json.dumps(
                    {
                        "date": "2026-08-30T00:00:00Z",
                        "language": "en",
                        "rawText": "Send the repo on Monday",
                        "finalText": "Send the repo on Monday.",
                    }
                ),
                encoding="utf-8",
            )
            manifest = {"items": [{"id": "one", "audioPath": "sessions/one/audio.wav"}]}
            predictions = {
                "parakeet": {"one": {"rawText": "Send the repo on Monday", "finalText": "Send the repo on Monday."}},
                "gemini": {"one": {"rawText": "Send the report on Monday", "finalText": "Send the report on Monday."}},
                "wispr": {"one": {"rawText": "Send the report on Monday", "finalText": "Send the report on Monday."}},
            }

            review = MODULE.adjudicate_item(manifest["items"][0], predictions)
            MODULE.write_session_review(personal, review, apply=True)

            self.assertEqual(review["status"], "accepted")
            self.assertEqual(review["provenance"]["tier"], "ensemble-adjudicated")
            self.assertEqual(review["chosen"]["clean"], "Send the report on Monday.")
            self.assertEqual(review["chosen"]["faithful_gold"], "Send the report on Monday.")
            self.assertEqual(review["chosen"]["rewrite_gold"], "")
            self.assertEqual(review["chosen"]["verbatim_source"], "gemini")
            self.assertEqual(review["chosen"]["clean_source"], "gemini")
            self.assertEqual(
                (session / "verbatim.txt").read_text(encoding="utf-8"),
                "Send the report on Monday",
            )
            self.assertEqual(
                (session / "corrected.txt").read_text(encoding="utf-8"),
                "Send the report on Monday.",
            )
            self.assertEqual(
                (session / "faithful.txt").read_text(encoding="utf-8"),
                "Send the report on Monday.",
            )
            self.assertFalse((session / "rewrite.txt").exists())

    def test_critical_disagreement_is_quarantined(self) -> None:
        item = {"id": "critical", "audioPath": "sessions/critical/audio.wav"}
        predictions = {
            "parakeet": {"critical": {"rawText": "Do not delete 42", "finalText": "Do not delete 42."}},
            "gemini": {"critical": {"rawText": "Delete 42", "finalText": "Delete 42."}},
            "wispr": {"critical": {"rawText": "Do not delete 43", "finalText": "Do not delete 43."}},
        }

        review = MODULE.adjudicate_item(item, predictions)

        self.assertEqual(review["status"], "quarantined")
        self.assertIn("critical_value_disagreement", review["reasons"])
        self.assertIn("number", review["critical_disagreements"])
        self.assertIn("negation", review["critical_disagreements"])

    def test_teacher_consensus_corrects_a_critical_product_error(self) -> None:
        item = {"id": "port", "audioPath": "sessions/port/audio.wav"}
        predictions = {
            "parakeet": {"port": {"rawText": "Use port 8088", "finalText": "Use port 8088."}},
            "gemini": {"port": {"rawText": "Use port 8080", "finalText": "Use port 8080."}},
            "wispr": {"port": {"rawText": "Use port 8080", "finalText": "Use port 8080."}},
        }

        review = MODULE.adjudicate_item(item, predictions)

        self.assertEqual(review["status"], "accepted")
        self.assertEqual(review["chosen"]["clean"], "Use port 8080.")
        self.assertIn("number", review["critical_disagreements"])
        self.assertEqual(review["teacher_critical_disagreements"], [])

    def test_teacher_acceptance_never_selects_the_global_parakeet_medoid(self) -> None:
        item = {"id": "medoid", "audioPath": "sessions/medoid/audio.wav"}
        predictions = {
            "parakeet": {
                "medoid": {
                    "rawText": "we should build the beta transcription system today for every person who records a long technical discussion at work",
                    "finalText": "We should build the beta transcription system today for every person who records a long technical discussion at work.",
                }
            },
            "gemini": {
                "medoid": {
                    "rawText": "we should build the alpha transcription system today for every person who records a long technical discussion at work",
                    "finalText": "We should build the alpha transcription system today for every person who records a long technical discussion at work.",
                }
            },
            "wispr": {
                "medoid": {
                    "rawText": "we should create the beta transcription system today for every person who records a long technical discussion at work",
                    "finalText": "We should create the beta transcription system today for every person who records a long technical discussion at work.",
                }
            },
        }

        global_choice = MODULE.medoid(
            {
                system: row["medoid"]["rawText"]
                for system, row in predictions.items()
            }
        )
        review = MODULE.adjudicate_item(item, predictions)

        self.assertEqual(global_choice["system"], "parakeet")
        self.assertEqual(review["status"], "accepted")
        self.assertEqual(review["chosen"]["verbatim_source"], "gemini")
        self.assertEqual(review["chosen"]["clean_source"], "gemini")
        self.assertNotEqual(review["chosen"]["verbatim"], global_choice["text"])

    def test_context_decision_keeps_machine_provenance(self) -> None:
        item = {"id": "context", "audioPath": "sessions/context/audio.wav"}
        predictions = {
            "parakeet": {"context": {"rawText": "Open the repo", "finalText": "Open the repo."}},
            "gemini": {"context": {"rawText": "Open the report", "finalText": "Open the report."}},
            "wispr": {"context": {"rawText": "Open the repository", "finalText": "Open the repository."}},
        }
        decision = {
            "id": "context",
            "verbatim": "Open the repository",
            "clean": "Open the repository.",
            "rationale": "Repository is the only form consistent with the surrounding project context.",
        }

        review = MODULE.adjudicate_item(item, predictions, decision=decision)

        self.assertEqual(review["status"], "accepted")
        self.assertEqual(review["provenance"]["tier"], "agent-context-adjudicated")
        self.assertFalse(review["provenance"]["human_reviewed"])
        self.assertEqual(review["chosen"]["clean"], "Open the repository.")
        self.assertEqual(review["chosen"]["verbatim_source"], "context_decision")
        self.assertEqual(review["chosen"]["clean_source"], "context_decision")

    def test_machine_review_never_overwrites_human_review(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            personal = Path(temporary) / "personal"
            session = personal / "sessions" / "human"
            session.mkdir(parents=True)
            existing = {
                "status": "accepted",
                "provenance": {"tier": "human-reviewed", "human_reviewed": True},
            }
            (session / "review.json").write_text(json.dumps(existing), encoding="utf-8")
            (session / "verbatim.txt").write_text("Human verbatim", encoding="utf-8")
            (session / "corrected.txt").write_text("Human clean.", encoding="utf-8")
            machine = {
                "id": "human",
                "audio_path": "sessions/human/audio.wav",
                "status": "accepted",
                "provenance": {
                    "tier": "ensemble-adjudicated",
                    "human_reviewed": False,
                },
                "chosen": {"verbatim": "Machine verbatim", "clean": "Machine clean."},
            }

            MODULE.write_session_review(personal, machine, apply=True)

            self.assertEqual(
                json.loads((session / "review.json").read_text(encoding="utf-8")),
                existing,
            )
            self.assertEqual((session / "verbatim.txt").read_text(), "Human verbatim")
            self.assertEqual((session / "corrected.txt").read_text(), "Human clean.")


if __name__ == "__main__":
    unittest.main()
