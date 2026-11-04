from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from Tools.training.prepare_wispr_youtube_handoff import build_queue, load_global_approval, sha256, write_json, write_jsonl
from Tools.training.serve_wispr_youtube_review import ReviewApplication, validate_review
from Tools.training.verify_wispr_youtube_handoff import require_sha


class YouTubeHandoffTests(unittest.TestCase):
    def test_global_consent_is_bound_to_snapshot_and_preserves_review_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            handoff = {"queue_count": 2, "queue_sha256": "snapshot-a", "inputs": {"source": "hash"}}
            receipt = {"schema": "voxol-youtube-global-user-approval-v1", "approved": True,
                       "scope": "all_segments_in_frozen_queue", "queue_sha256": "snapshot-a",
                       "segment_count": 2, "inputs": handoff["inputs"], "qwen_pilot_config": None}
            write_json(root / "user-approval.json", receipt)
            write_json(root / "review-state.json", {"reviews": {}})
            before = (root / "review-state.json").read_bytes()
            self.assertEqual(load_global_approval(root, handoff)["segment_count"], 2)
            self.assertEqual((root / "review-state.json").read_bytes(), before)
            handoff["queue_sha256"] = "snapshot-b"
            with self.assertRaisesRegex(ValueError, "does not match"):
                load_global_approval(root, handoff)

    def test_preflight_rejects_a_changed_input(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "artifact"
            artifact.write_bytes(b"frozen")
            expected = sha256(artifact)
            artifact.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "SHA-256 changed"):
                require_sha(artifact, expected)

    def test_queue_keeps_failed_and_accepted_segments_distinct(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audio = root / "records" / "clip.wav"
            audio.parent.mkdir()
            audio.write_bytes(b"RIFFdummy")
            digest = hashlib.sha256(audio.read_bytes()).hexdigest()
            teacher = [
                {"id": "a", "audio_path": "records/clip.wav", "audio_sha256": digest,
                 "recording_id": "r", "source_video_id": "v", "chunk": 1,
                 "requested_language": "fr", "raw": "bonjour", "edited": "Bonjour.",
                 "raw_http_status": "200", "edited_http_status": "200"},
                {"id": "b", "audio_path": "records/clip.wav", "audio_sha256": digest,
                 "recording_id": "r", "source_video_id": "v", "chunk": 2,
                 "requested_language": "fr", "raw": "suite", "edited": "",
                 "raw_http_status": "200", "edited_http_status": "500"},
            ]
            luna = [{"id": "a", "audio_sha256": digest, "raw_original": "bonjour", "edited_original": "Bonjour.", "decision": "keep", "proposed_text": "Bonjour."}]
            queue, failures = build_queue(
                teacher, luna, [{"id": "a", "rawText": "bonjour"}],
                [{"id": "a", "target_text": "Bonjour."}], set(), set(), set(),
                {"r": "test"}, root,
            )
            self.assertEqual(len(queue), 2)
            self.assertEqual(len(failures), 1)
            self.assertEqual(queue[0]["id"], "a")
            self.assertEqual(queue[0]["qwen_candidate_status"], "accepted")
            self.assertIn("wispr_edited_failed", queue[1]["flags"])
            self.assertFalse(queue[0]["humanReviewed"])

    def test_verification_requires_audio_and_matching_raw(self) -> None:
        item = {"voxol_raw": "hello"}
        payload = {"status": "verified", "audio_confirmed": False, "verify_asr": True, "asr_text": "hello"}
        with self.assertRaisesRegex(ValueError, "listened"):
            validate_review(item, payload, "2026-09-25T00:00:00Z")
        payload["audio_confirmed"] = True
        payload["verify_asr"] = False
        payload["verify_qwen"] = True
        payload["qwen_target"] = "Hello."
        with self.assertRaisesRegex(ValueError, "matching VoxoL"):
            validate_review({"voxol_raw": ""}, payload, "2026-09-25T00:00:00Z")
        self.assertTrue(validate_review(item, payload, "2026-09-25T00:00:00Z")["verify_qwen"])

    def test_review_exports_only_explicitly_verified_rows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset = root / "dataset"
            dataset.mkdir()
            (dataset / "clip.wav").write_bytes(b"RIFFdummy")
            item = {
                "id": "a", "audio_path": "clip.wav", "audio_sha256": sha256(dataset / "clip.wav"),
                "recording_id": "r", "source_video_id": "v", "language": "en", "split": "test",
                "voxol_raw": "hello", "chunk": 1, "flags": [], "priority": 0,
                "qwen_candidate_status": "accepted",
            }
            write_jsonl(root / "review-queue.jsonl", [item])
            queue_digest = sha256(root / "review-queue.jsonl")
            write_json(root / "handoff.json", {"queue_sha256": queue_digest, "dataset_root": str(dataset)})
            write_json(root / "review-state.json", {"queue_sha256": queue_digest, "reviews": {}, "updated_at_utc": None})
            html = Path(__file__).with_name("wispr_youtube_review.html")
            app = ReviewApplication(root, html)
            self.assertEqual(json.loads((root / "human-review-summary.json").read_text())["verified_count"], 0)
            app.save("a", {"status": "verified", "audio_confirmed": True, "verify_asr": True,
                           "asr_text": "Hello", "verify_qwen": True, "qwen_target": "Hello.", "notes": "heard"})
            rows = [json.loads(line) for line in (root / "human-reviewed.jsonl").read_text().splitlines()]
            self.assertEqual(len(rows), 1)
            self.assertTrue(rows[0]["humanReviewed"])
            self.assertFalse(rows[0]["approved"])
            app.save("a", {"status": "skipped", "notes": "uncertain"})
            self.assertEqual((root / "human-reviewed.jsonl").read_text(), "")


if __name__ == "__main__":
    unittest.main()
