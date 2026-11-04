import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("audit-diagnostic-corpus.py")
SPEC = importlib.util.spec_from_file_location("audit_diagnostic_corpus", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DiagnosticCorpusAuditTests(unittest.TestCase):
    def test_reports_gate_exclusions_duplicates_and_group_safe_splits(self):
        rows = [
            {
                "id": "one-faithful",
                "language": "fr",
                "mode": "faithful",
                "split_group": "one",
                "raw_transcript": "un texte assez long pour tester la cible ici",
                "target_text": "Un texte assez long ici.",
            },
            {
                "id": "one-rewrite",
                "language": "es",
                "mode": "rewrite",
                "split_group": "one",
                "raw_transcript": "un texte assez long pour tester la cible ici",
                "target_text": "Bref.",
            },
        ]

        audit = MODULE.build_audit(rows, "abc")

        self.assertEqual(audit["role"], "diagnostic-ai-labeled-v1")
        self.assertEqual(audit["independentSourceCount"], 1)
        self.assertEqual(audit["frEnGate"]["excludedIDs"], ["one-rewrite"])
        self.assertEqual(audit["groupAwareSplits"]["leakingSplitGroups"], [])
        self.assertEqual(len(audit["duplicates"]["sharedRawTranscriptGroups"]), 1)
        self.assertEqual(len(audit["suspiciouslyShortTargets"]), 1)


if __name__ == "__main__":
    unittest.main()
