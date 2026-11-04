#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREPARE = load_module(
    "prepare_servicenow_code_switch",
    ROOT / "Scripts" / "prepare-servicenow-code-switch-benchmark.py",
)
SCORE = load_module(
    "score_servicenow_code_switch",
    ROOT / "Scripts" / "score-servicenow-code-switch.py",
)


class ServiceNowCodeSwitchBenchmarkTests(unittest.TestCase):
    def test_mixing_stats_count_transitions_and_non_dominant_words(self):
        cmi, switches = PREPARE.mixing_stats(["FR", "FR", "EN", "EN", "FR"])
        self.assertAlmostEqual(cmi, 40.0)
        self.assertEqual(switches, 2)

    def test_basic_normalizer_matches_public_task_contract(self):
        self.assertEqual(
            SCORE.normalize_au_basic("J’ai (vraiment) rebooté Teams — OK!"),
            "j ai rebooté teams ok",
        )
        self.assertEqual(SCORE.normalize_au_basic("Ticket 42"), "ticket 42")

    def test_edit_alignment_counts_all_word_error_kinds(self):
        alignment = SCORE.edit_alignment(
            "je reboot le laptop".split(),
            "je redémarre laptop maintenant".split(),
        )
        operations = [operation for operation, _ in alignment]
        self.assertEqual(operations.count("equal"), 2)
        self.assertEqual(operations.count("substitute"), 1)
        self.assertEqual(operations.count("insert"), 1)

    def test_language_labels_follow_removed_parenthetical_span(self):
        labels, adjusted = SCORE.reference_language_labels(
            ["section", "(existing", "users)", "sur", "PyCharm"],
            ["FR", "EN", "EN", "FR", "EN"],
            SCORE.normalize_au_basic("section (existing users) sur PyCharm").split(),
        )
        self.assertTrue(adjusted)
        self.assertEqual(labels, ["FR", "FR", "EN"])

    def test_score_reports_language_and_switch_slices(self):
        identifier = "sample"
        manifest = {
            "benchmarkID": "test",
            "items": [
                {
                    "id": identifier,
                    "reference": {"verbatim": "je reboot le laptop"},
                }
            ],
        }
        metadata = [
            {
                "id": identifier,
                "configuration": "en_fr",
                "codeMixingIndex": 25.0,
                "switchCount": 2,
                "words": ["je", "reboot", "le", "laptop"],
                "wordLanguages": ["FR", "EN", "FR", "EN"],
            }
        ]
        predictions = [
            {
                "id": identifier,
                "rawText": "je redémarre le laptop",
                "inferenceMilliseconds": 12.0,
            }
        ]
        report, records = SCORE.score(manifest, metadata, predictions, "rawText")
        self.assertEqual(report["itemCount"], 1)
        self.assertAlmostEqual(report["microWER"], 0.25)
        self.assertAlmostEqual(report["languageReferenceErrorRate"]["EN"]["rate"], 0.5)
        self.assertEqual(report["switchCountSlices"]["0-2"]["itemCount"], 1)
        self.assertEqual(
            report["publishedComparison"]["wer"]["en_fr"]["Google Gemini 3 Flash"],
            0.040,
        )
        self.assertEqual(
            report["comparability"]["auHarnessRevision"],
            SCORE.AU_HARNESS_REVISION,
        )
        self.assertEqual(len(records), 1)


if __name__ == "__main__":
    unittest.main()
