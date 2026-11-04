import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("audit-personal-dictations.py")
SPEC = importlib.util.spec_from_file_location("audit_personal_dictations", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PersonalDictationAuditTests(unittest.TestCase):
    def test_explicit_missing_adjudication_does_not_use_stale_default(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            arguments = [
                str(SCRIPT), "--head-to-head", str(root), "--output-dir", str(root / "out"),
                "--adjudication-review", str(root / "missing.jsonl"),
            ]
            with patch("sys.argv", arguments), self.assertRaisesRegex(SystemExit, "Adjudication review not found"):
                MODULE.main()

    def test_suite_uses_auto_language_and_explicit_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "one"
            directory.mkdir()
            session = {
                "id": "one",
                "directory": directory,
                "meta": {"rawText": "bonjour", "finalText": "Bonjour.", "language": "auto"},
                "review": None,
            }
            (directory / "corrected.txt").write_text("Bonjour.", encoding="utf-8")

            suite = MODULE.build_suite([session], {}, "rewrite", "fr")

            self.assertEqual(suite["cases"][0]["language"], "auto")
            self.assertEqual(suite["cases"][0]["fallbackLanguage"], "fr")
            self.assertFalse(suite["promotionEligible"])

    def test_adjudicated_suite_excludes_quarantined_sessions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            accepted_directory = root / "accepted"
            quarantined_directory = root / "quarantined"
            accepted_directory.mkdir()
            quarantined_directory.mkdir()
            sessions = [
                {
                    "id": "accepted",
                    "directory": accepted_directory,
                    "meta": {"rawText": "bonjour", "finalText": "Bonjour.", "language": "auto"},
                    "review": {
                        "status": "accepted",
                        "provenance": {"human_reviewed": False},
                        "chosen": {"rewrite_gold": "Bonjour."},
                    },
                },
                {
                    "id": "quarantined",
                    "directory": quarantined_directory,
                    "meta": {"rawText": "salut", "finalText": "Salut.", "language": "auto"},
                    "review": {"status": "quarantined"},
                },
            ]

            suite = MODULE.build_suite(
                sessions, {}, "rewrite", "fr", accepted_only=True
            )

            self.assertEqual([case["id"] for case in suite["cases"]], ["accepted"])
            self.assertEqual(suite["cases"][0]["expected"], "Bonjour.")

    def test_code_switch_signal_requires_both_languages(self):
        mixed = MODULE.language_signal("Je pense que that this is vraiment bien")
        french = MODULE.language_signal("Je pense que cette phrase est vraiment bien")
        ambiguous = MODULE.language_signal("On a validé la direction et on passe à la suite")

        self.assertTrue(mixed["code_switch_candidate"])
        self.assertFalse(french["code_switch_candidate"])
        self.assertFalse(ambiguous["code_switch_candidate"])

    def test_human_reference_is_the_only_verified_qwen_comparison(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "one"
            directory.mkdir()
            session = {
                "id": "one",
                "directory": directory,
                "audio_path": directory / "audio.wav",
                "meta": {
                    "rawText": "je veux envoyer rapport",
                    "finalText": "Je veux envoyer le rapport.",
                    "durationSeconds": 2,
                },
                "review": {
                    "status": "accepted",
                    "provenance": {"tier": "human-reviewed", "human_reviewed": True},
                    "chosen": {"rewrite_gold": "Je veux envoyer le rapport."},
                },
            }
            polisher = {
                "one": {
                    "normalized": "Je veux envoyer rapport.",
                    "finalText": "Je veux envoyer le rapport.",
                    "polisherOutcome": "modelOutputUsed",
                    "v3Status": "accepted",
                }
            }

            summary, rows = MODULE.build_audit(
                [session],
                {"parakeet": {}, "gemini": {}, "wispr": {}},
                {},
                {},
                polisher,
                "rewrite",
            )

            self.assertEqual(summary["humanReviewedReferenceCount"], 1)
            self.assertEqual(summary["verifiedQwenHelpfulCount"], 1)
            self.assertLess(rows[0]["qwenReferenceDistanceDelta"], 0)


if __name__ == "__main__":
    unittest.main()
