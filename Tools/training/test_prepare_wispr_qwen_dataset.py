#!/usr/bin/env python3
"""Tests for the Wispr-to-Qwen dataset preparation."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare_wispr_qwen_dataset.py")
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("prepare_wispr_qwen_dataset", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
BUILDER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BUILDER
SPEC.loader.exec_module(BUILDER)


def write_manifest(path: Path) -> None:
    rows = []
    for language in ("en", "fr"):
        for source_index in range(4):
            recording = f"{language}-source-{source_index}"
            speaker = (
                f"{language}-shared"
                if source_index in (0, 1)
                else f"{language}-speaker-{source_index}"
            )
            for chunk in range(2):
                raw = f"well this is source {source_index} chunk {chunk} with enough words"
                edited = f"This is source {source_index}, chunk {chunk}, with enough words."
                if source_index == 3 and chunk == 1:
                    edited = "Truncated."
                rows.append(
                    {
                        "detected_language": language,
                        "duration": 10.0,
                        "edited": edited,
                        "id": f"{recording}-chunk-{chunk}",
                        "raw": raw,
                        "recording_id": recording,
                        "requested_language": language,
                        "speaker_id": speaker,
                    }
                )
    path.write_text(
        "".join(
            json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            for row in rows
        ),
        encoding="utf-8",
    )


class WisprQwenDatasetTests(unittest.TestCase):
    def test_filters_truncation_and_keeps_speakers_in_one_split(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "polisher.jsonl"
            write_manifest(manifest)

            report = BUILDER.prepare(
                manifest,
                root / "prepared",
                noop_fraction=1.0,
            )

            self.assertEqual(
                report["filter"]["excludedByReason"]["length_ratio_out_of_range"],
                2,
            )
            groups = report["groups"]
            shared = [
                group
                for group in groups
                if f"{group['language']}-shared" in group["speakers"]
            ]
            self.assertEqual(len(shared), 2)
            self.assertTrue(all(len(group["recordings"]) == 2 for group in shared))
            source = BUILDER.read_jsonl(root / "prepared" / "source.jsonl")
            references = BUILDER.read_jsonl(
                root / "prepared" / "evaluation-reference.jsonl"
            )
            self.assertEqual(
                [row["id"] for row in source],
                [row["id"] for row in references],
            )
            self.assertTrue(any(row["id"].endswith("-noop") for row in source))

    def test_output_is_deterministic_except_for_report_timestamp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "polisher.jsonl"
            write_manifest(manifest)

            BUILDER.prepare(manifest, root / "first")
            BUILDER.prepare(manifest, root / "second")

            for filename in (
                "source.jsonl",
                "evaluation-reference.jsonl",
                "excluded.jsonl",
            ):
                self.assertEqual(
                    (root / "first" / filename).read_bytes(),
                    (root / "second" / filename).read_bytes(),
                )

    def prepare_with_boundary_gap(
        self,
        root: Path,
        *,
        predict_excluded_row: bool,
    ) -> dict[str, object]:
        """Build a corpus whose first row fails the boundary filter.

        `predict_excluded_row` chooses whether the prediction file also covers
        that row. In production it does not: predictions are generated from the
        benchmark manifest, which the same boundary filter already emptied.
        """
        root.mkdir(parents=True, exist_ok=True)
        manifest = root / "polisher.jsonl"
        write_manifest(manifest)
        rows = BUILDER.read_jsonl(manifest)
        rows[0]["boundary_complete"] = False
        for row in rows[1:]:
            row["boundary_complete"] = True
        manifest.write_text(
            "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
            encoding="utf-8",
        )
        predicted = rows if predict_excluded_row else rows[1:]
        predictions = root / "predictions.jsonl"
        predictions.write_text(
            "".join(
                json.dumps(
                    {
                        "id": row["id"],
                        "rawText": str(row["raw"]).replace("well", "runtime", 1),
                    },
                    sort_keys=True,
                )
                + "\n"
                for row in predicted
            ),
            encoding="utf-8",
        )
        return BUILDER.prepare(
            manifest,
            root / "prepared",
            raw_predictions=predictions,
            require_complete_boundary=True,
        )

    def test_a_boundary_excluded_row_needs_no_runtime_prediction(self) -> None:
        # The benchmark manifest that produced the predictions was filtered by
        # the same rule, so the row is absent by design. Treating that as a
        # corrupt prediction file aborted the whole campaign.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = self.prepare_with_boundary_gap(root, predict_excluded_row=False)

        self.assertEqual(
            report["filter"]["excludedByReason"]["incomplete_or_legacy_boundary"],
            1,
        )

    def test_a_gap_outside_the_boundary_filter_still_fails_loudly(self) -> None:
        # An includable row without a prediction means the prediction file is
        # genuinely short, which must stay a hard error.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "polisher.jsonl"
            write_manifest(manifest)
            rows = BUILDER.read_jsonl(manifest)
            for row in rows:
                row["boundary_complete"] = True
            manifest.write_text(
                "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
                encoding="utf-8",
            )
            predictions = root / "predictions.jsonl"
            predictions.write_text(
                "".join(
                    json.dumps({"id": row["id"], "rawText": str(row["raw"])}, sort_keys=True)
                    + "\n"
                    for row in rows[1:]
                ),
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit) as raised:
                BUILDER.prepare(
                    manifest,
                    root / "prepared",
                    raw_predictions=predictions,
                    require_complete_boundary=True,
                )
        self.assertIn("Missing raw prediction", str(raised.exception))

    def test_boundary_gap_and_full_predictions_agree_on_the_kept_rows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            partial = self.prepare_with_boundary_gap(
                root / "partial", predict_excluded_row=False
            )
            full = self.prepare_with_boundary_gap(
                root / "full", predict_excluded_row=True
            )

        for key in ("includedTeacherPairCount", "excludedItemCount", "excludedByReason"):
            self.assertEqual(partial["filter"][key], full["filter"][key], key)

    def test_final_runtime_raw_overrides_wispr_and_requires_real_boundaries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "polisher.jsonl"
            write_manifest(manifest)
            rows = BUILDER.read_jsonl(manifest)
            rows[0]["boundary_complete"] = False
            for row in rows[1:]:
                row["boundary_complete"] = True
            manifest.write_text(
                "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
                encoding="utf-8",
            )
            predictions = root / "predictions.jsonl"
            predictions.write_text(
                "".join(
                    json.dumps(
                        {
                            "id": row["id"],
                            "rawText": str(row["raw"]).replace("well", "runtime", 1),
                        },
                        sort_keys=True,
                    )
                    + "\n"
                    for row in rows
                ),
                encoding="utf-8",
            )

            report = BUILDER.prepare(
                manifest,
                root / "prepared",
                raw_predictions=predictions,
                require_complete_boundary=True,
            )

            self.assertEqual(
                report["filter"]["excludedByReason"]["incomplete_or_legacy_boundary"],
                1,
            )
            source = BUILDER.read_jsonl(root / "prepared" / "source.jsonl")
            self.assertTrue(
                all(
                    row["raw_transcript"].startswith("runtime")
                    for row in source
                    if not str(row["id"]).endswith("-noop")
                )
            )
            self.assertEqual(report["labelContract"]["input"], "VoxoL final runtime raw")


if __name__ == "__main__":
    unittest.main()
