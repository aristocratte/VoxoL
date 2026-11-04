import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "build_human_revision_suite", Path(__file__).with_name("build-human-revision-suite.py")
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def record(final, edit=None, raw="texte brut", example=False):
    """History records keep an undo stack: `revisions` holds earlier values, oldest first.

    A record starts as text=final, revisions=[raw] (or [] when raw == final); an owner edit
    pushes the current text, so an edited record is text=edit, revisions=[raw, final].
    """
    stack = [raw] if raw != final else []
    if edit is not None:
        stack.append(final)
    revisions = [{"id": f"r{index}", "createdAt": "2026-09-01T10:00:00Z", "text": text}
                 for index, text in enumerate(stack)]
    return {"id": "h-" + final[:6], "createdAt": "2026-09-01T09:59:00Z",
            "text": edit if edit is not None else final, "revisions": revisions,
            "undoneRevisions": [], "isExample": example}


class LinkTests(unittest.TestCase):
    def test_links_by_normalized_final_text(self):
        history = [record("Il faut  livrer demain.", edit="Il faut livrer demain matin.",
                          raw="il faut livrer demain")]
        sessions = {"20260901-100000-aaaa": {"rawText": "il faut livrer demain",
                                             "finalText": "Il faut livrer demain."}}
        links, exclusions = MODULE.link_revisions(history, sessions)
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0].session_id, "20260901-100000-aaaa")
        self.assertEqual(links[0].raw_text, "il faut livrer demain")
        self.assertEqual(links[0].revision_text, "Il faut livrer demain matin.")
        self.assertEqual(exclusions, [])

    def test_unedited_record_is_not_an_owner_correction(self):
        history = [record("Il faut livrer demain.", raw="il faut livrer demain")]
        sessions = {"s1": {"rawText": "il faut livrer demain", "finalText": "Il faut livrer demain."}}
        links, exclusions = MODULE.link_revisions(history, sessions)
        self.assertEqual(links, [])
        self.assertEqual([reason for _, reason in exclusions], ["no-owner-edit"])

    def test_edit_of_a_text_equal_to_its_raw_transcript_is_found(self):
        history = [record("Bonjour.", edit="Bonjour Nora.", raw="Bonjour.")]
        sessions = {"s1": {"rawText": "Bonjour.", "finalText": "Bonjour."}}
        links, _ = MODULE.link_revisions(history, sessions)
        self.assertEqual([(link.raw_text, link.revision_text) for link in links],
                         [("Bonjour.", "Bonjour Nora.")])

    def test_unlinked_and_shared_final_texts_are_excluded_with_reason(self):
        history = [record("Bonjour à tous.", edit="Bonjour à toutes."),
                   record("Pas de session.", edit="Pas de séance.")]
        sessions = {"s1": {"rawText": "bonjour à tous", "finalText": "Bonjour à tous."},
                    "s2": {"rawText": "bonjour a tous", "finalText": "Bonjour à tous."}}
        links, exclusions = MODULE.link_revisions(history, sessions)
        self.assertEqual(links, [])
        self.assertEqual(sorted(reason for _, reason in exclusions), ["ambiguous-session", "unlinked"])


class CaseTests(unittest.TestCase):
    def link(self, final, revision, raw="texte brut de la dictée"):
        return MODULE.Link("s-" + str(abs(hash(final + revision))), raw, final, revision)

    def test_excludes_identical_and_rewrite_with_reason(self):
        links = [
            self.link("Je vais livrer le module demain.", "Je vais livrer le module demain."),
            self.link("Je vais livrer le module demain.",
                      "Merci de reprogrammer la réunion de lundi avec toute l'équipe produit."),
            self.link("Je vais livré le module demain.", "Je vais livrer le module demain."),
        ]
        cases, exclusions = MODULE.build_cases(links, owner_confirmed=False)
        self.assertEqual(len(cases), 1)
        self.assertEqual(sorted(reason for _, reason in exclusions),
                         ["identical-revision", "probable-rewrite"])

    def test_split_is_deterministic_per_session(self):
        first = MODULE.split_for("20260902-150321-a94ca3e8")
        self.assertEqual(first, MODULE.split_for("20260902-150321-a94ca3e8"))
        self.assertIn(first, ("train", "validation", "test"))
        splits = {MODULE.split_for(f"session-{index}") for index in range(200)}
        self.assertEqual(splits, {"train", "validation", "test"})

    def test_code_switch_sentence_is_french(self):
        self.assertEqual(MODULE.guess_language("je push sur main demain"), "fr")
        self.assertEqual(MODULE.guess_language("I will push this to the main branch"), "en")
        self.assertIsNone(MODULE.guess_language("B450 OAuth"))

    def test_approved_requires_owner_flag(self):
        links = [self.link("Je vais livré le module demain.", "Je vais livrer le module demain.")]
        unconfirmed, _ = MODULE.build_cases(links, owner_confirmed=False)
        confirmed, _ = MODULE.build_cases(links, owner_confirmed=True)
        self.assertFalse(unconfirmed[0]["approved"])
        self.assertTrue(confirmed[0]["approved"])
        self.assertEqual(confirmed[0]["source"], "human")
        self.assertEqual(confirmed[0]["transcript"], "texte brut de la dictée")
        self.assertEqual(confirmed[0]["expected"], "Je vais livrer le module demain.")

    def test_output_refuses_tracked_path(self):
        repository = Path(__file__).resolve().parents[1]
        with self.assertRaises(ValueError):
            MODULE.checked_output(repository / "Data/corpus/human-revision-suite")
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            MODULE.checked_output(Path(directory))
        self.assertEqual(MODULE.checked_output(repository / "outputs/qwen-corrector/x"),
                         (repository / "outputs/qwen-corrector/x").resolve())

    def test_write_suite_never_writes_text_into_manifest(self):
        links = [self.link("Je vais livré le module demain.", "Je vais livrer le module demain.")]
        cases, exclusions = MODULE.build_cases(links, owner_confirmed=False)
        repository = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(dir=repository / "outputs") as directory:
            MODULE.write_suite(Path(directory), cases, exclusions, inputs={"history": "abc"},
                               owner_confirmed=False)
            manifest = json.loads((Path(directory) / "manifest.json").read_text())
            self.assertNotIn("livrer", json.dumps(manifest))
            total = sum(manifest["countsBySplit"].values())
            self.assertEqual(total, 1)


if __name__ == "__main__":
    unittest.main()
