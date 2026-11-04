import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("calibrate-asr-word-risk.py")
SPEC = importlib.util.spec_from_file_location("calibrate_asr_word_risk", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ASRWordRiskCalibrationTests(unittest.TestCase):
    def test_fit_is_monotonic_and_pools_violations(self):
        rows = [
            {"minimum_margin": 0.1, "correct": False},
            {"minimum_margin": 0.2, "correct": True},
            {"minimum_margin": 0.3, "correct": False},
            {"minimum_margin": 0.4, "correct": True},
        ]

        knots = MODULE.fit_isotonic(rows)
        probabilities = [knot["errorProbability"] for knot in knots]

        self.assertEqual([knot["margin"] for knot in knots], [0.1, 0.2, 0.3, 0.4])
        self.assertEqual(probabilities, [1.0, 0.5, 0.5, 0.0])
        self.assertTrue(
            all(left >= right for left, right in zip(probabilities, probabilities[1:]))
        )

    def test_report_matches_swift_runtime_schema(self):
        report = MODULE.build_report(
            [
                {
                    "surface": "voxol",
                    "correct": False,
                    "minimum_margin": 0.2,
                    "language": "fr",
                },
                {
                    "surface": "rapport",
                    "correct": True,
                    "minimum_margin": 1.2,
                    "language": "fr",
                },
            ]
        )

        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual(report["method"], "isotonic-pav")
        self.assertEqual(report["rowCount"], 2)
        self.assertEqual(report["errorCount"], 1)
        self.assertEqual(len(report["knots"]), 2)


if __name__ == "__main__":
    unittest.main()
