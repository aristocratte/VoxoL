#!/usr/bin/env python3
"""Tests for the localhost Wispr teacher review service."""

from __future__ import annotations

import tempfile
from pathlib import Path
import unittest

from Tools.training import serve_wispr_teacher_review as server


def item(identifier: str) -> dict[str, object]:
    return {
        "audioPath": f"/audio/{identifier}.wav",
        "audioSHA256": identifier.ljust(64, "0")[:64],
        "durationSeconds": 10,
        "editedTranscript": "Edited text.",
        "id": identifier,
        "language": "en",
        "rawTranscript": "Raw teacher text.",
        "recordingID": "recording",
        "speakerID": "speaker",
        "split": "train",
    }


class WisprTeacherReviewServerTests(unittest.TestCase):
    def test_accepted_review_uses_raw_teacher_text(self) -> None:
        review = server.validated_review(
            item("one"),
            {
                "notes": "  sounds correct  ",
                "status": "accepted",
                "transcript": "Ignored client text",
            },
            "2026-07-29T00:00:00Z",
        )

        self.assertEqual(review["transcript"], "Raw teacher text.")
        self.assertEqual(review["notes"], "sounds correct")

    def test_corrected_review_requires_nonempty_text(self) -> None:
        with self.assertRaisesRegex(ValueError, "cannot be empty"):
            server.validated_review(
                item("one"),
                {"status": "corrected", "transcript": "   "},
                "2026-07-29T00:00:00Z",
            )

    def test_export_contains_only_human_accepted_references(self) -> None:
        queue = {
            "items": [item("one"), item("two"), item("three")],
            "queueContentSHA256": "digest",
        }
        state = {
            "reviews": {
                "one": {
                    "notes": "",
                    "reviewedAt": "now",
                    "status": "accepted",
                    "transcript": "Raw teacher text.",
                },
                "two": {
                    "notes": "",
                    "reviewedAt": "now",
                    "status": "corrected",
                    "transcript": "Human correction.",
                },
                "three": {
                    "notes": "",
                    "reviewedAt": "now",
                    "status": "skipped",
                    "transcript": "",
                },
            },
            "updatedAt": "now",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            summary = server.export_reviews(queue, state, root)
            lines = (root / "reviewed.jsonl").read_text(
                encoding="utf-8"
            ).splitlines()

        self.assertEqual(summary["acceptedForTraining"], 2)
        self.assertEqual(summary["reviewCounts"]["skipped"], 1)
        self.assertEqual(len(lines), 2)

    def test_public_queue_does_not_expose_filesystem_paths(self) -> None:
        queue = {
            "items": [item("one")],
            "queueContentSHA256": "digest",
        }

        public = server.public_queue(queue)

        self.assertNotIn("audioPath", public["items"][0])


if __name__ == "__main__":
    unittest.main()
