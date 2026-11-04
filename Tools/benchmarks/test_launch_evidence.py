import copy
import hashlib
import unittest

import dictation_campaign as c
import launch_evidence as e


def fixture():
    provenance = {"kind": "public", "humanReviewed": False, "checks": ["fixture"],
                  "sourceSHA256": "1" * 64, "dataset": "google/fleurs", "revision": "2" * 40,
                  "license": "CC-BY-4.0"}
    item = {"id": "fleurs-en_us-test-abcdef", "audioPath": "private-path-not-exported.wav",
            "language": "english", "categories": ["public"], "sourceGroup": "fleurs-en_us-test",
            "split": "public", "decision": "accepted", "reasons": ["fixture"],
            "audio": {"sha256": "3" * 64, "sampleDataSHA256": "4" * 64, "sampleRate": 16000,
                      "channels": 1, "bitsPerSample": 32, "encoding": "float", "durationSeconds": 2},
            "references": {kind: {"text": "keep three commits", "provenance": provenance}
                           for kind in ("verbatim", "faithful")}}
    manifest = c.freeze({"items": [item]})
    run = {"manifestSHA256": manifest["manifestSHA256"], "split": "public", "runnerSHA256": "5" * 64,
           "model": {"revision": "6" * 40, "sha256": "7" * 64}, "privateContext": "NEVER_EXPORT"}
    row = {**c.identity(manifest["items"][0], run), "status": "ok", "transcript": "keep three commits",
           "inferenceMilliseconds": 100.0, "privateContext": "NEVER_EXPORT"}
    return manifest, run, row


class LaunchEvidenceTests(unittest.TestCase):
    def test_allowlist_omits_text_private_context_and_paths(self):
        manifest, run, row = fixture()
        model, proof = e.export_model("parakeet", manifest, run, [row])
        import json
        value = json.dumps([model, proof])
        for forbidden in ("NEVER_EXPORT", "private-path", "keep three commits"):
            self.assertNotIn(forbidden, value)
        self.assertEqual(model["counts"]["werPercent"], 0)
        self.assertIsNone(model["releaseToVisibleMilliseconds"])
        self.assertIsNone(model["uncertainty95"])

    def test_missing_inference_stays_in_denominator(self):
        manifest, run, _ = fixture()
        model, _ = e.export_model("parakeet", manifest, run, [])
        self.assertEqual(model["counts"]["referenceWords"], 3)
        self.assertEqual(model["counts"]["werPercent"], 100)
        self.assertEqual(model["counts"]["failures"], 1)
        self.assertEqual(model["counts"]["missing"], 1)

    def test_error_with_partial_transcript_is_not_a_success(self):
        manifest, run, row = fixture()
        row["status"] = "error"
        model, _ = e.export_model("parakeet", manifest, run, [row])
        self.assertEqual(model["counts"]["errors"], 3)
        self.assertEqual(model["counts"]["failures"], 1)

    def test_rejects_other_cohort(self):
        manifest, run, row = fixture()
        run["manifestSHA256"] = "a" * 64
        with self.assertRaises(ValueError):
            e.export_model("parakeet", manifest, run, [row])

    def test_rejects_ai_provenance_even_when_frozen(self):
        manifest, run, row = fixture()
        manifest = copy.deepcopy(manifest)
        for reference in manifest["items"][0]["references"].values():
            reference["provenance"]["kind"] = "ai-legacy"
        manifest = c.freeze(manifest)
        with self.assertRaises(ValueError):
            e.export_model("parakeet", manifest, run, [row])

    def test_rejects_nan_latency(self):
        manifest, run, row = fixture()
        row["inferenceMilliseconds"] = float("nan")
        with self.assertRaises(ValueError):
            e.export_model("parakeet", manifest, run, [row])

    def test_rejects_stale_prediction(self):
        manifest, run, row = fixture()
        row["audioSHA256"] = "0" * 64
        with self.assertRaises(ValueError):
            e.export_model("parakeet", manifest, run, [row])

    def test_rejects_forged_count(self):
        bad = dict.fromkeys(e.COUNT_KEYS, 0)
        bad.update(count=1, referenceWords=3, errors=2, substitutions=1)
        with self.assertRaises(ValueError):
            e.counts(bad)


if __name__ == "__main__":
    unittest.main()
