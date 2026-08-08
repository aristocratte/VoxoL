#!/usr/bin/env python3
"""Tests for the teacher-disagreement analyser."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).with_name("analyze_teacher_disagreement.py")
SPEC = importlib.util.spec_from_file_location("analyze_teacher_disagreement", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
ANALYZER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ANALYZER
SPEC.loader.exec_module(ANALYZER)


def teacher(identifier: str, raw: str, language: str = "fr") -> dict[str, object]:
    return {"id": identifier, "raw": raw, "requested_language": language}


def prediction(identifier: str, text: str) -> dict[str, object]:
    return {"id": identifier, "rawText": text}


class NormalisationTests(unittest.TestCase):
    def test_case_and_punctuation_do_not_create_disagreement(self) -> None:
        self.assertEqual(
            ANALYZER.normalize("Bonjour, le monde !"),
            ANALYZER.normalize("bonjour le monde"),
        )

    def test_accents_are_preserved_because_they_change_the_word(self) -> None:
        self.assertNotEqual(ANALYZER.normalize("côté"), ANALYZER.normalize("cote"))


class AlignmentTests(unittest.TestCase):
    def test_identical_sequences_align_as_matches(self) -> None:
        operations = ANALYZER.word_alignment(["a", "b"], ["a", "b"])
        self.assertEqual([op[0] for op in operations], ["match", "match"])

    def test_a_replaced_word_is_a_substitution(self) -> None:
        operations = ANALYZER.word_alignment(["a", "b"], ["a", "c"])
        self.assertEqual([op[0] for op in operations], ["match", "substitution"])

    def test_a_dropped_word_is_a_deletion(self) -> None:
        operations = ANALYZER.word_alignment(["a", "b"], ["a"])
        self.assertEqual([op[0] for op in operations], ["match", "deletion"])

    def test_an_added_word_is_an_insertion(self) -> None:
        operations = ANALYZER.word_alignment(["a"], ["a", "b"])
        self.assertEqual([op[0] for op in operations], ["match", "insertion"])


class ClassificationTests(unittest.TestCase):
    def test_an_accent_difference_is_named_as_such(self) -> None:
        self.assertEqual(ANALYZER.classify("côté", "cote"), "accent")

    def test_an_apostrophe_difference_is_elision(self) -> None:
        self.assertEqual(ANALYZER.classify("qu'on", "quon"), "elision")

    def test_a_digit_on_either_side_is_numeric(self) -> None:
        self.assertEqual(ANALYZER.classify("2026", "deux"), "numeric")
        self.assertEqual(ANALYZER.classify("deux", "2026"), "numeric")

    def test_a_shared_first_letter_separates_near_misses(self) -> None:
        # "piton"/"python" is a teacher error on technical audio, not a VoxoL
        # one, and it is worth separating from an unrelated word swap.
        self.assertEqual(ANALYZER.classify("piton", "python"), "same_onset")

    def test_an_unrelated_word_is_lexical(self) -> None:
        self.assertEqual(ANALYZER.classify("bonjour", "merci"), "lexical")


class AnalysisTests(unittest.TestCase):
    def test_agreement_is_counted_after_normalisation(self) -> None:
        report, queue = ANALYZER.analyze(
            [teacher("a", "Bonjour, le monde !")],
            [prediction("a", "bonjour le monde")],
        )
        self.assertEqual(report["chunks"]["agreed"], 1)
        self.assertEqual(report["chunks"]["disagreed"], 0)
        self.assertEqual(queue, [])

    def test_a_chunk_without_a_prediction_is_skipped_not_counted(self) -> None:
        report, _ = ANALYZER.analyze([teacher("a", "bonjour")], [])
        self.assertEqual(report["chunks"]["skipped"], 1)
        self.assertEqual(report["chunks"]["compared"], 0)

    def test_an_empty_reference_is_skipped(self) -> None:
        report, _ = ANALYZER.analyze([teacher("a", "   ")], [prediction("a", "x")])
        self.assertEqual(report["chunks"]["skipped"], 1)

    def test_word_disagreement_rate_uses_reference_length(self) -> None:
        report, _ = ANALYZER.analyze(
            [teacher("a", "un deux trois quatre")],
            [prediction("a", "un deux trois cinq")],
        )
        self.assertEqual(report["words"]["reference"], 4)
        self.assertEqual(report["words"]["disagreeing"], 1)
        self.assertAlmostEqual(report["words"]["disagreementRate"], 0.25)

    def test_the_queue_is_ordered_by_how_much_is_at_stake(self) -> None:
        report, queue = ANALYZER.analyze(
            [
                teacher("small", "un deux trois"),
                teacher("large", "un deux trois quatre cinq"),
            ],
            [
                prediction("small", "un deux quatre"),
                prediction("large", "six sept huit neuf dix"),
            ],
        )
        self.assertEqual([item["id"] for item in queue], ["large", "small"])
        self.assertGreater(queue[0]["errorCount"], queue[1]["errorCount"])
        self.assertEqual(report["chunks"]["disagreed"], 2)

    def test_the_queue_carries_both_texts_for_adjudication(self) -> None:
        _, queue = ANALYZER.analyze(
            [teacher("a", "le python")],
            [prediction("a", "le piton")],
        )
        self.assertEqual(queue[0]["teacherText"], "le python")
        self.assertEqual(queue[0]["voxolText"], "le piton")

    def test_languages_are_counted_separately(self) -> None:
        report, _ = ANALYZER.analyze(
            [teacher("a", "bonjour", "fr"), teacher("b", "hello", "en")],
            [prediction("a", "bonsoir"), prediction("b", "hallo")],
        )
        self.assertEqual(report["disagreementsByLanguage"], {"fr": 1, "en": 1})

    def test_substitution_pairs_are_ranked_by_frequency(self) -> None:
        rows = [teacher(f"r{i}", "le python") for i in range(3)]
        rows.append(teacher("other", "un chat"))
        predictions = [prediction(f"r{i}", "le piton") for i in range(3)]
        predictions.append(prediction("other", "un chien"))
        report, _ = ANALYZER.analyze(rows, predictions)
        top = report["mostFrequentSubstitutions"][0]
        self.assertEqual((top["teacher"], top["voxol"], top["count"]), ("python", "piton", 3))


if __name__ == "__main__":
    unittest.main()
