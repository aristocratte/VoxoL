#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("compare_transcriber_reports.py")
SPEC = importlib.util.spec_from_file_location("compare_transcriber_reports", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CompareTranscriberReportsTests(unittest.TestCase):
    def test_summary_keeps_raw_and_final_metrics_distinct(self) -> None:
        report = {
            "rawVerbatim": {
                "itemCount": 10,
                "wordErrors": {
                    "substitutions": 10,
                    "deletions": 5,
                    "insertions": 5,
                    "referenceUnitCount": 100,
                },
                "exactMatchRate": 0.1,
                "criticalSpanErrorRate": 0.3,
            },
            "finalClean": {
                "itemCount": 10,
                "wordErrors": {
                    "substitutions": 5,
                    "deletions": 3,
                    "insertions": 2,
                    "referenceUnitCount": 100,
                },
                "exactMatchRate": 0.4,
                "criticalSpanErrorRate": 0.0,
            },
        }

        row = MODULE.summarize("Gemini", report)

        self.assertEqual(row["raw_wer"], 0.2)
        self.assertEqual(row["final_wer"], 0.1)
        self.assertEqual(row["raw_critical_span_error_rate"], 0.3)


if __name__ == "__main__":
    unittest.main()
