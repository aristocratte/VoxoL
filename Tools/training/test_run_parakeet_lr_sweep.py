#!/usr/bin/env python3
"""Tests for the Parakeet learning-rate sweep driver and its profile overrides."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Tools.training import run_parakeet_lr_sweep as SWEEP
from Tools.training import run_voxol_wispr_gpu_pipeline as PIPELINE


class LearningRateParsingTests(unittest.TestCase):
    def test_accepts_a_comma_separated_list(self) -> None:
        self.assertEqual(
            SWEEP.parse_learning_rates("3e-6, 1e-5 ,3e-5"),
            ["3e-6", "1e-5", "3e-5"],
        )

    def test_rejects_an_empty_list(self) -> None:
        with self.assertRaises(SystemExit):
            SWEEP.parse_learning_rates("  ,  ")

    def test_rejects_a_non_numeric_rate(self) -> None:
        with self.assertRaises(SystemExit):
            SWEEP.parse_learning_rates("3e-6,fast")

    def test_rejects_a_non_positive_rate(self) -> None:
        with self.assertRaises(SystemExit):
            SWEEP.parse_learning_rates("0")

    def test_labels_are_filesystem_safe_and_distinct(self) -> None:
        labels = {SWEEP.rate_label(rate) for rate in ("3e-6", "1e-5", "3e-5", "1.5e-5")}
        self.assertEqual(len(labels), 4)
        for label in labels:
            self.assertNotIn("-", label.removeprefix("lr-"))
            self.assertNotIn(".", label)


class DiscoveryTests(unittest.TestCase):
    def test_finds_the_single_prepared_training_root(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            work_root = Path(raw)
            prepared = work_root / "data" / "wispr-fleurs-replay-abc123456789"
            prepared.mkdir(parents=True)
            (prepared / "train.jsonl").write_text("{}\n", encoding="utf-8")
            self.assertEqual(SWEEP.discover_training_root(work_root), prepared)

    def test_ignores_a_directory_without_a_train_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            work_root = Path(raw)
            (work_root / "data" / "wispr-fleurs-replay-empty").mkdir(parents=True)
            with self.assertRaises(SystemExit):
                SWEEP.discover_training_root(work_root)

    def test_refuses_an_ambiguous_work_root(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            work_root = Path(raw)
            for suffix in ("aaaaaaaaaaaa", "bbbbbbbbbbbb"):
                prepared = work_root / "data" / f"wispr-fleurs-replay-{suffix}"
                prepared.mkdir(parents=True)
                (prepared / "train.jsonl").write_text("{}\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                SWEEP.discover_training_root(work_root)

    def test_finds_a_nested_teacher_dataset(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            work_root = Path(raw)
            teacher = work_root / "extracted" / "voxol-wispr-asr-v1"
            teacher.mkdir(parents=True)
            (teacher / "manifest-frozen.json").write_text("{}", encoding="utf-8")
            self.assertEqual(SWEEP.discover_teacher_root(work_root), teacher)


class MetricsTests(unittest.TestCase):
    def test_reads_overall_and_per_language_wer(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            report = Path(raw) / "report.json"
            report.write_text(
                json.dumps(
                    {
                        "microWER": 0.062347,
                        "byLanguage": {
                            "french": {"microWER": 0.078694},
                            "english": {"microWER": 0.043946},
                        },
                    }
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                SWEEP.report_metrics(report),
                {
                    "microWER": 0.062347,
                    "french": 0.078694,
                    "english": 0.043946,
                },
            )

    def test_tolerates_a_report_without_language_breakdown(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            report = Path(raw) / "report.json"
            report.write_text(json.dumps({"microWER": 0.05}), encoding="utf-8")
            self.assertEqual(SWEEP.report_metrics(report), {"microWER": 0.05})

    def test_relative_change_is_signed_and_guards_a_zero_baseline(self) -> None:
        self.assertAlmostEqual(SWEEP.relative_change(0.09, 0.10), -10.0)
        self.assertAlmostEqual(SWEEP.relative_change(0.11, 0.10), 10.0)
        self.assertIsNone(SWEEP.relative_change(0.1, 0.0))


class ProfileOverrideTests(unittest.TestCase):
    def test_the_24_gib_profile_keeps_an_effective_batch_of_16(self) -> None:
        profile = PIPELINE.teacher_profile(24.0, True)
        self.assertEqual(profile.batch_size * profile.accumulate_grad_batches, 16)

    def test_the_24_gib_profile_keeps_the_30_second_window(self) -> None:
        # 41.6% of campaign chunks run past 20 s; a shorter window drops them.
        profile = PIPELINE.teacher_profile(24.0, True)
        self.assertEqual(profile.max_duration, PIPELINE.MAX_TRAINING_DURATION_SECONDS)
        self.assertGreaterEqual(profile.max_duration, 30.0)

    def test_no_override_returns_the_profile_unchanged(self) -> None:
        profile = PIPELINE.teacher_profile(24.0, True)
        self.assertIs(PIPELINE.profile_with_overrides(profile, 0, 0), profile)

    def test_batch_only_override_rescales_accumulation(self) -> None:
        profile = PIPELINE.teacher_profile(24.0, True)
        overridden = PIPELINE.profile_with_overrides(profile, 4, 0)
        self.assertEqual(overridden.batch_size, 4)
        self.assertEqual(overridden.accumulate_grad_batches, 4)
        self.assertEqual(
            overridden.batch_size * overridden.accumulate_grad_batches,
            profile.batch_size * profile.accumulate_grad_batches,
        )

    def test_explicit_accumulation_is_taken_verbatim(self) -> None:
        profile = PIPELINE.teacher_profile(24.0, True)
        overridden = PIPELINE.profile_with_overrides(profile, 8, 1)
        self.assertEqual(overridden.batch_size, 8)
        self.assertEqual(overridden.accumulate_grad_batches, 1)

    def test_override_records_its_shape_in_the_profile_name(self) -> None:
        profile = PIPELINE.teacher_profile(24.0, True)
        self.assertEqual(
            PIPELINE.profile_with_overrides(profile, 4, 0).name,
            "wispr-silver-24g-b4x4",
        )

    def test_override_preserves_the_frozen_encoder_depth_and_window(self) -> None:
        profile = PIPELINE.teacher_profile(24.0, True)
        overridden = PIPELINE.profile_with_overrides(profile, 4, 0)
        self.assertEqual(
            overridden.train_top_encoder_layers,
            profile.train_top_encoder_layers,
        )
        self.assertEqual(overridden.max_duration, profile.max_duration)


class PipelineDefaultsTests(unittest.TestCase):
    def base_arguments(self) -> list[str]:
        return [
            "--source-root", "/tmp/source",
            "--work-root", "/tmp/work",
            "--teacher-dataset", "/tmp/teacher.tar",
            "--teacher-dataset-sha256", "0" * 64,
            "--hourly-price", "0.4",
            "--budget", "15",
            "--max-hours", "8",
        ]

    def test_defaults_match_the_promoted_recipe(self) -> None:
        arguments = PIPELINE.parser().parse_args(self.base_arguments())
        self.assertEqual(arguments.learning_rate, "3e-6")
        self.assertEqual(arguments.minimum_learning_rate, "3e-7")
        self.assertEqual(arguments.warmup_steps, 8)
        self.assertFalse(arguments.no_deterministic)

    def test_sentinel_zero_defers_to_the_profile_and_the_data(self) -> None:
        arguments = PIPELINE.parser().parse_args(self.base_arguments())
        self.assertEqual(arguments.batch_size, 0)
        self.assertEqual(arguments.accumulate_grad_batches, 0)
        self.assertEqual(arguments.max_steps, 0)

    def test_probe_overrides_are_accepted(self) -> None:
        arguments = PIPELINE.parser().parse_args(
            [
                *self.base_arguments(),
                "--learning-rate", "1e-5",
                "--batch-size", "4",
                "--max-steps", "200",
                "--no-deterministic",
            ]
        )
        self.assertEqual(arguments.learning_rate, "1e-5")
        self.assertEqual(arguments.batch_size, 4)
        self.assertEqual(arguments.max_steps, 200)
        self.assertTrue(arguments.no_deterministic)


if __name__ == "__main__":
    unittest.main()
