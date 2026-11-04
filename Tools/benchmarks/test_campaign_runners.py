from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import dictation_campaign as campaign
import run_mlx_asr_challenger as mlx_runner
import score_asr_challengers as scorer
import test_dictation_campaign as fixtures


class CampaignRunnerTests(unittest.TestCase):
    def test_native_inference_receives_only_audio_identity_without_review_claim(self):
        root = Path(__file__).resolve().parents[2]
        spec = importlib.util.spec_from_file_location("native_runner", root / "Scripts/run-dictation-campaign.py")
        native = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(native)
        item = {"id": "clip", "audioPath": "clip.wav", "audio": {"sha256": "a" * 64},
                "references": {"verbatim": {"text": "Private target", "humanReviewed": False}}}
        result = native.native_manifest([item], "b" * 64)
        self.assertEqual(result["items"], [{"id": "clip", "audioPath": "clip.wav", "audioSHA256": "a" * 64}])
        self.assertNotIn("reviewed", json.dumps(result))
        self.assertNotIn("Private target", json.dumps(result))

    def test_generation_never_receives_reference_language_or_vocabulary(self):
        self.assertEqual(mlx_runner.campaign_options("Qwen3-ASR-0.6B", 123),
                         {"language": None, "verbose": False, "temperature": 0.0,
                          "min_chunk_duration": .1, "max_tokens": 123})
        self.assertNotIn("prompt", mlx_runner.campaign_options("whisper", 123))

    def test_legacy_scorer_counts_failed_and_missing_items(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = [{"id": str(i), "referenceRawText": "one two", "parakeetText": "one two"} for i in range(3)]
            candidate = [{"id": "0", "transcript": "one two", "status": "ok"},
                         {"id": "1", "transcript": "ignored", "status": "error"}]
            for name, rows in (("baseline", baseline), ("candidate", candidate)):
                (root / f"{name}.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows))
            subprocess.run([sys.executable, scorer.__file__, "--baseline", str(root / "baseline.jsonl"),
                            "--candidate", "test=" + str(root / "candidate.jsonl"),
                            "--output", str(root / "report.json")], check=True, capture_output=True)
            result = json.loads((root / "report.json").read_text())["candidates"]["test"]
            self.assertEqual(result["candidate"]["count"], 3)
            self.assertAlmostEqual(result["candidate"]["microWER"], 4 / 6)
            self.assertFalse(result["coverage"]["complete"])
            self.assertEqual(result["coverage"]["errors"], 1)
            self.assertEqual(result["coverage"]["missing"], 1)

    def test_paired_comparison_reports_correct_witness_regression(self):
        fixture = fixtures.DictationCampaignTests()
        fixture.setUp()
        try:
            baseline = campaign.score(fixture.items, [fixture.prediction(), fixture.prediction(1)], fixture.run)
            candidate = campaign.score(fixture.items, [fixture.prediction(transcript="Tu gardes 4 commits."),
                                                       fixture.prediction(1)], fixture.run)
            result = scorer.paired_difference(fixture.items, baseline, candidate)
            self.assertEqual(result["previouslyCorrectRegressions"], 1)
            self.assertEqual(result["newNumericSequenceAlerts"], 1)
            self.assertIsNone(result["relativeErrorReduction"])
            self.assertEqual(result["worsened"], 1)
        finally:
            fixture.doCleanups()

    def test_script_modules_import_without_mlx(self):
        root = Path(__file__).resolve().parents[2]
        for name in ("prepare-dictation-campaign", "run-dictation-campaign", "prepare-dictation-challengers"):
            spec = importlib.util.spec_from_file_location(name, root / "Scripts" / (name + ".py"))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)


if __name__ == "__main__":
    unittest.main()
