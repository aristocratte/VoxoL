#!/usr/bin/env python3
"""Tests for the Wispr-silver Parakeet GPU pipeline."""

from __future__ import annotations

import json
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("run_voxol_wispr_gpu_pipeline.py")
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT))
SPEC = importlib.util.spec_from_file_location(
    "run_voxol_wispr_gpu_pipeline",
    SCRIPT,
)
assert SPEC is not None and SPEC.loader is not None
PIPELINE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PIPELINE
SPEC.loader.exec_module(PIPELINE)


def report(
    wer: float,
    french: float,
    english: float,
    empty: int = 0,
) -> dict[str, object]:
    reference_words = 10_000
    errors = round(wer * reference_words)
    return {
        "microWER": wer,
        "emptyOutputCount": empty,
        "wordErrors": {
            "deletions": 0,
            "insertions": 0,
            "substitutions": errors,
            "referenceWords": reference_words,
        },
        "byLanguage": {
            "french": {"microWER": french},
            "english": {"microWER": english},
        },
    }


class WisprGPUPipelineTests(unittest.TestCase):
    @staticmethod
    def write_manifest(
        path: Path,
        rows: list[dict[str, object]],
    ) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "".join(
                json.dumps(row, sort_keys=True) + "\n"
                for row in rows
            ),
            encoding="utf-8",
        )

    def test_teacher_benchmark_uses_dataset_root_for_audio_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            teacher = root / "teacher"
            teacher.mkdir()
            (teacher / "manifest-frozen.json").write_text(
                json.dumps({"items": [{"id": "one"}]}),
                encoding="utf-8",
            )

            with mock.patch.object(PIPELINE.base, "run_source_script") as run:
                PIPELINE.base.evaluate(
                    root,
                    {"teacher": teacher},
                    root / "results",
                    root / "logs",
                    "baseline",
                    ["--pretrained-name", PIPELINE.base.MODEL_ID],
                    8,
                    (("wispr-teacher-heldout", "teacher"),),
                    audio_roots={"teacher": teacher},
                )

            benchmark_arguments = run.call_args_list[0].args[2]
            audio_root_index = benchmark_arguments.index("--audio-root") + 1
            self.assertEqual(benchmark_arguments[audio_root_index], teacher)

    def test_24_gib_profile_keeps_30_second_training_items(self) -> None:
        profile = PIPELINE.teacher_profile(24, True)

        self.assertEqual(profile.max_duration, 30.1)
        self.assertEqual(profile.train_top_encoder_layers, 4)
        self.assertEqual(profile.precision, "bf16-mixed")

    def test_24_gib_profile_keeps_one_clip_per_micro_batch(self) -> None:
        profile = PIPELINE.teacher_profile(24, True)

        # Measured, not assumed: two clips OOMed on a real 24 GiB RTX 4090,
        # dying in the RNN-T loss trying to allocate 6.01 GiB. The loss gradient
        # tensor scales with the micro-batch and dwarfs the encoder activations
        # that freezing saves.
        self.assertEqual(profile.batch_size, 1)
        self.assertEqual(profile.accumulate_grad_batches, 16)
        self.assertEqual(profile.batch_size * profile.accumulate_grad_batches, 16)

    def test_oom_fallback_returns_to_one_clip_per_micro_batch(self) -> None:
        fallback = PIPELINE.teacher_fallback(PIPELINE.teacher_profile(24, True))

        self.assertEqual(fallback.batch_size, 1)
        self.assertEqual(fallback.batch_size * fallback.accumulate_grad_batches, 16)
        self.assertEqual(fallback.max_duration, 30.1)

    def test_replay_manifest_is_balanced_and_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            teacher = root / "teacher"
            fleurs = root / "fleurs"
            for split in ("train", "validation"):
                teacher_audio = teacher / "audio"
                fleurs_audio = fleurs / "audio"
                for language in ("en", "fr"):
                    for index in range(6):
                        teacher_path = (
                            teacher_audio / f"{split}-{language}-{index}.wav"
                        )
                        teacher_path.parent.mkdir(parents=True, exist_ok=True)
                        teacher_path.write_bytes(b"RIFF" + b"\0" * 96)
                        fleurs_path = (
                            fleurs_audio
                            / ("en_us" if language == "en" else "fr_fr")
                            / f"{split}-{index}.wav"
                        )
                        fleurs_path.parent.mkdir(parents=True, exist_ok=True)
                        fleurs_path.write_bytes(b"RIFF" + b"\0" * 96)
                teacher_rows = [
                    {
                        "audio_filepath": str(
                            teacher_audio / f"{split}-{language}-{index}.wav"
                        ),
                        "duration": 20,
                        "language": language,
                        "text": f"teacher {language} {index}",
                    }
                    for language in ("en", "fr")
                    for index in range(2)
                ]
                fleurs_rows = [
                    {
                        "audio_filepath": str(
                            fleurs_audio
                            / ("en_us" if language == "en" else "fr_fr")
                            / f"{split}-{index}.wav"
                        ),
                        "duration": 10,
                        "text": f"replay {language} {index}",
                    }
                    for language in ("en", "fr")
                    for index in range(6)
                ]
                long_audio = (
                    fleurs_audio
                    / "en_us"
                    / f"{split}-long.wav"
                )
                long_audio.write_bytes(b"RIFF" + b"\0" * 96)
                fleurs_rows.append(
                    {
                        "audio_filepath": str(long_audio),
                        "duration": 33.3,
                        "text": "This row must be excluded by the training duration limit.",
                    }
                )
                self.write_manifest(teacher / f"{split}.jsonl", teacher_rows)
                self.write_manifest(fleurs / f"{split}.jsonl", fleurs_rows)

            first = root / "first"
            second = root / "second"
            report = PIPELINE.mixed_replay_manifests(teacher, fleurs, first)
            PIPELINE.mixed_replay_manifests(teacher, fleurs, second)

            self.assertEqual(
                (first / "train.jsonl").read_text(encoding="utf-8"),
                (second / "train.jsonl").read_text(encoding="utf-8"),
            )
            train_rows = [
                json.loads(line)
                for line in (first / "train.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()
            ]
            self.assertEqual(len(train_rows), 6)
            self.assertTrue(
                all(
                    float(row["duration"])
                    <= PIPELINE.MAX_TRAINING_DURATION_SECONDS
                    for row in train_rows
                )
            )
            self.assertEqual(
                report["splits"]["train"]["teacherByLanguage"],
                {"en": 2, "fr": 2},
            )
            self.assertEqual(
                report["splits"]["train"]["replayByLanguage"],
                {"en": 1, "fr": 1},
            )
            self.assertAlmostEqual(
                report["splits"]["train"]["actualReplayFractionByItems"],
                1 / 3,
            )

    def test_training_budget_is_one_effective_epoch_with_safety_bounds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "train.jsonl"
            manifest.write_text("{}\n" * 20_000, encoding="utf-8")
            profile = PIPELINE.teacher_profile(24, True)
            self.assertEqual(PIPELINE.training_step_budget(manifest, profile), 1_250)

            manifest.write_text("{}\n" * 100, encoding="utf-8")
            self.assertEqual(
                PIPELINE.training_step_budget(manifest, profile),
                PIPELINE.MINIMUM_TRAINING_STEPS,
            )

    def test_oom_fallback_preserves_the_four_encoder_layer_recipe(self) -> None:
        fallback = PIPELINE.teacher_fallback(
            PIPELINE.teacher_profile(24, True)
        )

        self.assertEqual(fallback.train_top_encoder_layers, 4)
        self.assertEqual(fallback.max_duration, 30.1)

    def test_teacher_gate_requires_gain_without_public_regression(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline_values = {
                "teacher": report(0.20, 0.20, 0.20),
                "mixed_validation": report(0.15, 0.15, 0.15),
                "fleurs": report(0.08, 0.08, 0.08),
                "mediaspeech": report(0.27, 0.27, 0.0, 3),
                "librispeech": report(0.04, 0.0, 0.04),
                "voxpopuli": report(0.10, 0.10, 0.10),
            }
            candidate_values = {
                "teacher": report(0.18, 0.19, 0.17),
                "mixed_validation": report(0.12, 0.12, 0.12),
                "fleurs": report(0.083, 0.083, 0.083),
                "mediaspeech": report(0.274, 0.274, 0.0, 3),
                "librispeech": report(0.044, 0.0, 0.044),
                "voxpopuli": report(0.104, 0.104, 0.104),
            }
            paths: dict[tuple[str, str], Path] = {}
            for label, values in (
                ("baseline", baseline_values),
                ("candidate", candidate_values),
            ):
                for benchmark, payload in values.items():
                    path = root / f"{label}-{benchmark}.json"
                    path.write_text(json.dumps(payload), encoding="utf-8")
                    paths[(label, benchmark)] = path
            candidate = root / "candidate.delta.pt"
            candidate.write_bytes(b"delta")

            gate = PIPELINE.teacher_source_gate(
                candidate,
                "abc",
                {
                    key: paths[("baseline", key)]
                    for key in baseline_values
                },
                {
                    key: paths[("candidate", key)]
                    for key in candidate_values
                },
                {
                    "validationWERSelection": 0.12,
                    "validationWERSelectionMetric": "voxol-asr-v1-micro-wer",
                    "validationReferenceWords": 10_000,
                    "validationWordErrors": 1_200,
                },
            )

            self.assertTrue(gate["sourceGatePassed"])

    def test_teacher_gate_rejects_english_and_librispeech_regression(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before = {
                "teacher": report(0.20, 0.20, 0.20),
                "mixed_validation": report(0.15, 0.15, 0.15),
                "fleurs": report(0.08, 0.08, 0.08),
                "mediaspeech": report(0.27, 0.27, 0.0),
                "librispeech": report(0.04, 0.0, 0.04),
                "voxpopuli": report(0.10, 0.10, 0.10),
            }
            after = {
                "teacher": report(0.18, 0.14, 0.22),
                "mixed_validation": report(0.12, 0.12, 0.12),
                "fleurs": report(0.08, 0.08, 0.08),
                "mediaspeech": report(0.27, 0.27, 0.0),
                "librispeech": report(0.046, 0.0, 0.046),
                "voxpopuli": report(0.10, 0.10, 0.10),
            }
            baseline_paths = {}
            candidate_paths = {}
            for key in before:
                baseline_paths[key] = root / f"baseline-{key}.json"
                candidate_paths[key] = root / f"candidate-{key}.json"
                baseline_paths[key].write_text(
                    json.dumps(before[key]), encoding="utf-8"
                )
                candidate_paths[key].write_text(
                    json.dumps(after[key]), encoding="utf-8"
                )
            candidate = root / "candidate.delta.pt"
            candidate.write_bytes(b"delta")

            gate = PIPELINE.teacher_source_gate(
                candidate,
                "abc",
                baseline_paths,
                candidate_paths,
                {
                    "validationWERSelection": 0.12,
                    "validationWERSelectionMetric": "voxol-asr-v1-micro-wer",
                    "validationReferenceWords": 10_000,
                    "validationWordErrors": 1_200,
                },
            )

            self.assertFalse(gate["sourceGatePassed"])
            self.assertFalse(
                gate["checks"]["teacherEnglishImprovesAtLeast2PercentRelative"]
            )
            self.assertFalse(
                gate["checks"]["libriSpeechRegressionAtMost0.5Point"]
            )

    def test_teacher_gate_rejects_checkpoint_metric_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            values = {
                "teacher": report(0.18, 0.18, 0.18),
                "mixed_validation": report(0.12, 0.12, 0.12),
                "fleurs": report(0.08, 0.08, 0.08),
                "mediaspeech": report(0.27, 0.27, 0.0),
                "librispeech": report(0.04, 0.0, 0.04),
                "voxpopuli": report(0.10, 0.10, 0.10),
            }
            baseline_paths = {}
            candidate_paths = {}
            for key, payload in values.items():
                baseline_paths[key] = root / f"baseline-{key}.json"
                candidate_paths[key] = root / f"candidate-{key}.json"
                baseline_paths[key].write_text(
                    json.dumps(
                        report(0.20, 0.20, 0.20)
                        if key == "teacher"
                        else payload
                    ),
                    encoding="utf-8",
                )
                candidate_paths[key].write_text(
                    json.dumps(payload),
                    encoding="utf-8",
                )

            gate = PIPELINE.teacher_source_gate(
                root / "candidate.delta.pt",
                "abc",
                baseline_paths,
                candidate_paths,
                {
                    "validationWERSelection": 0.13,
                    "validationWERSelectionMetric": "voxol-asr-v1-micro-wer",
                    "validationReferenceWords": 10_000,
                    "validationWordErrors": 1_300,
                },
            )

        self.assertFalse(gate["sourceGatePassed"])
        self.assertFalse(
            gate["checks"]["checkpointSelectionMetricIsGlobalVoxoLWER"]
        )

    def test_teacher_gate_accepts_one_word_of_gpu_decode_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline_paths = {}
            candidate_paths = {}
            for key in (
                "teacher",
                "mixed_validation",
                "fleurs",
                "mediaspeech",
                "librispeech",
                "voxpopuli",
            ):
                baseline_payload = report(
                    0.20 if key == "teacher" else 0.12,
                    0.20 if key == "teacher" else 0.12,
                    0.20 if key == "teacher" else 0.12,
                )
                candidate_payload = report(
                    0.18 if key == "teacher" else 0.12,
                    0.18 if key == "teacher" else 0.12,
                    0.18 if key == "teacher" else 0.12,
                )
                baseline_paths[key] = root / f"baseline-{key}.json"
                candidate_paths[key] = root / f"candidate-{key}.json"
                baseline_paths[key].write_text(
                    json.dumps(baseline_payload), encoding="utf-8"
                )
                candidate_paths[key].write_text(
                    json.dumps(candidate_payload), encoding="utf-8"
                )

            gate = PIPELINE.teacher_source_gate(
                root / "candidate.delta.pt",
                "abc",
                baseline_paths,
                candidate_paths,
                {
                    "validationWERSelection": 0.1201,
                    "validationWERSelectionMetric": "voxol-asr-v1-micro-wer",
                    "validationReferenceWords": 10_000,
                    "validationWordErrors": 1_201,
                },
            )

        self.assertTrue(
            gate["checks"]["checkpointSelectionMetricIsGlobalVoxoLWER"]
        )
        self.assertEqual(gate["checkpointValidation"]["wordErrorDelta"], 1)

    def gate_with_validation(
        self,
        root: Path,
        reference_words: int,
        external_errors: int,
        stored_errors: int,
        metric: str = "voxol-asr-v1-micro-wer",
    ) -> dict[str, object]:
        """Build a passing gate whose only variable is the validation bookkeeping."""
        baseline_paths = {}
        candidate_paths = {}
        for key in (
            "teacher",
            "mixed_validation",
            "fleurs",
            "mediaspeech",
            "librispeech",
            "voxpopuli",
        ):
            baseline_payload = report(0.20 if key == "teacher" else 0.12, 0.20, 0.20)
            candidate_payload = report(0.18 if key == "teacher" else 0.12, 0.18, 0.18)
            if key == "mixed_validation":
                candidate_payload["wordErrors"] = {
                    "deletions": 0,
                    "insertions": 0,
                    "substitutions": external_errors,
                    "referenceWords": reference_words,
                }
                candidate_payload["microWER"] = external_errors / reference_words
            baseline_paths[key] = root / f"baseline-{key}.json"
            candidate_paths[key] = root / f"candidate-{key}.json"
            baseline_paths[key].write_text(
                json.dumps(baseline_payload), encoding="utf-8"
            )
            candidate_paths[key].write_text(
                json.dumps(candidate_payload), encoding="utf-8"
            )
        return PIPELINE.teacher_source_gate(
            root / "candidate.delta.pt",
            "abc",
            baseline_paths,
            candidate_paths,
            {
                "validationWERSelection": stored_errors / reference_words,
                "validationWERSelectionMetric": metric,
                "validationReferenceWords": reference_words,
                "validationWordErrors": stored_errors,
            },
        )

    def test_teacher_gate_accepts_the_measured_decode_drift_of_a_real_run(
        self,
    ) -> None:
        # The 2026-08-03 mass run: 156,356 words, 12,737 errors from the
        # in-training validation loop against 12,748 from the benchmark harness.
        # The two paths use different batch sizes and CUDA-graph decoding, so
        # they are never bit-identical; an exact-match rule made the check
        # unsatisfiable and failed an otherwise passing candidate.
        with tempfile.TemporaryDirectory() as directory:
            gate = self.gate_with_validation(Path(directory), 156_356, 12_748, 12_737)

        self.assertTrue(gate["checks"]["checkpointSelectionMetricIsGlobalVoxoLWER"])
        self.assertEqual(gate["checkpointValidation"]["wordErrorDelta"], 11)
        self.assertEqual(gate["checkpointValidation"]["failedConditions"], [])

    def test_teacher_gate_still_rejects_a_divergence_beyond_decode_drift(
        self,
    ) -> None:
        # A checkpoint selected on NeMo's raw WER instead of the VoxoL metric
        # diverges by orders of magnitude, not by a handful of words.
        with tempfile.TemporaryDirectory() as directory:
            gate = self.gate_with_validation(Path(directory), 156_356, 24_400, 12_737)

        self.assertFalse(gate["checks"]["checkpointSelectionMetricIsGlobalVoxoLWER"])
        self.assertEqual(
            gate["checkpointValidation"]["failedConditions"],
            ["wordErrorDeltaWithinTolerance"],
        )

    def test_teacher_gate_tolerance_scales_with_the_validation_corpus(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            large = self.gate_with_validation(root, 156_356, 12_737, 12_737)
            small = self.gate_with_validation(root, 1_000, 120, 120)

        self.assertEqual(
            large["checkpointValidation"]["maximumAcceptedWordErrorDelta"], 64
        )
        # Never below one word, so a tiny corpus keeps a usable tolerance.
        self.assertEqual(
            small["checkpointValidation"]["maximumAcceptedWordErrorDelta"], 1
        )

    def test_teacher_gate_names_a_wrong_selection_metric(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            gate = self.gate_with_validation(
                Path(directory),
                156_356,
                12_737,
                12_737,
                metric="nemo-raw-wer",
            )

        self.assertFalse(gate["checks"]["checkpointSelectionMetricIsGlobalVoxoLWER"])
        self.assertEqual(
            gate["checkpointValidation"]["failedConditions"],
            ["metricIsVoxoLMicroWER"],
        )


if __name__ == "__main__":
    unittest.main()
