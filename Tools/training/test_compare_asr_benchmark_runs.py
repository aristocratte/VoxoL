#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("compare_asr_benchmark_runs.py")
SPEC = importlib.util.spec_from_file_location("compare_asr_benchmark_runs", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CompareASRBenchmarkRunsTests(unittest.TestCase):
    def test_comparison_calculates_quality_and_latency_deltas(self) -> None:
        baseline = {
            "schema_version": 1,
            "candidate_delta_sha256": "same",
            "encoder_weight_sha256": "old",
            "benchmarks": [
                {"benchmark_id": "fixture", "item_count": 10, "micro_wer": 0.10, "p95_ms": 100}
            ],
        }
        candidate = {
            "schema_version": 1,
            "candidate_delta_sha256": "same",
            "encoder_weight_sha256": "new",
            "benchmarks": [
                {"benchmark_id": "fixture", "item_count": 10, "micro_wer": 0.08, "p95_ms": 120}
            ],
        }
        report = MODULE.compare(baseline, candidate)
        self.assertAlmostEqual(report["benchmarks"][0]["absolute_wer_delta"], -0.02)
        self.assertAlmostEqual(report["benchmarks"][0]["relative_wer_delta"], -0.2)
        self.assertAlmostEqual(report["benchmarks"][0]["p95_ratio"], 1.2)
        self.assertTrue(report["candidate_passes_non_regression"])


if __name__ == "__main__":
    unittest.main()
