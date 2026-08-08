#!/usr/bin/env python3
"""Run VoxoL's resumable Parakeet training and source-quality gate."""

from __future__ import annotations

import argparse
import codecs
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import time
import traceback
import zipfile


MODEL_ID = "nvidia/parakeet-tdt-0.6b-v3"
FREEZE_TIMESTAMP = "2026-07-26T00:00:00Z"
PIPELINE_VERSION = "2026-07-29-gpu-pipeline-v2"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def atomic_copy(source: Path, destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".partial")
    with source.open("rb") as source_stream, temporary.open("wb") as output:
        shutil.copyfileobj(source_stream, output, length=8 * 1024 * 1024)
    if temporary.stat().st_size != source.stat().st_size:
        raise RuntimeError(f"Incomplete copy: {destination}")
    temporary.replace(destination)
    return destination


@dataclass(frozen=True)
class GPUProfile:
    name: str
    precision: str
    batch_size: int
    validation_batch_size: int
    accumulate_grad_batches: int
    max_duration: float
    train_top_encoder_layers: int
    evaluation_batch_size: int


def selected_profile(memory_gib: float, bf16_supported: bool) -> GPUProfile:
    if memory_gib < 14:
        raise RuntimeError(
            f"The GPU has {memory_gib:.1f} GiB of VRAM; at least 14 GiB is required."
        )
    if memory_gib < 20:
        return GPUProfile("gpu-14g-safe", "16-mixed", 1, 1, 16, 12, 6, 4)
    precision = "bf16-mixed" if bf16_supported else "16-mixed"
    if memory_gib < 38:
        return GPUProfile("gpu-24g-fast", precision, 2, 2, 8, 18, 8, 8)
    return GPUProfile("gpu-40g-fast", precision, 4, 4, 4, 30, 8, 16)


def fallback_profile(profile: GPUProfile) -> GPUProfile:
    return GPUProfile(
        name=f"{profile.name}-oom-fallback",
        precision=profile.precision,
        batch_size=1,
        validation_batch_size=1,
        accumulate_grad_batches=16,
        max_duration=min(10, profile.max_duration),
        train_top_encoder_layers=min(4, profile.train_top_encoder_layers),
        evaluation_batch_size=min(4, profile.evaluation_batch_size),
    )


class CommandFailure(RuntimeError):
    def __init__(self, command: list[str], return_code: int, log_path: Path, tail: str):
        super().__init__(
            f"Command failed with exit code {return_code}: {' '.join(command)}\n"
            f"Last output:\n{tail or 'No output.'}\nFull log: {log_path}"
        )
        self.command = command
        self.return_code = return_code
        self.log_path = log_path
        self.tail = tail

    @property
    def is_resource_failure(self) -> bool:
        text = self.tail.lower()
        return self.return_code in (-9, 137) or any(
            marker in text
            for marker in (
                "out of memory",
                "cuda error: out of memory",
                "cudnn_status_alloc_failed",
                "killed",
            )
        )


class Progress:
    def __init__(
        self,
        status_path: Path,
        hourly_price: float,
        max_hours: float,
        started_epoch: float,
        pipeline_version: str = PIPELINE_VERSION,
    ) -> None:
        self.status_path = status_path
        self.hourly_price = hourly_price
        self.max_hours = max_hours
        self.started_epoch = started_epoch
        self.pipeline_version = pipeline_version
        self.completed: list[str] = []
        self.current = "starting"
        self.state = "running"
        self.error: str | None = None
        self.write()

    def payload(self) -> dict[str, object]:
        elapsed_hours = max(0.0, time.time() - self.started_epoch) / 3600
        return {
            "schemaVersion": 1,
            "pipelineVersion": self.pipeline_version,
            "state": self.state,
            "currentStage": self.current,
            "completedStages": self.completed,
            "startedAtEpoch": self.started_epoch,
            "updatedAt": utc_now(),
            "elapsedHours": round(elapsed_hours, 4),
            "estimatedComputeCostUSD": round(elapsed_hours * self.hourly_price, 4),
            "maximumHours": self.max_hours,
            "maximumComputeCostUSD": round(self.max_hours * self.hourly_price, 2),
            "error": self.error,
        }

    def write(self) -> None:
        atomic_json(self.status_path, self.payload())

    def begin(self, number: int, total: int, stage: str) -> None:
        self.current = stage
        self.write()
        print(f"\n{'=' * 72}\n[{number}/{total}] {stage}\n{'=' * 72}", flush=True)

    def finish_stage(self, stage: str) -> None:
        if stage not in self.completed:
            self.completed.append(stage)
        self.write()

    def fail(self, error: BaseException) -> None:
        self.state = "failed"
        self.error = str(error)
        self.write()

    def succeed(self) -> None:
        self.state = "complete"
        self.current = "complete"
        self.error = None
        self.write()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--source-root", type=Path, required=True)
    result.add_argument("--work-root", type=Path, required=True)
    result.add_argument("--hourly-price", type=float, required=True)
    result.add_argument("--budget", type=float, required=True)
    result.add_argument("--max-hours", type=float, required=True)
    result.add_argument("--max-epochs", type=int, default=5)
    return result


def stream_command(
    command: list[object],
    log_path: Path,
    environment: dict[str, str] | None = None,
) -> None:
    rendered = [str(value) for value in command]
    print("+", " ".join(rendered), flush=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    tail = ""
    with log_path.open("a", encoding="utf-8") as log:
        log.write(f"\n[{utc_now()}] + {' '.join(rendered)}\n")
        log.flush()
        process = subprocess.Popen(
            rendered,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
            env=environment,
        )
        assert process.stdout is not None
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        try:
            while chunk := os.read(process.stdout.fileno(), 4096):
                text = decoder.decode(chunk)
                print(text, end="", flush=True)
                log.write(text)
                log.flush()
                tail = (tail + text)[-50_000:]
            remainder = decoder.decode(b"", final=True)
            if remainder:
                print(remainder, end="", flush=True)
                log.write(remainder)
                log.flush()
                tail = (tail + remainder)[-50_000:]
        except BaseException:
            process.terminate()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            process.stdout.close()
            raise
        process.stdout.close()
        return_code = process.wait()
    if return_code != 0:
        raise CommandFailure(rendered, return_code, log_path, tail.strip())


def run_source_script(
    source_root: Path,
    relative_path: str,
    arguments: list[object],
    log_path: Path,
) -> None:
    stream_command(
        [sys.executable, source_root / relative_path, *arguments],
        log_path,
    )


def ensure_budget(arguments: argparse.Namespace) -> None:
    for name in ("hourly_price", "budget", "max_hours"):
        if getattr(arguments, name) <= 0:
            raise SystemExit(f"--{name.replace('_', '-')} must be positive.")
    if arguments.max_epochs <= 0:
        raise SystemExit("--max-epochs must be positive.")
    projected = arguments.hourly_price * arguments.max_hours
    if projected > arguments.budget + 1e-9:
        raise SystemExit(
            f"Refusing to start: ${projected:.2f} maximum compute cost exceeds "
            f"the ${arguments.budget:.2f} budget."
        )


def prepare_datasets(
    source_root: Path,
    work_root: Path,
    log_root: Path,
) -> dict[str, Path]:
    dataset_cache = work_root / "cache" / "datasets"
    training_data = work_root / "data" / "parakeet-fleurs-fr-en"
    fleurs_test = work_root / "benchmarks" / "fleurs-test"
    mediaspeech_test = work_root / "benchmarks" / "mediaspeech-fr"
    commands = (
        (
            "Scripts/prepare-parakeet-fleurs-finetune.py",
            [
                "--cache-root",
                dataset_cache / "fleurs-training",
                "--output-root",
                training_data,
            ],
        ),
        (
            "Scripts/prepare-fleurs-test-benchmark.py",
            [
                "--cache-root",
                dataset_cache / "fleurs-test",
                "--output-root",
                fleurs_test,
            ],
        ),
        (
            "Scripts/prepare-mediaspeech-fr-benchmark.py",
            [
                "--cache-root",
                dataset_cache / "mediaspeech",
                "--output-root",
                mediaspeech_test,
            ],
        ),
    )
    for index, (relative_path, script_arguments) in enumerate(commands, 1):
        run_source_script(
            source_root,
            relative_path,
            script_arguments,
            log_root / f"dataset-{index}.log",
        )
    for benchmark_root in (fleurs_test, mediaspeech_test):
        run_source_script(
            source_root,
            "Tools/training/freeze_asr_manifest.py",
            [
                "--input",
                benchmark_root / "manifest-unfrozen.json",
                "--output",
                benchmark_root / "manifest-frozen.json",
                "--timestamp",
                FREEZE_TIMESTAMP,
            ],
            log_root / "freeze-manifests.log",
        )
    required = (
        training_data / "train.jsonl",
        training_data / "validation.jsonl",
        fleurs_test / "manifest-frozen.json",
        mediaspeech_test / "manifest-frozen.json",
    )
    for path in required:
        if not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"Dataset preparation did not produce {path}.")
    return {
        "training": training_data,
        "fleurs": fleurs_test,
        "mediaspeech": mediaspeech_test,
    }


def existing_candidate(
    completion_path: Path,
    max_epochs: int,
    training_identity: str,
    learning_rate: str,
    minimum_learning_rate: str,
    warmup_steps: int,
    max_steps: int = 0,
    checkpoint_every_n_steps: int = 0,
    seed: int = 42,
    freeze_decoder: bool = False,
    freeze_joint: bool = False,
    freeze_batchnorm: bool = False,
    deterministic: bool = False,
) -> tuple[Path, dict[str, object]] | None:
    if not completion_path.is_file():
        return None
    completion = json.loads(completion_path.read_text(encoding="utf-8"))
    candidate = Path(str(completion.get("candidate", "")))
    expected_digest = str(completion.get("sha256", ""))
    if (
        completion.get("pipelineVersion") == PIPELINE_VERSION
        and completion.get("baseModel") == MODEL_ID
        and completion.get("epochs") == max_epochs
        and completion.get("trainingIdentity") == training_identity
        and completion.get("learningRate") == learning_rate
        and completion.get("minimumLearningRate") == minimum_learning_rate
        and completion.get("warmupSteps") == warmup_steps
        and completion.get("maxSteps", 0) == max_steps
        and completion.get("checkpointEveryNSteps", 0)
        == checkpoint_every_n_steps
        and completion.get("seed", 42) == seed
        and completion.get("freezeDecoder", False) is freeze_decoder
        and completion.get("freezeJoint", False) is freeze_joint
        and completion.get("freezeBatchNorm", False) is freeze_batchnorm
        and completion.get("deterministic", False) is deterministic
        and candidate.is_file()
        and candidate.stat().st_size > 0
        and expected_digest
        and sha256(candidate) == expected_digest
    ):
        return candidate, completion
    return None


def preserve_recovery_delta(
    experiment_root: Path,
    candidate_root: Path,
    attempt_name: str,
) -> Path | None:
    delta = experiment_root / "best-trainable-parameters.delta.pt"
    if not delta.is_file() or delta.stat().st_size == 0:
        return None
    digest = sha256(delta)
    destination = candidate_root / "recovery" / f"{attempt_name}-{digest[:12]}.delta.pt"
    if not destination.is_file():
        atomic_copy(delta, destination)
    atomic_json(
        destination.with_suffix(".json"),
        {
            "schemaVersion": 1,
            "candidate": str(destination),
            "sha256": digest,
            "completeTraining": False,
            "createdAt": utc_now(),
            "reuse": (
                "This is the best epoch-level recovery delta, not a completed "
                "five-epoch candidate. Keep it for diagnosis; the automatic "
                "source gate evaluates only a completed training run."
            ),
        },
    )
    return destination


def find_compatible_resume_checkpoint(
    work_root: Path,
    datasets: dict[str, Path],
    profile: GPUProfile,
    max_epochs: int,
    learning_rate: str,
    minimum_learning_rate: str,
    warmup_steps: int,
    max_steps: int,
    checkpoint_every_n_steps: int,
    seed: int,
    freeze_decoder: bool,
    freeze_joint: bool,
    freeze_batchnorm: bool,
    deterministic: bool,
) -> tuple[Path, Path] | None:
    expected = {
        "train_manifest": str((datasets["training"] / "train.jsonl").resolve()),
        "validation_manifest": str(
            (datasets["training"] / "validation.jsonl").resolve()
        ),
        "precision": profile.precision,
        "batch_size": profile.batch_size,
        "validation_batch_size": profile.validation_batch_size,
        "accumulate_grad_batches": profile.accumulate_grad_batches,
        "max_duration": profile.max_duration,
        "train_top_encoder_layers": profile.train_top_encoder_layers,
        "train_decoder": not freeze_decoder,
        "train_joint": not freeze_joint,
        "freeze_batchnorm": freeze_batchnorm,
        "max_epochs": max_epochs,
        "max_steps": max_steps,
        "learning_rate": float(learning_rate),
        "minimum_learning_rate": float(minimum_learning_rate),
        "warmup_steps": warmup_steps,
        "checkpoint_every_n_steps": checkpoint_every_n_steps,
        "seed": seed,
        "deterministic": deterministic,
    }
    candidates: list[tuple[int, float, Path, Path]] = []
    for configuration_path in sorted(
        (work_root / "experiments").glob("*/training-configuration.json")
    ):
        try:
            configuration = json.loads(
                configuration_path.read_text(encoding="utf-8")
            )
        except (OSError, json.JSONDecodeError):
            continue
        if any(configuration.get(key) != value for key, value in expected.items()):
            continue
        experiment_root = configuration_path.parent
        checkpoint_roots = [experiment_root / "checkpoints"]
        external_checkpoint_root = os.environ.get("VOXOL_FULL_CHECKPOINT_ROOT")
        if external_checkpoint_root:
            checkpoint_roots.append(
                Path(external_checkpoint_root).resolve() / experiment_root.name
            )
        checkpoints = (
            checkpoint
            for root in checkpoint_roots
            for checkpoint in root.glob("step-*.ckpt")
        )
        for checkpoint in checkpoints:
            match = re.fullmatch(r"step-(\d+)\.ckpt", checkpoint.name)
            if match is None:
                continue
            step = int(match.group(1))
            if max_steps > 0 and step > max_steps:
                continue
            try:
                with zipfile.ZipFile(checkpoint) as archive:
                    if not any(
                        name == "data.pkl" or name.endswith("/data.pkl")
                        for name in archive.namelist()
                    ):
                        continue
            except (OSError, zipfile.BadZipFile):
                continue
            candidates.append(
                (step, checkpoint.stat().st_mtime, checkpoint, experiment_root)
            )
    if not candidates:
        return None
    _, _, checkpoint, experiment_root = max(candidates)
    return checkpoint, experiment_root


def train_candidate(
    source_root: Path,
    work_root: Path,
    datasets: dict[str, Path],
    profile: GPUProfile,
    max_epochs: int,
    log_root: Path,
    *,
    training_identity: str = "google-fleurs-fr-en-v1",
    learning_rate: str = "2e-5",
    minimum_learning_rate: str = "2e-6",
    warmup_steps: int = 100,
    max_steps: int = 0,
    checkpoint_every_n_steps: int = 0,
    seed: int = 42,
    freeze_decoder: bool = False,
    freeze_joint: bool = False,
    freeze_batchnorm: bool = False,
    deterministic: bool = False,
    fallback: GPUProfile | None = None,
) -> tuple[Path, dict[str, object]]:
    candidate_root = work_root / "candidates"
    completion_path = candidate_root / "training-complete.json"
    if existing := existing_candidate(
        completion_path,
        max_epochs,
        training_identity,
        learning_rate,
        minimum_learning_rate,
        warmup_steps,
        max_steps,
        checkpoint_every_n_steps,
        seed,
        freeze_decoder,
        freeze_joint,
        freeze_batchnorm,
        deterministic,
    ):
        print(f"Reusing verified completed candidate: {existing[0]}", flush=True)
        return existing

    run_token = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    attempts = (profile, fallback or fallback_profile(profile))
    last_error: BaseException | None = None
    for number, attempt in enumerate(attempts, 1):
        attempt_name = f"{run_token}-attempt-{number}-{attempt.name}"
        experiment_root = work_root / "experiments" / attempt_name
        resume = find_compatible_resume_checkpoint(
            work_root,
            datasets,
            attempt,
            max_epochs,
            learning_rate,
            minimum_learning_rate,
            warmup_steps,
            max_steps,
            checkpoint_every_n_steps,
            seed,
            freeze_decoder,
            freeze_joint,
            freeze_batchnorm,
            deterministic,
        )
        if resume is not None:
            resume_checkpoint, experiment_root = resume
            attempt_name = experiment_root.name
            print(
                f"Resuming compatible training checkpoint: {resume_checkpoint}",
                flush=True,
            )
        command = [
            sys.executable,
            source_root / "Tools/training/run_voxol_nemo_finetune.py",
            "--train-manifest",
            datasets["training"] / "train.jsonl",
            "--validation-manifest",
            datasets["training"] / "validation.jsonl",
            "--experiment-root",
            experiment_root,
            "--precision",
            attempt.precision,
            "--batch-size",
            attempt.batch_size,
            "--validation-batch-size",
            attempt.validation_batch_size,
            "--accumulate-grad-batches",
            attempt.accumulate_grad_batches,
            "--max-duration",
            attempt.max_duration,
            "--train-top-encoder-layers",
            attempt.train_top_encoder_layers,
            "--max-epochs",
            max_epochs,
            "--max-steps",
            max_steps,
            "--learning-rate",
            learning_rate,
            "--minimum-learning-rate",
            minimum_learning_rate,
            "--warmup-steps",
            warmup_steps,
            "--checkpoint-every-n-steps",
            checkpoint_every_n_steps,
            "--num-workers",
            "2",
            "--seed",
            seed,
        ]
        if resume is not None:
            command.extend(["--resume-checkpoint", resume_checkpoint])
        if freeze_decoder:
            command.append("--freeze-decoder")
        if freeze_joint:
            command.append("--freeze-joint")
        if freeze_batchnorm:
            command.append("--freeze-batchnorm")
        if deterministic:
            command.append("--deterministic")
        log_path = log_root / f"training-attempt-{number}.log"
        try:
            stream_command(command, log_path)
        except CommandFailure as error:
            preserve_recovery_delta(
                experiment_root,
                candidate_root,
                attempt_name,
            )
            last_error = error
            if error.is_resource_failure and number == 1:
                print(
                    "\nThe first profile exhausted a resource. "
                    "Retrying once with the safe fallback.",
                    flush=True,
                )
                continue
            raise

        delta = experiment_root / "best-trainable-parameters.delta.pt"
        if not delta.is_file() or delta.stat().st_size == 0:
            raise RuntimeError("Training completed without a trainable delta.")
        digest = sha256(delta)
        candidate = candidate_root / f"{attempt.name}-{digest[:12]}.delta.pt"
        if not candidate.is_file():
            atomic_copy(delta, candidate)
        completion = {
            "schemaVersion": 1,
            "pipelineVersion": PIPELINE_VERSION,
            "baseModel": MODEL_ID,
            "candidate": str(candidate),
            "sha256": digest,
            "bytes": candidate.stat().st_size,
            "profile": asdict(attempt),
            "epochs": max_epochs,
            "trainingIdentity": training_identity,
            "learningRate": learning_rate,
            "minimumLearningRate": minimum_learning_rate,
            "warmupSteps": warmup_steps,
            "maxSteps": max_steps,
            "checkpointEveryNSteps": checkpoint_every_n_steps,
            "seed": seed,
            "freezeDecoder": freeze_decoder,
            "freezeJoint": freeze_joint,
            "freezeBatchNorm": freeze_batchnorm,
            "deterministic": deterministic,
            "trainingLog": str(log_path),
            "completedAt": utc_now(),
        }
        atomic_json(completion_path, completion)
        return candidate, completion
    assert last_error is not None
    raise last_error


def prediction_is_complete(manifest_path: Path, prediction_path: Path) -> bool:
    if not prediction_path.is_file():
        return False
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected = {str(item["id"]) for item in manifest["items"]}
    actual: set[str] = set()
    try:
        for line in prediction_path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                identifier = str(json.loads(line)["id"])
                if identifier in actual:
                    return False
                actual.add(identifier)
    except (KeyError, json.JSONDecodeError):
        return False
    return actual == expected


def evaluate(
    source_root: Path,
    datasets: dict[str, Path],
    result_root: Path,
    log_root: Path,
    label: str,
    model_arguments: list[object],
    batch_size: int,
    benchmark_specs: tuple[tuple[str, str], ...] | None = None,
    audio_roots: dict[str, Path] | None = None,
) -> dict[str, Path]:
    output_root = result_root / "evaluation" / label
    output_root.mkdir(parents=True, exist_ok=True)
    reports: dict[str, Path] = {}
    benchmarks = benchmark_specs or (
        ("fleurs-fr-en-test", "fleurs"),
        ("mediaspeech-fr", "mediaspeech"),
    )
    for benchmark_label, dataset_key in benchmarks:
        benchmark_root = datasets[dataset_key]
        audio_root = (
            audio_roots[dataset_key]
            if audio_roots is not None and dataset_key in audio_roots
            else benchmark_root / "audio"
        )
        manifest = benchmark_root / "manifest-frozen.json"
        predictions = output_root / f"{benchmark_label}-predictions.jsonl"
        if prediction_is_complete(manifest, predictions):
            print(f"Reusing complete predictions: {predictions}", flush=True)
        else:
            run_source_script(
                source_root,
                "Tools/training/run_nemo_asr_benchmark.py",
                [
                    *model_arguments,
                    "--manifest",
                    manifest,
                    "--audio-root",
                    audio_root,
                    "--output",
                    predictions,
                    "--batch-size",
                    batch_size,
                    "--resume",
                ],
                log_root / f"{label}-{benchmark_label}.log",
            )
        report = output_root / f"{benchmark_label}-report.json"
        run_source_script(
            source_root,
            "Tools/training/score_asr_predictions.py",
            [
                "--manifest",
                manifest,
                "--predictions",
                predictions,
                "--output",
                report,
            ],
            log_root / f"{label}-{benchmark_label}-score.log",
        )
        reports[dataset_key] = report
    return reports


def load_report(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def source_gate(
    candidate: Path,
    candidate_digest: str,
    baseline_reports: dict[str, Path],
    candidate_reports: dict[str, Path],
) -> dict[str, object]:
    baseline_fleurs = load_report(baseline_reports["fleurs"])
    candidate_fleurs = load_report(candidate_reports["fleurs"])
    baseline_media = load_report(baseline_reports["mediaspeech"])
    candidate_media = load_report(candidate_reports["mediaspeech"])
    checks = {
        "fleursOverallRegressionAtMost0.5Point": (
            candidate_fleurs["microWER"] <= baseline_fleurs["microWER"] + 0.005
        ),
        "fleursFrenchRegressionAtMost0.5Point": (
            candidate_fleurs["byLanguage"]["french"]["microWER"]
            <= baseline_fleurs["byLanguage"]["french"]["microWER"] + 0.005
        ),
        "fleursEnglishRegressionAtMost0.5Point": (
            candidate_fleurs["byLanguage"]["english"]["microWER"]
            <= baseline_fleurs["byLanguage"]["english"]["microWER"] + 0.005
        ),
        "mediaSpeechImprovesAtLeast10PercentRelative": (
            candidate_media["microWER"] <= baseline_media["microWER"] * 0.90
        ),
        "mediaSpeechEmptyOutputsDecrease": (
            candidate_media["emptyOutputCount"] < baseline_media["emptyOutputCount"]
        ),
    }
    passed = all(checks.values())
    return {
        "schemaVersion": 1,
        "pipelineVersion": PIPELINE_VERSION,
        "sourceGatePassed": passed,
        "checks": checks,
        "candidate": str(candidate),
        "candidateSHA256": candidate_digest,
        "baseline": {
            "fleurs": baseline_fleurs,
            "mediaspeech": baseline_media,
        },
        "candidateResults": {
            "fleurs": candidate_fleurs,
            "mediaspeech": candidate_media,
        },
        "nextStep": (
            "Run the pinned Mac reconstruction and Core ML int8/int4 parity gate."
            if passed
            else "Reject this candidate and keep the current production artifact."
        ),
        "decidedAt": utc_now(),
    }


def quantization_plan(gate: dict[str, object]) -> dict[str, object]:
    passed = bool(gate["sourceGatePassed"])
    return {
        "schemaVersion": 1,
        "candidateSHA256": gate["candidateSHA256"],
        "sourceGatePassed": passed,
        "automaticQuantizationPerformed": False,
        "trainingArtifact": {
            "format": "VoxoL NeMo trainable delta",
            "precision": "FP16 tensors over the floating-point NeMo base model",
            "quantized": False,
        },
        "productionContext": {
            "currentASR": "Pinned Core ML 4-bit Parakeet conversion",
            "currentPolisher": "Pinned MLX 4-bit Qwen3.5-0.8B",
        },
        "eligibleForMacQuantization": passed,
        "plannedCandidates": ["Core ML int8", "Core ML int4"],
        "requiredMacGate": [
            "Reconstruct the official NeMo model from the verified delta in a fresh process.",
            "Export architecture-compatible int8 and int4 Core ML candidates.",
            "Measure WER parity, empty outputs, language drift, latency, RAM and energy on the M4.",
            "Promote only a candidate that preserves the source-gate quality.",
        ],
        "reason": (
            "The source candidate passed. Quantization is deferred to the Mac parity stage "
            "because Linux NeMo training cannot validate VoxoL's Core ML runtime contract."
            if passed
            else "The source candidate failed, so quantizing it would waste time and hide a quality regression."
        ),
    }


def environment_report(
    profile: GPUProfile,
    arguments: argparse.Namespace,
    started_epoch: float,
) -> dict[str, object]:
    import nemo
    import torch

    gpu = torch.cuda.get_device_properties(0)
    return {
        "schemaVersion": 1,
        "pipelineVersion": PIPELINE_VERSION,
        "startedAt": datetime.fromtimestamp(started_epoch, timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        "host": {
            "platform": platform.platform(),
            "python": sys.version,
            "machine": platform.machine(),
        },
        "runtime": {
            "torch": torch.__version__,
            "cudaRuntime": torch.version.cuda,
            "nemo": getattr(nemo, "__version__", "unknown"),
        },
        "gpu": {
            "name": gpu.name,
            "memoryGiB": round(gpu.total_memory / (1024**3), 2),
            "bf16Supported": torch.cuda.is_bf16_supported(),
        },
        "profile": asdict(profile),
        "costGuard": {
            "hourlyPriceUSD": arguments.hourly_price,
            "budgetUSD": arguments.budget,
            "maximumHours": arguments.max_hours,
            "maximumComputeCostUSD": round(
                arguments.hourly_price * arguments.max_hours, 2
            ),
            "scope": (
                "Compute-time estimate supplied by the user. Provider storage, "
                "network and idle-instance charges are not observable by this script."
            ),
        },
    }


def archive_files(
    work_root: Path,
    candidate: Path | None,
) -> list[tuple[Path, str]]:
    files: list[tuple[Path, str]] = []
    roots = (
        work_root / "results",
        work_root / "candidates",
    )
    for root in roots:
        if root.is_dir():
            for path in sorted(root.rglob("*")):
                if not path.is_file() or path.suffix == ".partial":
                    continue
                if candidate is not None and root.name == "candidates":
                    relative = path.relative_to(root)
                    if "recovery" in relative.parts:
                        continue
                    if (
                        path.name.endswith(".delta.pt")
                        and path.resolve() != candidate.resolve()
                    ):
                        continue
                files.append((path, f"VoxoL-Parakeet/{path.relative_to(work_root)}"))
    for provenance in (
        work_root / "data" / "parakeet-fleurs-fr-en" / "provenance.json",
    ):
        if provenance.is_file():
            files.append(
                (
                    provenance,
                    f"VoxoL-Parakeet/{provenance.relative_to(work_root)}",
                )
            )
    if candidate is not None and candidate.is_file():
        candidate_entry = f"VoxoL-Parakeet/candidate/{candidate.name}"
        if all(path.resolve() != candidate.resolve() for path, _ in files):
            files.append((candidate, candidate_entry))
    unique: dict[str, Path] = {}
    for path, entry in files:
        unique[entry] = path
    return [(path, entry) for entry, path in sorted(unique.items())]


def build_archive(
    work_root: Path,
    candidate: Path | None,
    run_token: str,
) -> Path:
    export_root = work_root / "exports"
    export_root.mkdir(parents=True, exist_ok=True)
    destination = export_root / f"voxol-parakeet-results-{run_token}.zip"
    temporary = destination.with_suffix(destination.suffix + ".partial")
    checksums = []
    with zipfile.ZipFile(
        temporary,
        mode="w",
        compression=zipfile.ZIP_STORED,
        allowZip64=True,
    ) as archive:
        for path, entry in archive_files(work_root, candidate):
            digest = sha256(path)
            checksums.append(f"{digest}  {entry}")
            archive.write(path, entry)
        archive.writestr(
            "VoxoL-Parakeet/SHA256SUMS.txt",
            "\n".join(checksums) + ("\n" if checksums else ""),
        )
    temporary.replace(destination)
    (work_root / "results" / "latest-export.txt").write_text(
        str(destination) + "\n",
        encoding="utf-8",
    )
    return destination


def main() -> None:
    arguments = parser().parse_args()
    ensure_budget(arguments)

    def interrupted(signal_number: int, frame: object) -> None:
        del frame
        raise KeyboardInterrupt(f"Received signal {signal_number}.")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)

    source_root = arguments.source_root.resolve()
    work_root = arguments.work_root.resolve()
    result_root = work_root / "results"
    log_root = result_root / "logs"
    result_root.mkdir(parents=True, exist_ok=True)
    started_epoch = float(os.environ.get("VOXOL_RUN_STARTED_EPOCH", str(time.time())))
    progress = Progress(
        result_root / "status.json",
        arguments.hourly_price,
        arguments.max_hours,
        started_epoch,
    )
    run_token = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    candidate: Path | None = None

    try:
        import torch

        if not torch.cuda.is_available():
            raise RuntimeError("PyTorch cannot access the NVIDIA CUDA GPU.")
        gpu = torch.cuda.get_device_properties(0)
        profile = selected_profile(
            gpu.total_memory / (1024**3),
            torch.cuda.is_bf16_supported(),
        )

        progress.begin(1, 6, "Vérification du profil GPU et de la provenance")
        report = environment_report(profile, arguments, started_epoch)
        atomic_json(result_root / "run-profile.json", report)
        print(json.dumps(report, indent=2, sort_keys=True), flush=True)
        progress.finish_stage("Vérification du profil GPU et de la provenance")

        progress.begin(2, 6, "Téléchargement vérifié et préparation des datasets")
        datasets = prepare_datasets(source_root, work_root, log_root)
        progress.finish_stage("Téléchargement vérifié et préparation des datasets")

        progress.begin(3, 6, "Fine-tuning Parakeet avec sauvegarde du meilleur delta")
        candidate, completion = train_candidate(
            source_root,
            work_root,
            datasets,
            profile,
            arguments.max_epochs,
            log_root,
        )
        candidate_digest = str(completion["sha256"])
        progress.finish_stage("Fine-tuning Parakeet avec sauvegarde du meilleur delta")

        progress.begin(4, 6, "Benchmark de la baseline officielle")
        baseline_reports = evaluate(
            source_root,
            datasets,
            result_root,
            log_root,
            "baseline",
            ["--pretrained-name", MODEL_ID],
            profile.evaluation_batch_size,
        )
        progress.finish_stage("Benchmark de la baseline officielle")

        progress.begin(5, 6, "Benchmark du candidat fine-tuné")
        candidate_label = f"candidate-{candidate_digest[:12]}"
        candidate_reports = evaluate(
            source_root,
            datasets,
            result_root,
            log_root,
            candidate_label,
            ["--delta", candidate],
            profile.evaluation_batch_size,
        )
        progress.finish_stage("Benchmark du candidat fine-tuné")

        progress.begin(6, 6, "Décision qualité, plan de quantification et archive")
        decision = source_gate(
            candidate,
            candidate_digest,
            baseline_reports,
            candidate_reports,
        )
        atomic_json(result_root / "source-gate.json", decision)
        atomic_json(
            result_root / "quantization-plan.json",
            quantization_plan(decision),
        )
        progress.finish_stage("Décision qualité, plan de quantification et archive")
        progress.succeed()
        archive = work_root / "exports" / f"voxol-parakeet-results-{run_token}.zip"
        summary = {
            "sourceGatePassed": decision["sourceGatePassed"],
            "candidate": str(candidate),
            "candidateSHA256": candidate_digest,
            "archive": str(archive),
            "status": str(progress.status_path),
            "finishedAt": utc_now(),
        }
        atomic_json(result_root / "final-summary.json", summary)
        archive = build_archive(work_root, candidate, run_token)
        print("\n" + "=" * 72, flush=True)
        print("VoxoL GPU pipeline complete.", flush=True)
        print(json.dumps(summary, indent=2, sort_keys=True), flush=True)
        print(f"DOWNLOAD_THIS_FILE={archive}", flush=True)
    except BaseException as error:
        progress.fail(error)
        failure = {
            "pipelineVersion": PIPELINE_VERSION,
            "failedAt": utc_now(),
            "error": str(error),
            "traceback": traceback.format_exc(),
            "recovery": (
                "Rerun the same launcher with the same work root. Dataset downloads "
                "and completed benchmark predictions resume. Training restarts, but "
                "the best epoch-level delta is preserved under candidates/recovery."
            ),
        }
        atomic_json(result_root / "failure.json", failure)
        try:
            archive = build_archive(work_root, candidate, run_token)
            print(f"\nRECOVERY_ARCHIVE={archive}", file=sys.stderr, flush=True)
        except BaseException as archive_error:
            print(
                f"Could not build the recovery archive: {archive_error}",
                file=sys.stderr,
                flush=True,
            )
        raise


if __name__ == "__main__":
    main()
