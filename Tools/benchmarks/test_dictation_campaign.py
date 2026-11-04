from __future__ import annotations

import copy
from pathlib import Path
import struct
import tempfile
import unittest
import wave

import dictation_campaign as c


class DictationCampaignTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.run = {"model": "public-model", "revision": "revision-a", "parameters": {"temperature": 0},
                    "runnerSHA256": "runner-a"}
        self.items = []
        for i, text in enumerate(("Tu gardes 3 commits.", "Ne change pas le dépôt.")):
            path = self.root / f"{i}.wav"
            with wave.open(str(path), "wb") as stream:
                stream.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                stream.writeframes(struct.pack("<h", i + 1) * 1600)
            provenance = {"kind": "ai-controlled", "humanReviewed": False, "model": "teacher",
                          "revision": "teacher-rev", "promptSHA256": c.digest("prompt"),
                          "sourceSHA256": c.digest("source"), "checks": ["independent consensus"]}
            self.items.append({"id": str(i), "audioPath": path.name, "audio": c.wav_info(path),
                               "sourceGroup": f"session-{i}", "split": "diagnostic", "decision": "accepted",
                               "reasons": ["test fixture"], "language": "fr", "categories": [],
                               "references": {k: {"text": text, "provenance": copy.deepcopy(provenance)}
                                              for k in ("verbatim", "faithful")}})
        self.manifest = c.freeze({"items": self.items})
        self.items = self.manifest["items"]

    def prediction(self, item=0, **kwargs):
        return {**c.identity(self.items[item], self.run), "status": "ok",
                "transcript": self.items[item]["references"]["verbatim"]["text"], **kwargs}

    def test_valid_manifest_verifies_real_audio(self):
        c.validate(self.manifest, self.root)

    def test_swapped_audio_paths_are_rejected(self):
        changed = copy.deepcopy(self.manifest)
        changed["items"][0]["audioPath"] = "1.wav"
        changed = c.freeze(changed)
        with self.assertRaisesRegex(ValueError, "Audio/ID"):
            c.validate(changed, self.root)

    def test_changed_reference_cannot_reuse_prediction(self):
        changed = copy.deepcopy(self.manifest)
        changed["items"][0]["references"]["faithful"]["text"] = "Tu gardes 4 commits."
        with self.assertRaises(ValueError):
            c.validate(changed)
        changed = c.freeze(changed)
        with self.assertRaisesRegex(ValueError, "Stale"):
            c.validate_results([self.prediction()], changed["items"], self.run)

    def test_duplicate_ids_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            c.freeze({"items": self.items + [self.items[0]]})
        with self.assertRaisesRegex(ValueError, "duplicate"):
            c.validate_results([self.prediction(), self.prediction()], self.items, self.run)

    def test_unknown_result_id_is_rejected(self):
        with self.assertRaises(ValueError):
            c.validate_results([self.prediction(id="other")], self.items, self.run)

    def test_source_groups_cannot_cross_splits(self):
        changed = copy.deepcopy(self.items)
        changed[1].update(sourceGroup=changed[0]["sourceGroup"], split="reserved")
        with self.assertRaisesRegex(ValueError, "crosses splits"):
            c.freeze({"items": changed})

    def test_duplicate_audio_cannot_become_another_example(self):
        changed = copy.deepcopy(self.items)
        changed[1]["audio"] = changed[0]["audio"]
        with self.assertRaisesRegex(ValueError, "Duplicate recording"):
            c.freeze({"items": changed})

    def test_missing_result_remains_in_denominator(self):
        report = c.score(self.items, [self.prediction()], self.run)
        self.assertFalse(report["coverageComplete"])
        self.assertEqual(report["summary"]["count"], 2)
        self.assertEqual(report["summary"]["referenceWords"], 9)
        self.assertEqual(report["summary"]["deletions"], 5)
        self.assertEqual(report["summary"]["missing"], 1)

    def test_unrestored_candidate_cannot_be_scored_as_product_text(self):
        prediction = self.prediction(candidate="Tu gardes VOXOLP0 commits.", finalText="Tu gardes 3 commits.")
        with self.assertRaisesRegex(ValueError, "protected tokens"):
            c.score(self.items, [prediction], self.run, "candidate")
        self.assertEqual(c.score(self.items[:1], [prediction], self.run, "final")["summary"]["errors"], 0)

    def test_failed_inference_is_not_removed(self):
        report = c.score(self.items, [self.prediction(), self.prediction(1, status="error", transcript="ignored")], self.run)
        self.assertEqual(report["summary"]["failures"], 1)
        self.assertEqual(report["summary"]["deletions"], 5)
        self.assertEqual(report["summary"]["referenceWords"], 9)

    def test_placeholder_for_unproduced_inference_is_not_complete_coverage(self):
        row = self.prediction(1, status="error", missingInference=True)
        report = c.score(self.items, [self.prediction(), row], self.run)
        self.assertFalse(report["coverageComplete"])
        self.assertEqual(report["summary"]["referenceWords"], 9)

    def test_all_missing_is_a_report_not_a_statistics_exception(self):
        report = c.score(self.items, [], self.run)
        self.assertEqual(report["summary"]["lexicalWER"], 1)
        self.assertIsNone(report["latencyMilliseconds"]["p95"])
        self.assertFalse(report["promotionAllowed"])

    def test_failed_correction_scores_its_actual_fallback(self):
        row = self.prediction(finalText=self.items[0]["references"]["faithful"]["text"], failure="generationTimedOut")
        report = c.score(self.items[:1], [row], self.run, "final")
        self.assertEqual(report["summary"]["errors"], 0)
        self.assertEqual(report["summary"]["failures"], 1)

    def test_resume_checks_model_parameters_and_runner(self):
        for key, value in (("revision", "revision-b"), ("parameters", {"temperature": .1}),
                           ("runnerSHA256", "runner-b")):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "Stale"):
                c.validate_results([self.prediction()], self.items, {**self.run, key: value})

    def test_ai_references_cannot_claim_human_approval(self):
        changed = copy.deepcopy(self.items)
        changed[0]["references"]["faithful"]["provenance"]["humanReviewed"] = True
        with self.assertRaisesRegex(ValueError, "human approval"):
            c.freeze({"items": changed})

    def test_ai_controlled_requires_revision_and_prompt(self):
        changed = copy.deepcopy(self.items)
        changed[0]["references"]["verbatim"]["provenance"]["revision"] = None
        with self.assertRaisesRegex(ValueError, "revision"):
            c.freeze({"items": changed})

    def test_audio_symlink_cannot_escape_root(self):
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside) / "private.wav"
            target.write_bytes(b"not authorized")
            (self.root / "escape.wav").symlink_to(target)
            with self.assertRaises(ValueError):
                c.safe_audio_path(self.root, "escape.wav")

    def test_float32_wav_is_not_mislabelled_pcm(self):
        samples = struct.pack("<f", .25) * 1600
        fmt = struct.pack("<HHIIHH", 3, 1, 16000, 64000, 4, 32)
        body = b"WAVEfmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(samples)) + samples
        path = self.root / "native.wav"
        path.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)
        info = c.wav_info(path)
        self.assertEqual(info["encoding"], "float")
        self.assertEqual(info["durationSeconds"], .1)

    def test_truncated_wav_is_rejected(self):
        path = self.root / "0.wav"
        path.write_bytes(path.read_bytes()[:-10])
        with self.assertRaisesRegex(ValueError, "Truncated"):
            c.wav_info(path)

    def test_accents_numbers_negation_and_numeric_roles_are_not_erased(self):
        self.assertNotEqual(c.words("côté"), c.words("cote"))
        self.assertNotEqual(c.words("-3,5"), c.words("3,5"))
        self.assertNotEqual(c.words("do not"), c.words("do"))
        self.assertGreater(c.edit_counts(c.words("3 commits"), c.words("commit 3"))["errors"], 0)
        self.assertEqual(c.words("L’été."), c.words("l'été"))

    def test_zero_latency_is_an_observation(self):
        report = c.score(self.items[:1], [self.prediction(inferenceMilliseconds=0)], self.run)
        self.assertEqual(report["latencyMilliseconds"]["p50"], 0)

    def test_invalid_latency_is_rejected(self):
        for latency in (-1, float("nan"), True):
            with self.subTest(latency=latency), self.assertRaises(ValueError):
                c.validate_results([self.prediction(inferenceMilliseconds=latency)], self.items, self.run)

    def test_final_stage_uses_processor_duration_not_asr_duration(self):
        row = self.prediction(finalText="Tu gardes 3 commits.",
                              inferenceMilliseconds=11, durationMilliseconds=501)
        report = c.score(self.items[:1], [row], self.run, "final")
        self.assertEqual(report["latencyMilliseconds"]["p50"], 501)
        self.assertEqual(report["latencyObservationField"], "durationMilliseconds")

    def test_missing_processor_timer_is_not_substituted_with_asr_timer(self):
        row = self.prediction(finalText="Tu gardes 3 commits.", inferenceMilliseconds=11)
        report = c.score(self.items[:1], [row], self.run, "final")
        self.assertIsNone(report["latencyMilliseconds"]["p50"])
        self.assertEqual(report["timingCoverage"]["missing"], 1)

    def test_normalization_has_no_inferred_timer(self):
        row = self.prediction(normalized="Tu gardes 3 commits.",
                              inferenceMilliseconds=11, durationMilliseconds=501)
        report = c.score(self.items[:1], [row], self.run, "normalized")
        self.assertIsNone(report["latencyMilliseconds"]["p50"])
        self.assertIsNone(report["latencyObservationField"])

    def test_present_row_without_stage_text_is_missing_and_failed(self):
        report = c.score(self.items[:1], [self.prediction()], self.run, "final")
        self.assertFalse(report["coverageComplete"])
        self.assertEqual(report["summary"]["missing"], 1)
        self.assertEqual(report["summary"]["failures"], 1)
        self.assertEqual(report["summary"]["deletions"], 4)

    def test_unproduced_placeholder_is_counted_as_missing(self):
        row = self.prediction(status="error", missingInference=True, inferenceMilliseconds=0)
        report = c.score(self.items[:1], [row], self.run)
        self.assertEqual(report["summary"]["missing"], 1)
        self.assertEqual(report["timingCoverage"]["observed"], 0)
        self.assertIsNone(report["latencyMilliseconds"]["p50"])

    def test_failure_timings_are_kept_but_not_mislabeled_as_successes(self):
        rows = [self.prediction(inferenceMilliseconds=500),
                self.prediction(1, status="error", inferenceMilliseconds=1)]
        report = c.score(self.items, rows, self.run)
        self.assertEqual(report["successfulLatencyMilliseconds"]["p50"], 500)
        self.assertEqual(report["failedLatencyMilliseconds"]["p50"], 1)
        self.assertEqual(report["timingCoverage"],
                         {"expected": 2, "observed": 2, "missing": 0, "successful": 1, "failed": 1})

    def test_two_locale_groups_are_not_a_reliable_bootstrap(self):
        report = c.score(self.items, [self.prediction(), self.prediction(1)], self.run)
        self.assertEqual(report["summary"]["groupBootstrap95CI"], [None, None])
        self.assertEqual(report["summary"]["bootstrapMinimumGroups"], 20)

    def test_invalid_percentile_arguments_fail_closed(self):
        for values, p in [([1], -0.1), ([1], 1.1), ([1], float("nan")),
                          ([float("inf")], .5), ([-1], .5), ([True], .5)]:
            with self.subTest(values=values, p=p), self.assertRaises(ValueError):
                c.percentile(values, p)


if __name__ == "__main__":
    unittest.main()
