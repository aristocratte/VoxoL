#!/usr/bin/env python3
"""Provenance and selection checks for the experimental YouTube Qwen corpus."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import wave

from prepare_wispr_youtube_qwen import prepare, read_rows, reviewed_targets, split_map


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


class PrepareWisprYoutubeQwenTests(unittest.TestCase):
    def fixture(self, root: Path) -> dict[str, Path]:
        dataset = root / "dataset"
        audio = dataset / "records" / "video-a" / "audio" / "chunk_0001.wav"
        audio.parent.mkdir(parents=True)
        with wave.open(str(audio), "wb") as stream:
            stream.setnchannels(1)
            stream.setsampwidth(2)
            stream.setframerate(16_000)
            stream.writeframes(b"\0\0" * 16_000)
        audio_hash = hashlib.sha256(audio.read_bytes()).hexdigest()
        texts = [
            ("keep", "The first simple phrase", "The first simple phrase."),
            ("correct", "A bright red light", "A bright red light."),
            ("needs_audio", "Three uncertain spoken words", "Three uncertain spoken words."),
            ("correct", "Four clearly spoken words", "Four clearly spoken words."),
        ]
        teacher_rows = []
        review_rows = []
        prediction_rows = []
        for index, (decision, raw, edited) in enumerate(texts, 1):
            identifier = f"video-a-chunk-{index:04d}"
            relative = "records/video-a/audio/chunk_0001.wav"
            teacher_rows.append({
                "id": identifier, "recording_id": "video-a", "source_video_id": "videoaa",
                "audio_path": relative, "audio_sha256": audio_hash,
                "raw": raw, "edited": edited,
                "raw_http_status": "200", "edited_http_status": "200",
                "requested_language": "en", "detected_language": "en",
            })
            review_rows.append({
                "id": identifier, "audio_path": relative, "audio_sha256": audio_hash,
                "raw_original": raw, "edited_original": edited,
                "proposed_text": "A bright green light." if index == 2 else edited,
                "decision": decision, "approved": False, "humanReviewed": False,
            })
            if index <= 2:
                prediction_rows.append({"id": identifier, "rawText": raw})
        paths = {name: root / name for name in (
            "teacher.jsonl", "review.jsonl", "audit.json", "split.json",
            "predictions.jsonl", "runtime-report.json", "dataset", "output",
        )}
        write_jsonl(paths["teacher.jsonl"], teacher_rows)
        write_jsonl(paths["review.jsonl"], review_rows)
        write_jsonl(paths["predictions.jsonl"], prediction_rows)
        paths["audit.json"].write_text(json.dumps({
            "reviewed_rows": 4, "snapshot_complete": True,
            "warnings": [{"id": "video-a-chunk-0004", "issue": "number_tokens_changed"}],
        }), encoding="utf-8")
        paths["split.json"].write_text(json.dumps({
            "groups": [{"split": "train", "recordings": ["video-a"]}]
        }), encoding="utf-8")
        return paths

    def run_prepare(self, paths: dict[str, Path]) -> dict[str, object]:
        audit = json.loads(paths["audit.json"].read_text(encoding="utf-8"))
        eligible, _ = reviewed_targets(
            read_rows(paths["teacher.jsonl"]), read_rows(paths["review.jsonl"]),
            {str(row["id"]) for row in audit["warnings"]}, split_map(paths["split.json"]),
        )
        prediction_count = len(read_rows(paths["predictions.jsonl"]))
        paths["runtime-report.json"].write_text(json.dumps({
            "teacher_sha256": hashlib.sha256(paths["teacher.jsonl"].read_bytes()).hexdigest(),
            "luna_review_sha256": hashlib.sha256(paths["review.jsonl"].read_bytes()).hexdigest(),
            "luna_audit_sha256": hashlib.sha256(paths["audit.json"].read_bytes()).hexdigest(),
            "split_report_sha256": hashlib.sha256(paths["split.json"].read_bytes()).hexdigest(),
            "predictions_sha256": hashlib.sha256(paths["predictions.jsonl"].read_bytes()).hexdigest(),
            "prediction_count": prediction_count,
            "eligible_item_count": len(eligible),
            "labels_seen_by_asr": False,
        }), encoding="utf-8")
        return prepare(
            paths["teacher.jsonl"], paths["review.jsonl"], paths["audit.json"],
            paths["split.json"], paths["predictions.jsonl"], paths["runtime-report.json"],
            paths["dataset"], paths["output"],
        )

    def test_keeps_silver_provenance_and_excludes_ambiguous_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.fixture(Path(temporary))
            report = self.run_prepare(paths)
            self.assertEqual(report["example_count"], 2)
            self.assertEqual(report["excluded_by_reason"]["needs_audio_review"], 1)
            self.assertEqual(report["excluded_by_reason"]["luna_numeric_warning"], 1)
            examples = [json.loads(line) for line in (paths["output"] / "source.jsonl").read_text().splitlines()]
            self.assertEqual(examples[1]["target_text"], "A bright green light.")
            self.assertTrue(all(row["source"] == "ai-curated-experimental" and row["approved"] is False for row in examples))
            self.assertTrue(all(row["mode"] == "faithful" for row in examples))
            provenance = [json.loads(line) for line in (paths["output"] / "provenance.jsonl").read_text().splitlines()]
            self.assertTrue(all(row["humanReviewed"] is False and row["audio_verified"] is False for row in provenance))

    def test_quarantines_stale_text_review(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.fixture(Path(temporary))
            rows = [json.loads(line) for line in paths["review.jsonl"].read_text().splitlines()]
            rows[0]["edited_original"] = "Different text"
            write_jsonl(paths["review.jsonl"], rows)
            predictions = [json.loads(line) for line in paths["predictions.jsonl"].read_text().splitlines()]
            write_jsonl(paths["predictions.jsonl"], predictions[1:])
            report = self.run_prepare(paths)
            self.assertEqual(report["excluded_by_reason"]["stale_luna_review"], 1)

    def test_refuses_luna_audio_identity_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.fixture(Path(temporary))
            rows = [json.loads(line) for line in paths["review.jsonl"].read_text().splitlines()]
            rows[0]["audio_sha256"] = "0" * 64
            write_jsonl(paths["review.jsonl"], rows)
            with self.assertRaisesRegex(ValueError, "Luna audio identity mismatch"):
                self.run_prepare(paths)


if __name__ == "__main__":
    unittest.main()
