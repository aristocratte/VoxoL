import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "compare_polisher_runs", Path(__file__).resolve().parent / "compare-polisher-runs.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PolisherRunComparisonTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def write(self, name, rows):
        path = self.root / name
        path.write_text(json.dumps({"results": rows}), encoding="utf-8")
        return path

    @staticmethod
    def row(identifier, duration=100, candidate="same", final="same", failure=None):
        return {"id": identifier, "durationMilliseconds": duration, "candidate": candidate,
                "finalText": final, "failure": failure, "accepted": failure is None}

    def test_comparison_matches_ids_not_order(self):
        a = self.write("a.json", [self.row("one"), self.row("two")])
        b = self.write("b.json", [self.row("two"), self.row("one")])
        result = MODULE.compare_runs(a, b)
        self.assertEqual(result["caseCount"], 2)
        self.assertEqual(result["rawTextDifferences"], 0)

    def test_failure_is_in_headline_but_not_complete_only_subset(self):
        a = self.write("a.json", [self.row("one"), self.row("two")])
        b = self.write("b.json", [self.row("one", 50), self.row("two", 3000, "", failure="timeout")])
        result = MODULE.compare_runs(a, b)
        self.assertEqual(result["allCases"]["candidate"]["meanMs"], 1525)
        self.assertEqual(result["bothCompleted"]["candidate"]["count"], 1)
        self.assertEqual(result["rawTextDifferences"], 1)
        self.assertEqual(result["finalTextDifferences"], 0)
        self.assertNotIn('"same"', json.dumps(result))

    def test_different_case_sets_are_rejected(self):
        a = self.write("a.json", [self.row("one")])
        b = self.write("b.json", [self.row("two")])
        with self.assertRaises(ValueError):
            MODULE.compare_runs(a, b)

    def test_duplicate_case_ids_are_rejected(self):
        a = self.write("a.json", [self.row("one"), self.row("one")])
        with self.assertRaises(ValueError):
            MODULE.read_run(a)

    def test_percentile_includes_slowest_case_in_small_sample(self):
        summary = MODULE.duration_summary([self.row(str(i), i) for i in range(1, 13)])
        self.assertEqual(summary["medianMs"], 6.5)
        self.assertEqual(summary["p95Ms"], 12)


if __name__ == "__main__":
    unittest.main()
