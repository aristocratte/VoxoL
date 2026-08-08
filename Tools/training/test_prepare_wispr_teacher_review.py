#!/usr/bin/env python3
"""Tests for the deterministic Wispr human-review queue."""

from __future__ import annotations

import tempfile
from pathlib import Path
import unittest

from Tools.training import prepare_wispr_teacher_review as review


class WisprTeacherReviewQueueTests(unittest.TestCase):
    def test_split_quotas_preserve_requested_count(self) -> None:
        self.assertEqual(
            review.split_quotas(200),
            {"train": 140, "validation": 30, "test": 30},
        )
        self.assertEqual(sum(review.split_quotas(6).values()), 6)

    def test_categories_flag_risky_teacher_labels(self) -> None:
        row = {
            "duration": 30,
            "edited": "",
            "edited_http_status": "500",
            "raw": "Thanks for watching!",
            "teacher_warning": True,
        }

        categories = review.review_categories(row)

        self.assertIn("teacher-warning", categories)
        self.assertIn("edited-missing", categories)
        self.assertIn("possible-boilerplate", categories)
        self.assertGreater(review.review_risk(row, categories), 10)

    def test_selection_is_balanced_deterministic_and_leakage_aware(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dataset_root = Path(temporary)
            rows = []
            split_map = {}
            split_counts = {"train": 8, "validation": 2, "test": 2}
            for language in review.LANGUAGES:
                number = 0
                for split, split_count in split_counts.items():
                    for offset in range(split_count):
                        number += 1
                        identifier = f"{language}-{split}-{offset}"
                        relative = Path("audio") / f"{identifier}.wav"
                        audio = dataset_root / relative
                        audio.parent.mkdir(parents=True, exist_ok=True)
                        audio.write_bytes(b"RIFF" + b"0" * 64)
                        rows.append(
                            {
                                "audio_path": str(relative),
                                "audio_sha256": identifier.ljust(64, "0")[:64],
                                "duration": 10.0,
                                "edited": f"Edited {identifier}.",
                                "edited_http_status": "200",
                                "id": identifier,
                                "raw": f"Raw {identifier}.",
                                "raw_http_status": "200",
                                "recording_id": f"{language}-source-{offset % 2}",
                                "requested_language": language,
                                "source_name": f"{language}.wav",
                                "speaker_id": f"{language}-speaker",
                                "start_seconds": float(number),
                                "teacher_warning": False,
                                "usable_for_asr": True,
                            }
                        )
                        split_map[identifier] = split

            first = review.select_review_items(
                rows,
                split_map,
                dataset_root,
                count=12,
                seed="test-seed",
            )
            second = review.select_review_items(
                rows,
                split_map,
                dataset_root,
                count=12,
                seed="test-seed",
            )

        self.assertEqual(first, second)
        self.assertEqual(
            review.queue_report(first)["byLanguage"],
            {"en": 6, "fr": 6},
        )
        self.assertEqual(
            review.queue_report(first)["bySplit"],
            {"test": 2, "train": 8, "validation": 2},
        )
        self.assertEqual(len({row["id"] for row in first}), 12)


if __name__ == "__main__":
    unittest.main()
