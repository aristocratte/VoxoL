import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "score_edit_attribution", Path(__file__).with_name("score-edit-attribution.py")
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def result(case_id, normalized, candidate, final, expected, duration=100, **extra):
    row = {"id": case_id, "normalized": normalized, "candidate": candidate,
           "finalText": final, "expected": expected, "durationMilliseconds": duration,
           "failure": None}
    row.update(extra)
    return row


class AttributeEditsTests(unittest.TestCase):
    def test_identity_is_unchanged(self):
        counts = MODULE.attribute_edits("Ouvre le fichier.", "Ouvre le fichier.", "Ouvre le fichier.")
        self.assertEqual((counts.fixed, counts.broken, counts.spurious, counts.verdict),
                         (0, 0, 0, "unchanged"))

    def test_counts_real_fix(self):
        counts = MODULE.attribute_edits(
            "Les document sont complet", "Les documents sont complets.", "Les documents sont complets.")
        self.assertEqual(counts.fixed, 2)
        self.assertEqual(counts.broken, 0)
        self.assertEqual(counts.verdict, "helpful")

    def test_counts_introduced_error(self):
        counts = MODULE.attribute_edits("tache sur le mur", "tâche sur le mur", "tache sur le mur")
        self.assertEqual(counts.broken, 1)
        self.assertEqual(counts.verdict, "harmful")

    def test_case_and_punctuation_ignored(self):
        counts = MODULE.attribute_edits("bonjour", "Bonjour.", "Bonjour.")
        self.assertEqual(counts.verdict, "unchanged")

    def test_code_switch_translation_is_harmful(self):
        counts = MODULE.attribute_edits(
            "je push sur main", "je pousse sur la branche principale", "je push sur main")
        self.assertEqual(counts.broken, 2)
        self.assertEqual(counts.verdict, "harmful")

    def test_removing_a_duplicate_word_is_helpful(self):
        counts = MODULE.attribute_edits("le le chat dort", "le chat dort", "le chat dort")
        self.assertEqual(counts.removed, 1)
        self.assertEqual(counts.verdict, "helpful")

    def test_long_multi_sentence_case_counts_once(self):
        filler = " ".join(["alors on continue la revue du module"] * 14)
        reference = "Les documents sont prêts. " + filler + " Il faut une tache simple."
        source = "Les document sont prêts. " + filler + " Il faut une tache simple."
        output = "Les documents sont prêts. " + filler + " Il faut une tâche simple."
        self.assertGreater(len(MODULE.tokens(reference)), 100)
        counts = MODULE.attribute_edits(source, output, reference)
        self.assertEqual((counts.fixed, counts.broken, counts.verdict), (1, 1, "mixed"))


class ScoreReportTests(unittest.TestCase):
    def report(self):
        return {"results": [
            result("one", "Les document sont complet", "Les documents sont complets.",
                   "Les documents sont complets.", "Les documents sont complets."),
            result("two", "tache sur le mur", "tâche sur le mur", "tache sur le mur",
                   "tache sur le mur"),
        ]}

    def test_report_scores_each_stage_separately(self):
        score = MODULE.score_report(self.report())
        self.assertEqual(score["stages"]["candidate"]["harmfulCases"], 1)
        self.assertEqual(score["stages"]["candidate"]["brokenTokens"], 1)
        self.assertEqual(score["stages"]["finalText"]["harmfulCases"], 0)
        self.assertEqual(score["stages"]["finalText"]["fixedTokens"], 2)

    def test_missing_candidate_counts_as_no_model_output(self):
        report = {"results": [result("one", "Bonjour.", "", "Bonjour.", "Bonjour.")]}
        score = MODULE.score_report(report)
        self.assertEqual(score["stages"]["candidate"]["unchangedCases"], 1)
        self.assertEqual(score["stages"]["candidate"]["noModelOutputCases"], 1)

    def test_v3_stage_falls_back_to_final_text(self):
        report = self.report()
        report["results"][0]["v3Text"] = "Les document sont complet"
        score = MODULE.score_report(report)
        self.assertEqual(score["stages"]["v3Text"]["fixedTokens"], 0)
        self.assertEqual(score["stages"]["v3Text"]["unchangedCases"], 2)

    def test_rejects_duplicate_case_ids(self):
        report = self.report()
        report["results"][1]["id"] = "one"
        with self.assertRaises(ValueError):
            MODULE.score_report(report)

    def test_never_prints_text(self):
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            output_path = Path(directory) / "score.json"
            report_path.write_text(json.dumps(self.report()))
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                MODULE.main(["--report", str(report_path), "--output", str(output_path)])
            printed = stdout.getvalue()
            self.assertNotIn("document", printed)
            self.assertNotIn("tache", printed)
            written = json.loads(output_path.read_text())
            self.assertNotIn("tache", json.dumps(written["rows"]))


if __name__ == "__main__":
    unittest.main()
