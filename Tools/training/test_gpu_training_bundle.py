#!/usr/bin/env python3
"""Regression tests for VoxoL's self-contained GPU training bundle."""

from __future__ import annotations

import base64
from contextlib import redirect_stdout
import gzip
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PIPELINE_PATH = Path(__file__).with_name("run_voxol_gpu_pipeline.py")
LAUNCHER_PATH = REPOSITORY_ROOT / "VoxoL_GPU_Train.sh"
MAC_LAUNCHER_PATH = REPOSITORY_ROOT / "Scripts" / "launch-voxol-runpod-training.sh"
BUILDER_PATH = REPOSITORY_ROOT / "Scripts" / "build-parakeet-gpu-runner.py"
SPEC = importlib.util.spec_from_file_location("run_voxol_gpu_pipeline", PIPELINE_PATH)
assert SPEC is not None and SPEC.loader is not None
PIPELINE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PIPELINE
SPEC.loader.exec_module(PIPELINE)
BUILDER_SPEC = importlib.util.spec_from_file_location(
    "build_parakeet_gpu_runner",
    BUILDER_PATH,
)
assert BUILDER_SPEC is not None and BUILDER_SPEC.loader is not None
BUILDER = importlib.util.module_from_spec(BUILDER_SPEC)
sys.modules[BUILDER_SPEC.name] = BUILDER
BUILDER_SPEC.loader.exec_module(BUILDER)


def report(
    wer: float,
    french_wer: float,
    english_wer: float,
    empty_outputs: int,
) -> dict[str, object]:
    return {
        "microWER": wer,
        "emptyOutputCount": empty_outputs,
        "byLanguage": {
            "french": {"microWER": french_wer},
            "english": {"microWER": english_wer},
        },
    }


class GPUTrainingPipelineTests(unittest.TestCase):
    def test_command_stream_preserves_carriage_return_progress(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "progress.log"
            output = io.StringIO()
            with redirect_stdout(output):
                PIPELINE.stream_command(
                    [
                        sys.executable,
                        "-c",
                        "import sys; sys.stdout.write('10%\\r20%\\n'); sys.stdout.flush()",
                    ],
                    log,
                )

            self.assertIn("10%\r20%", output.getvalue())
            self.assertIn(b"10%\r20%", log.read_bytes())

    def test_24_gib_gpu_uses_fast_bf16_profile(self) -> None:
        profile = PIPELINE.selected_profile(24, True)

        self.assertEqual(profile.name, "gpu-24g-fast")
        self.assertEqual(profile.precision, "bf16-mixed")
        self.assertEqual(profile.batch_size, 2)
        self.assertEqual(profile.train_top_encoder_layers, 8)

    def test_oom_fallback_reduces_trainable_work(self) -> None:
        normal = PIPELINE.selected_profile(24, True)
        fallback = PIPELINE.fallback_profile(normal)

        self.assertEqual(fallback.batch_size, 1)
        self.assertEqual(fallback.train_top_encoder_layers, 4)
        self.assertLess(fallback.max_duration, normal.max_duration)

    def test_completed_candidate_is_not_reused_for_a_different_recipe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate = root / "candidate.delta.pt"
            candidate.write_bytes(b"delta")
            completion = root / "training-complete.json"
            completion.write_text(
                json.dumps(
                    {
                        "pipelineVersion": PIPELINE.PIPELINE_VERSION,
                        "baseModel": PIPELINE.MODEL_ID,
                        "candidate": str(candidate),
                        "sha256": PIPELINE.sha256(candidate),
                        "epochs": 3,
                        "trainingIdentity": "teacher",
                        "learningRate": "3e-6",
                        "minimumLearningRate": "3e-7",
                        "warmupSteps": 8,
                        "maxSteps": 145,
                        "checkpointEveryNSteps": 18,
                        "seed": 1337,
                        "freezeDecoder": True,
                        "freezeJoint": True,
                        "freezeBatchNorm": True,
                        "deterministic": True,
                    }
                ),
                encoding="utf-8",
            )

            matching = PIPELINE.existing_candidate(
                completion,
                3,
                "teacher",
                "3e-6",
                "3e-7",
                8,
                145,
                18,
                1337,
                True,
                True,
                True,
                True,
            )
            changed = PIPELINE.existing_candidate(
                completion,
                3,
                "teacher",
                "3e-6",
                "3e-7",
                8,
                145,
                18,
                1337,
                True,
                False,
                True,
                True,
            )

        self.assertIsNotNone(matching)
        self.assertIsNone(changed)

    def test_resume_uses_latest_compatible_complete_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            training = root / "data"
            training.mkdir()
            datasets = {"training": training}
            profile = PIPELINE.GPUProfile(
                "wispr-silver-24g",
                "bf16-mixed",
                1,
                1,
                16,
                30.1,
                4,
                8,
            )
            experiment = root / "experiments" / "attempt"
            checkpoints = experiment / "checkpoints"
            checkpoints.mkdir(parents=True)
            configuration = {
                "train_manifest": str((training / "train.jsonl").resolve()),
                "validation_manifest": str(
                    (training / "validation.jsonl").resolve()
                ),
                "precision": "bf16-mixed",
                "batch_size": 1,
                "validation_batch_size": 1,
                "accumulate_grad_batches": 16,
                "max_duration": 30.1,
                "train_top_encoder_layers": 4,
                "train_decoder": False,
                "train_joint": False,
                "freeze_batchnorm": True,
                "max_epochs": 3,
                "max_steps": 145,
                "learning_rate": 3e-6,
                "minimum_learning_rate": 3e-7,
                "warmup_steps": 8,
                "checkpoint_every_n_steps": 18,
                "seed": 1337,
                "deterministic": True,
            }
            (experiment / "training-configuration.json").write_text(
                json.dumps(configuration),
                encoding="utf-8",
            )
            complete = checkpoints / "step-000108.ckpt"
            with zipfile.ZipFile(complete, "w") as archive:
                archive.writestr("archive/data.pkl", b"checkpoint")
            (checkpoints / "step-000126.ckpt").write_bytes(b"truncated")

            resume = PIPELINE.find_compatible_resume_checkpoint(
                root,
                datasets,
                profile,
                3,
                "3e-6",
                "3e-7",
                8,
                145,
                18,
                1337,
                True,
                True,
                True,
                True,
            )

        self.assertIsNotNone(resume)
        assert resume is not None
        self.assertEqual(resume[0].name, "step-000108.ckpt")
        self.assertEqual(resume[1].name, "attempt")

    def test_source_gate_only_passes_a_candidate_that_preserves_languages(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = {}
            values = {
                ("baseline", "fleurs"): report(0.10, 0.10, 0.10, 0),
                ("candidate", "fleurs"): report(0.102, 0.103, 0.101, 0),
                ("baseline", "mediaspeech"): report(0.40, 0.40, 0.0, 20),
                ("candidate", "mediaspeech"): report(0.35, 0.35, 0.0, 12),
            }
            for key, payload in values.items():
                path = root / f"{key[0]}-{key[1]}.json"
                path.write_text(json.dumps(payload), encoding="utf-8")
                paths[key] = path
            candidate = root / "candidate.delta.pt"
            candidate.write_bytes(b"delta")

            gate = PIPELINE.source_gate(
                candidate,
                "abc123",
                {
                    "fleurs": paths[("baseline", "fleurs")],
                    "mediaspeech": paths[("baseline", "mediaspeech")],
                },
                {
                    "fleurs": paths[("candidate", "fleurs")],
                    "mediaspeech": paths[("candidate", "mediaspeech")],
                },
            )

        self.assertTrue(gate["sourceGatePassed"])
        self.assertTrue(PIPELINE.quantization_plan(gate)["eligibleForMacQuantization"])

    def test_quantization_is_blocked_when_source_gate_fails(self) -> None:
        gate = {"sourceGatePassed": False, "candidateSHA256": "abc123"}

        plan = PIPELINE.quantization_plan(gate)

        self.assertFalse(plan["automaticQuantizationPerformed"])
        self.assertFalse(plan["eligibleForMacQuantization"])

    def test_result_archive_is_valid_and_contains_checksums(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = root / "results" / "source-gate.json"
            result.parent.mkdir(parents=True)
            result.write_text('{"sourceGatePassed": false}\n', encoding="utf-8")
            candidate = root / "candidates" / "candidate.delta.pt"
            candidate.parent.mkdir(parents=True)
            candidate.write_bytes(b"delta")
            recovery = root / "candidates" / "recovery" / "older.delta.pt"
            recovery.parent.mkdir(parents=True)
            recovery.write_bytes(b"older")

            archive_path = PIPELINE.build_archive(root, candidate, "test")

            with zipfile.ZipFile(archive_path) as archive:
                self.assertIsNone(archive.testzip())
                self.assertIn(
                    "VoxoL-Parakeet/results/source-gate.json",
                    archive.namelist(),
                )
                self.assertIn(
                    "VoxoL-Parakeet/SHA256SUMS.txt",
                    archive.namelist(),
                )
                self.assertEqual(
                    sum(
                        name.endswith("candidate.delta.pt")
                        for name in archive.namelist()
                    ),
                    1,
                )
                self.assertNotIn(
                    "VoxoL-Parakeet/candidates/recovery/older.delta.pt",
                    archive.namelist(),
                )


class GPUTrainingLauncherTests(unittest.TestCase):
    def test_embedded_sources_decode_and_match_their_digest(self) -> None:
        source = LAUNCHER_PATH.read_text(encoding="utf-8")
        digest_prefix = 'EMBEDDED_SOURCES_SHA256="'
        expected = source.split(digest_prefix, 1)[1].split('"', 1)[0]
        payload_prefix = "encoded_payload = '''"
        encoded = source.split(payload_prefix, 1)[1].split("'''", 1)[0]

        payload = base64.b64decode(
            "".join(encoded.split()).encode("ascii"),
            validate=True,
        )
        sources = json.loads(gzip.decompress(payload))

        self.assertEqual(hashlib.sha256(payload).hexdigest(), expected)
        self.assertIn("Tools/training/run_voxol_gpu_pipeline.py", sources)
        self.assertIn("Tools/training/run_voxol_wispr_gpu_pipeline.py", sources)
        self.assertIn("Scripts/prepare-librispeech-test-benchmark.py", sources)
        self.assertIn("Scripts/prepare-voxpopuli-fr-en-benchmark.py", sources)
        self.assertIn(
            "Tools/training/run_voxol_snapshot_diagnostic_pipeline.py",
            sources,
        )
        self.assertIn(
            "Tools/training/run_voxol_nemo_snapshot_diagnostics.py",
            sources,
        )
        # The bundle must carry exactly what the builder declares: a file added
        # to EMBEDDED_FILES without regenerating the launcher leaves the pod
        # running stale sources.
        self.assertEqual(sorted(sources), sorted(BUILDER.EMBEDDED_FILES))

    def test_launcher_has_valid_bash_syntax(self) -> None:
        completed = subprocess.run(
            ["bash", "-n", str(LAUNCHER_PATH)],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_runtime_is_persistent_on_runpod(self) -> None:
        source = LAUNCHER_PATH.read_text(encoding="utf-8")

        self.assertIn('RUNTIME_ROOT="/workspace/voxol-runtime-v7"', source)
        self.assertIn(
            'HF_HOME="${HF_HOME:-$RUNTIME_ROOT/cache/huggingface}"',
            source,
        )
        self.assertIn(
            'VOXOL_DATASET_CACHE_ROOT="${VOXOL_DATASET_CACHE_ROOT:-$RUNTIME_ROOT/cache/datasets}"',
            source,
        )
        self.assertIn('write_launcher_status "initializing"', source)

    def test_mac_launcher_has_v2_dataset_and_valid_bash_syntax(self) -> None:
        source = MAC_LAUNCHER_PATH.read_text(encoding="utf-8")
        completed = subprocess.run(
            ["bash", "-n", str(MAC_LAUNCHER_PATH)],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("voxol-wispr-asr-v2-20260801.tar.gz", source)
        self.assertIn("/workspace/voxol-wispr-replay-v5", source)
        self.assertIn("VOXOL_GPU_LAUNCHER", source)
        self.assertIn("Source gate passed", source)

    def test_launcher_pins_the_nemo_tdt_numba_runtime(self) -> None:
        source = LAUNCHER_PATH.read_text(encoding="utf-8")

        self.assertIn('NUMBA_VERSION="0.61.2"', source)
        self.assertIn('LLVMLITE_VERSION="0.44.0"', source)
        self.assertIn('"numba==$NUMBA_VERSION"', source)
        self.assertIn('"llvmlite==$LLVMLITE_VERSION"', source)
        self.assertIn(
            'NEMO_RUNTIME_MARKER="$NEMO_REVISION|$NUMBA_VERSION|$LLVMLITE_VERSION"',
            source,
        )

    def test_dry_run_shows_a_bounded_cost_without_touching_gpu(self) -> None:
        completed = subprocess.run(
            [
                "bash",
                str(LAUNCHER_PATH),
                "--dry-run",
                "--yes",
                "--hourly-price",
                "0.35",
                "--budget",
                "10",
                "--max-hours",
                "6",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("Coût compute maximal déclaré: $2.10", completed.stdout)
        self.assertIn("aucun entraînement", completed.stdout)

    def test_launcher_refuses_a_plan_over_budget(self) -> None:
        completed = subprocess.run(
            [
                "bash",
                str(LAUNCHER_PATH),
                "--dry-run",
                "--hourly-price",
                "2",
                "--budget",
                "10",
                "--max-hours",
                "6",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Refusing to start", completed.stderr)

    def test_teacher_dry_run_requires_a_complete_dataset_identity(self) -> None:
        completed = subprocess.run(
            [
                "bash",
                str(LAUNCHER_PATH),
                "--dry-run",
                "--teacher-dataset",
                "/workspace/teacher.tar.gz",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "doivent être fournis ensemble",
            completed.stderr,
        )

    def test_teacher_dry_run_selects_the_wispr_pipeline(self) -> None:
        completed = subprocess.run(
            [
                "bash",
                str(LAUNCHER_PATH),
                "--dry-run",
                "--teacher-dataset",
                "/workspace/teacher.tar.gz",
                "--teacher-dataset-sha256",
                "a" * 64,
                "--max-epochs",
                "3",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(
            "Mode: Wispr teacher + FLEURS replay",
            completed.stdout,
        )
        self.assertIn("Recette: une époque effective bornée", completed.stdout)
        self.assertIn("replay FLEURS cible 25 %", completed.stdout)

    def test_diagnostic_dry_run_is_explicitly_no_training(self) -> None:
        completed = subprocess.run(
            [
                "bash",
                str(LAUNCHER_PATH),
                "--dry-run",
                "--teacher-dataset",
                "/workspace/teacher.tar.gz",
                "--teacher-dataset-sha256",
                "a" * 64,
                "--research-archive",
                "/workspace/research.zip",
                "--research-archive-sha256",
                "b" * 64,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(
            "Mode: Diagnostic post-hoc sans entraînement",
            completed.stdout,
        )
        self.assertIn(
            "Analyses: parité A/A + validation exacte + grille de 18 compositions",
            completed.stdout,
        )

    def test_diagnostic_requires_the_teacher_dataset(self) -> None:
        completed = subprocess.run(
            [
                "bash",
                str(LAUNCHER_PATH),
                "--dry-run",
                "--research-archive",
                "/workspace/research.zip",
                "--research-archive-sha256",
                "b" * 64,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Le diagnostic exige aussi", completed.stderr)


if __name__ == "__main__":
    unittest.main()
