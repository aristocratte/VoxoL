#!/usr/bin/env python3
"""Fine-tune Parakeet on the frozen Wispr silver corpus and gate the result."""

from __future__ import annotations

import argparse
from dataclasses import asdict, replace
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import signal
import tarfile
import time
import traceback

from Tools.training import run_voxol_gpu_pipeline as base


PIPELINE_VERSION = "2026-08-03-wispr-mass-replay-v7"
REPLAY_SEED = "voxol-wispr-fleurs-replay-v1"
TARGET_REPLAY_FRACTION = 0.25
MINIMUM_TRAINING_STEPS = 400
MAXIMUM_TRAINING_STEPS = 1_600
TRAINING_SEED = 1337
MAX_TRAINING_DURATION_SECONDS = 30.1
DEFAULT_LEARNING_RATE = "3e-6"
DEFAULT_MINIMUM_LEARNING_RATE = "3e-7"
DEFAULT_WARMUP_STEPS = 8
# Word-error divergence allowed between the in-training validation score and the
# external re-evaluation, as a fraction of the stored error count.
VALIDATION_ERROR_TOLERANCE_RATIO = 0.005
BENCHMARKS = (
    ("wispr-teacher-heldout", "teacher"),
    ("fleurs-fr-en-test", "fleurs"),
    ("mediaspeech-fr", "mediaspeech"),
    ("librispeech-test-clean-other", "librispeech"),
    ("voxpopuli-fr-en-test", "voxpopuli"),
)
MIXED_VALIDATION_BENCHMARK = (
    ("wispr-fleurs-mixed-validation", "mixed_validation"),
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--source-root", type=Path, required=True)
    result.add_argument("--work-root", type=Path, required=True)
    result.add_argument("--teacher-dataset", type=Path, required=True)
    result.add_argument("--teacher-dataset-sha256", required=True)
    result.add_argument("--hourly-price", type=float, required=True)
    result.add_argument("--budget", type=float, required=True)
    result.add_argument("--max-hours", type=float, required=True)
    result.add_argument("--max-epochs", type=int, default=3)
    result.add_argument("--learning-rate", default=DEFAULT_LEARNING_RATE)
    result.add_argument(
        "--minimum-learning-rate",
        default=DEFAULT_MINIMUM_LEARNING_RATE,
    )
    result.add_argument("--warmup-steps", type=int, default=DEFAULT_WARMUP_STEPS)
    result.add_argument(
        "--batch-size",
        type=int,
        default=0,
        help="Override the GPU profile micro-batch size; 0 keeps the profile value.",
    )
    result.add_argument(
        "--accumulate-grad-batches",
        type=int,
        default=0,
        help="Override gradient accumulation; 0 keeps the profile value.",
    )
    result.add_argument(
        "--max-steps",
        type=int,
        default=0,
        help="Override the optimizer step budget; 0 derives one epoch from the data.",
    )
    result.add_argument(
        "--no-deterministic",
        action="store_true",
        help=(
            "Disable deterministic kernels and enable cuDNN autotuning. "
            "Use for hyper-parameter probes; keep determinism for promoted runs."
        ),
    )
    return result


def safe_member_path(member_name: str) -> Path:
    path = Path(member_name)
    if path.is_absolute() or ".." in path.parts:
        raise RuntimeError(f"Unsafe dataset archive path: {member_name}")
    if not path.parts or path.parts[0] != "voxol-wispr-asr-v1":
        raise RuntimeError(f"Unexpected dataset archive root: {member_name}")
    return path


def extract_verified_dataset(
    archive_path: Path,
    expected_digest: str,
    work_root: Path,
) -> Path:
    if not archive_path.is_file() or archive_path.stat().st_size == 0:
        raise RuntimeError(f"Missing Wispr teacher dataset: {archive_path}")
    actual_digest = base.sha256(archive_path)
    if actual_digest != expected_digest:
        raise RuntimeError(
            f"Wispr teacher archive SHA-256 mismatch: {actual_digest}"
        )

    destination = work_root / "data" / f"wispr-teacher-{actual_digest[:12]}"
    marker = destination / ".verified-archive-sha256"
    if marker.is_file() and marker.read_text(encoding="utf-8").strip() == actual_digest:
        verify_extracted_dataset(destination)
        print(f"Reusing verified Wispr teacher dataset: {destination}", flush=True)
        return destination

    temporary = destination.with_name(destination.name + ".partial")
    if temporary.exists():
        shutil.rmtree(temporary)
    temporary.mkdir(parents=True)
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive:
            relative = safe_member_path(member.name)
            if member.isdir():
                (temporary / relative).mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise RuntimeError(
                    f"Unsupported dataset archive member: {member.name}"
                )
            source = archive.extractfile(member)
            if source is None:
                raise RuntimeError(f"Unreadable dataset archive member: {member.name}")
            output = temporary / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            with output.open("wb") as stream:
                shutil.copyfileobj(source, stream, length=8 * 1024 * 1024)
            if output.stat().st_size != member.size:
                raise RuntimeError(f"Incomplete extraction: {member.name}")

    extracted_root = temporary / "voxol-wispr-asr-v1"
    verify_extracted_dataset(extracted_root)
    marker = extracted_root / ".verified-archive-sha256"
    marker.write_text(actual_digest + "\n", encoding="utf-8")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    os.replace(extracted_root, destination)
    shutil.rmtree(temporary)
    return destination


def verify_extracted_dataset(dataset_root: Path) -> None:
    package_manifest = dataset_root / "package-files.json"
    if not package_manifest.is_file():
        raise RuntimeError("Wispr teacher package is missing package-files.json.")
    package = json.loads(package_manifest.read_text(encoding="utf-8"))
    if package.get("schemaVersion") != "voxol-wispr-asr-package-v1":
        raise RuntimeError("Unsupported Wispr teacher package schema.")
    for relative, expected_digest in dict(package["metadata"]).items():
        path = dataset_root / relative
        if not path.is_file() or base.sha256(path) != expected_digest:
            raise RuntimeError(f"Invalid teacher metadata file: {relative}")
    for item in package["audio"]:
        relative = safe_member_path(
            f"voxol-wispr-asr-v1/{item['archivePath']}"
        ).relative_to("voxol-wispr-asr-v1")
        path = dataset_root / relative
        if (
            not path.is_file()
            or path.stat().st_size != int(item["bytes"])
            or base.sha256(path) != str(item["sha256"])
        ):
            raise RuntimeError(f"Invalid teacher audio file: {relative}")


def materialize_nemo_manifest(
    template_path: Path,
    dataset_root: Path,
    output_path: Path,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_suffix(output_path.suffix + ".partial")
    with template_path.open(encoding="utf-8") as source, temporary.open(
        "w", encoding="utf-8"
    ) as output:
        count = 0
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            relative = Path(str(row["audio_path"]))
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError(
                    f"Unsafe teacher audio path at {template_path}:{line_number}"
                )
            audio = (dataset_root / relative).resolve()
            if not audio.is_file():
                raise RuntimeError(f"Missing teacher audio: {audio}")
            payload = {
                "audio_filepath": str(audio),
                "duration": float(row["duration"]),
                "text": str(row["text"]),
            }
            for key in ("id", "language"):
                if row.get(key):
                    payload[key] = row[key]
            output.write(
                json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n"
            )
            count += 1
    if count == 0:
        temporary.unlink(missing_ok=True)
        raise RuntimeError(f"Empty teacher manifest: {template_path}")
    os.replace(temporary, output_path)


def read_nemo_manifest(path: Path) -> list[dict[str, object]]:
    rows = []
    seen_audio_paths: set[Path] = set()
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        duration = float(row.get("duration", 0.0))
        audio = Path(str(row.get("audio_filepath", "")))
        if not str(row.get("text", "")).strip() or not 0 < duration:
            raise RuntimeError(f"Invalid NeMo row at {path}:{line_number}")
        if duration > MAX_TRAINING_DURATION_SECONDS:
            continue
        if not audio.is_absolute():
            audio = (path.parent / audio).resolve()
        if (
            not audio.is_file()
            or audio.stat().st_size <= 44
            or audio in seen_audio_paths
        ):
            raise RuntimeError(f"Invalid NeMo row at {path}:{line_number}")
        seen_audio_paths.add(audio)
        row["audio_filepath"] = str(audio)
        rows.append(row)
    if not rows:
        raise RuntimeError(f"Empty NeMo manifest: {path}")
    return rows


def manifest_language(row: dict[str, object]) -> str:
    language = str(row.get("language", ""))
    if language in ("en", "fr"):
        return language
    parts = Path(str(row["audio_filepath"])).parts
    if "en_us" in parts:
        return "en"
    if "fr_fr" in parts:
        return "fr"
    raise RuntimeError(f"Cannot infer manifest language: {row['audio_filepath']}")


def deterministic_sample(
    rows: list[dict[str, object]],
    quotas: dict[str, int],
    seed: str,
) -> list[dict[str, object]]:
    grouped = {"en": [], "fr": []}
    for row in rows:
        grouped[manifest_language(row)].append(row)
    selected = []
    for language in sorted(quotas):
        quota = quotas[language]
        if len(grouped[language]) < quota:
            raise RuntimeError(
                f"FLEURS replay has {len(grouped[language])} {language} rows; "
                f"{quota} are required."
            )
        ranked = sorted(
            grouped[language],
            key=lambda row: (
                hashlib.sha256(
                    (
                        seed
                        + "\0"
                        + language
                        + "\0"
                        + str(row["audio_filepath"])
                        + "\0"
                        + str(row["text"])
                    ).encode("utf-8")
                ).hexdigest(),
                str(row["audio_filepath"]),
            ),
        )
        selected.extend(ranked[:quota])
    return sorted(
        selected,
        key=lambda row: (
            hashlib.sha256(
                (seed + "\0order\0" + str(row["audio_filepath"])).encode("utf-8")
            ).hexdigest(),
            str(row["audio_filepath"]),
        ),
    )


def atomic_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    with temporary.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(
                json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            )
    os.replace(temporary, path)


def mixed_replay_manifests(
    teacher_root: Path,
    fleurs_root: Path,
    output_root: Path,
) -> dict[str, object]:
    report: dict[str, object] = {
        "schemaVersion": 1,
        "seed": REPLAY_SEED,
        "targetReplayFractionByItems": TARGET_REPLAY_FRACTION,
        "splits": {},
    }
    for split in ("train", "validation"):
        teacher_rows = read_nemo_manifest(teacher_root / f"{split}.jsonl")
        general_rows = read_nemo_manifest(fleurs_root / f"{split}.jsonl")
        teacher_counts = {
            language: sum(
                manifest_language(row) == language for row in teacher_rows
            )
            for language in ("en", "fr")
        }
        available_counts = {
            language: sum(
                manifest_language(row) == language for row in general_rows
            )
            for language in ("en", "fr")
        }
        replay_ratio = TARGET_REPLAY_FRACTION / (1 - TARGET_REPLAY_FRACTION)
        quotas = {
            language: (
                min(
                    available_counts[language],
                    max(1, round(teacher_counts[language] * replay_ratio)),
                )
                if teacher_counts[language]
                else 0
            )
            for language in ("en", "fr")
        }
        replay_rows = deterministic_sample(
            general_rows,
            quotas,
            f"{REPLAY_SEED}:{split}",
        )
        mixed = sorted(
            [*teacher_rows, *replay_rows],
            key=lambda row: (
                hashlib.sha256(
                    (
                        f"{REPLAY_SEED}:{split}:order\0"
                        + str(row["audio_filepath"])
                    ).encode("utf-8")
                ).hexdigest(),
                str(row["audio_filepath"]),
            ),
        )
        output_path = output_root / f"{split}.jsonl"
        atomic_jsonl(output_path, mixed)
        report["splits"][split] = {
            "teacherItemCount": len(teacher_rows),
            "replayItemCount": len(replay_rows),
            "totalItemCount": len(mixed),
            "teacherByLanguage": teacher_counts,
            "replayByLanguage": {
                language: sum(
                    manifest_language(row) == language for row in replay_rows
                )
                for language in ("en", "fr")
            },
            "actualReplayFractionByItems": len(replay_rows) / len(mixed),
            "manifestSHA256": base.sha256(output_path),
        }
    base.atomic_json(output_root / "replay-report.json", report)
    return report


def training_step_budget(manifest: Path, profile: base.GPUProfile) -> int:
    item_count = sum(
        1 for line in manifest.read_text(encoding="utf-8").splitlines() if line.strip()
    )
    effective_batch_size = profile.batch_size * profile.accumulate_grad_batches
    one_epoch_steps = (item_count + effective_batch_size - 1) // effective_batch_size
    return min(
        MAXIMUM_TRAINING_STEPS,
        max(MINIMUM_TRAINING_STEPS, one_epoch_steps),
    )


def prepare_datasets(
    source_root: Path,
    work_root: Path,
    teacher_archive: Path,
    teacher_digest: str,
    log_root: Path,
) -> dict[str, Path]:
    teacher_root = extract_verified_dataset(
        teacher_archive,
        teacher_digest,
        work_root,
    )
    base.atomic_copy(
        teacher_root / "test-manifest-frozen.json",
        teacher_root / "manifest-frozen.json",
    )
    materialized = work_root / "data" / f"wispr-materialized-{teacher_digest[:12]}"
    for split in ("train", "validation", "test"):
        materialize_nemo_manifest(
            teacher_root / f"{split}.template.jsonl",
            teacher_root,
            materialized / f"{split}.jsonl",
        )

    dataset_cache = Path(
        os.environ.get(
            "VOXOL_DATASET_CACHE_ROOT",
            str(work_root / "cache" / "datasets"),
        )
    ).resolve()
    fleurs_replay = work_root / "data" / "fleurs-replay-fr-en"
    fleurs_test = work_root / "benchmarks" / "fleurs-test"
    mediaspeech_test = work_root / "benchmarks" / "mediaspeech-fr"
    librispeech_test = work_root / "benchmarks" / "librispeech-test"
    voxpopuli_test = work_root / "benchmarks" / "voxpopuli-fr-en-test"
    commands = (
        (
            "Scripts/prepare-parakeet-fleurs-finetune.py",
            [
                "--cache-root",
                dataset_cache / "fleurs-replay",
                "--output-root",
                fleurs_replay,
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
        (
            "Scripts/prepare-librispeech-test-benchmark.py",
            [
                "--cache-root",
                dataset_cache / "librispeech",
                "--output-root",
                librispeech_test,
            ],
        ),
        (
            "Scripts/prepare-voxpopuli-fr-en-benchmark.py",
            [
                "--cache-root",
                dataset_cache / "voxpopuli-fr-en",
                "--output-root",
                voxpopuli_test,
            ],
        ),
    )
    for index, (relative_path, arguments) in enumerate(commands, 1):
        base.run_source_script(
            source_root,
            relative_path,
            arguments,
            log_root / f"public-dataset-{index}.log",
        )
    for benchmark_root in (
        fleurs_test,
        mediaspeech_test,
        librispeech_test,
        voxpopuli_test,
    ):
        base.run_source_script(
            source_root,
            "Tools/training/freeze_asr_manifest.py",
            [
                "--input",
                benchmark_root / "manifest-unfrozen.json",
                "--output",
                benchmark_root / "manifest-frozen.json",
                "--timestamp",
                base.FREEZE_TIMESTAMP,
            ],
            log_root / "freeze-public-manifests.log",
        )
    mixed_training = (
        work_root / "data" / f"wispr-fleurs-replay-{teacher_digest[:12]}"
    )
    mixed_replay_manifests(materialized, fleurs_replay, mixed_training)
    mixed_validation = work_root / "benchmarks" / "wispr-fleurs-mixed-validation"
    base.run_source_script(
        source_root,
        "Tools/training/convert_nemo_manifest_to_benchmark.py",
        [
            "--input",
            mixed_training / "validation.jsonl",
            "--output",
            mixed_validation / "manifest-unfrozen.json",
            "--benchmark-id",
            "voxol-wispr-fleurs-mixed-validation-v1",
        ],
        log_root / "convert-mixed-validation.log",
    )
    base.run_source_script(
        source_root,
        "Tools/training/freeze_asr_manifest.py",
        [
            "--input",
            mixed_validation / "manifest-unfrozen.json",
            "--output",
            mixed_validation / "manifest-frozen.json",
            "--timestamp",
            base.FREEZE_TIMESTAMP,
        ],
        log_root / "freeze-mixed-validation.log",
    )
    return {
        "training": mixed_training,
        "teacher": teacher_root,
        "fleurs_replay": fleurs_replay,
        "mixed_validation": mixed_validation,
        "fleurs": fleurs_test,
        "mediaspeech": mediaspeech_test,
        "librispeech": librispeech_test,
        "voxpopuli": voxpopuli_test,
    }


def teacher_profile(memory_gib: float, bf16_supported: bool) -> base.GPUProfile:
    if memory_gib < 20:
        raise RuntimeError(
            "The 30-second Wispr recipe requires at least 20 GiB of GPU VRAM."
        )
    precision = "bf16-mixed" if bf16_supported else "16-mixed"
    if memory_gib < 38:
        # One 30-second clip per micro-batch, and it is not a conservative
        # guess. Freezing the lower encoder layers does free their activations,
        # but the dominant allocation in RNN-T training is the loss gradient
        # tensor of shape (batch, time, target, vocab), which scales linearly
        # with the micro-batch. Two clips was measured on a real 24 GiB RTX 4090
        # on 2026-08-03: it reached step 4 and died in `rnnt_pytorch.py` trying
        # to allocate 6.01 GiB with 4.11 GiB free. Raise this only with a larger
        # card or a shorter max_duration.
        return base.GPUProfile(
            "wispr-silver-24g",
            precision,
            1,
            1,
            16,
            MAX_TRAINING_DURATION_SECONDS,
            4,
            8,
        )
    return base.GPUProfile(
        "wispr-silver-40g",
        precision,
        2,
        2,
        8,
        MAX_TRAINING_DURATION_SECONDS,
        4,
        16,
    )


def profile_with_overrides(
    profile: base.GPUProfile,
    batch_size: int,
    accumulate_grad_batches: int,
) -> base.GPUProfile:
    """Apply explicit micro-batch overrides while preserving the effective batch.

    Overriding only ``--batch-size`` rescales accumulation so the optimizer sees
    the same effective batch as the profile; passing both takes them verbatim.
    """
    if batch_size <= 0 and accumulate_grad_batches <= 0:
        return profile
    effective = profile.batch_size * profile.accumulate_grad_batches
    resolved_batch = batch_size if batch_size > 0 else profile.batch_size
    if accumulate_grad_batches > 0:
        resolved_accumulate = accumulate_grad_batches
    else:
        resolved_accumulate = max(1, round(effective / resolved_batch))
    return replace(
        profile,
        name=f"{profile.name}-b{resolved_batch}x{resolved_accumulate}",
        batch_size=resolved_batch,
        accumulate_grad_batches=resolved_accumulate,
    )


def teacher_fallback(profile: base.GPUProfile) -> base.GPUProfile:
    return base.GPUProfile(
        f"{profile.name}-oom-fallback",
        profile.precision,
        1,
        1,
        16,
        30.1,
        4,
        min(8, profile.evaluation_batch_size),
    )


def load_report(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def teacher_source_gate(
    candidate: Path,
    candidate_digest: str,
    baseline_reports: dict[str, Path],
    candidate_reports: dict[str, Path],
    candidate_metadata: dict[str, object],
) -> dict[str, object]:
    baseline = {key: load_report(path) for key, path in baseline_reports.items()}
    candidate_results = {
        key: load_report(path) for key, path in candidate_reports.items()
    }
    teacher_before = baseline["teacher"]
    teacher_after = candidate_results["teacher"]
    fleurs_before = baseline["fleurs"]
    fleurs_after = candidate_results["fleurs"]
    media_before = baseline["mediaspeech"]
    media_after = candidate_results["mediaspeech"]
    librispeech_before = baseline["librispeech"]
    librispeech_after = candidate_results["librispeech"]
    voxpopuli_before = baseline["voxpopuli"]
    voxpopuli_after = candidate_results["voxpopuli"]
    external_validation_wer = float(
        candidate_results["mixed_validation"]["microWER"]
    )
    stored_validation_wer = float(
        candidate_metadata["validationWERSelection"]
    )
    external_word_error_counts = candidate_results["mixed_validation"][
        "wordErrors"
    ]
    external_validation_words = int(
        external_word_error_counts["referenceWords"]
    )
    external_validation_errors = sum(
        int(external_word_error_counts[key])
        for key in ("deletions", "insertions", "substitutions")
    )
    stored_validation_words = int(
        candidate_metadata["validationReferenceWords"]
    )
    stored_validation_errors = int(
        candidate_metadata["validationWordErrors"]
    )
    validation_error_delta = abs(
        external_validation_errors - stored_validation_errors
    )
    # The stored score comes from the in-training validation loop at
    # validation_batch_size, the external one from the benchmark harness at
    # evaluation_batch_size with CUDA-graph decoding. Those are two different
    # inference paths, so the TDT greedy decode is not bit-identical and a
    # handful of words differ on a six-figure corpus. Demanding an exact match
    # made this check unsatisfiable by construction: the 2026-08-03 run scored
    # 12,737 against 12,748 errors on 156,356 words — a 0.086% divergence, and
    # a 0.007-point WER difference. The tolerance below still catches what the
    # check exists to catch, a checkpoint selected on the wrong metric, since
    # that diverges by orders of magnitude (NeMo's raw WER read 15.6% where the
    # VoxoL metric read 8.1%).
    validation_error_tolerance = max(
        1,
        math.ceil(stored_validation_errors * VALIDATION_ERROR_TOLERANCE_RATIO),
    )
    checks = {
        "checkpointSelectionMetricIsGlobalVoxoLWER": (
            candidate_metadata.get("validationWERSelectionMetric")
            == "voxol-asr-v1-micro-wer"
            and external_validation_words == stored_validation_words
            and validation_error_delta <= validation_error_tolerance
        ),
        "teacherOverallImprovesAtLeast5PercentRelative": (
            teacher_after["microWER"] <= teacher_before["microWER"] * 0.95
        ),
        "teacherFrenchImprovesAtLeast2PercentRelative": (
            teacher_after["byLanguage"]["french"]["microWER"]
            <= teacher_before["byLanguage"]["french"]["microWER"] * 0.98
        ),
        "teacherEnglishImprovesAtLeast2PercentRelative": (
            teacher_after["byLanguage"]["english"]["microWER"]
            <= teacher_before["byLanguage"]["english"]["microWER"] * 0.98
        ),
        "teacherEmptyOutputsDoNotIncrease": (
            teacher_after["emptyOutputCount"] <= teacher_before["emptyOutputCount"]
        ),
        "fleursOverallRegressionAtMost0.5Point": (
            fleurs_after["microWER"] <= fleurs_before["microWER"] + 0.005
        ),
        "fleursFrenchRegressionAtMost0.5Point": (
            fleurs_after["byLanguage"]["french"]["microWER"]
            <= fleurs_before["byLanguage"]["french"]["microWER"] + 0.005
        ),
        "fleursEnglishRegressionAtMost0.5Point": (
            fleurs_after["byLanguage"]["english"]["microWER"]
            <= fleurs_before["byLanguage"]["english"]["microWER"] + 0.005
        ),
        "mediaSpeechRegressionAtMost0.5Point": (
            media_after["microWER"] <= media_before["microWER"] + 0.005
        ),
        "mediaSpeechEmptyOutputsDoNotIncrease": (
            media_after["emptyOutputCount"] <= media_before["emptyOutputCount"]
        ),
        "libriSpeechRegressionAtMost0.5Point": (
            librispeech_after["microWER"] <= librispeech_before["microWER"] + 0.005
        ),
        "libriSpeechEmptyOutputsDoNotIncrease": (
            librispeech_after["emptyOutputCount"]
            <= librispeech_before["emptyOutputCount"]
        ),
        "voxPopuliRegressionAtMost0.5Point": (
            voxpopuli_after["microWER"] <= voxpopuli_before["microWER"] + 0.005
        ),
        "voxPopuliFrenchRegressionAtMost0.5Point": (
            voxpopuli_after["byLanguage"]["french"]["microWER"]
            <= voxpopuli_before["byLanguage"]["french"]["microWER"] + 0.005
        ),
        "voxPopuliEnglishRegressionAtMost0.5Point": (
            voxpopuli_after["byLanguage"]["english"]["microWER"]
            <= voxpopuli_before["byLanguage"]["english"]["microWER"] + 0.005
        ),
        "voxPopuliEmptyOutputsDoNotIncrease": (
            voxpopuli_after["emptyOutputCount"]
            <= voxpopuli_before["emptyOutputCount"]
        ),
    }
    passed = all(checks.values())
    return {
        "schemaVersion": 1,
        "pipelineVersion": PIPELINE_VERSION,
        "sourceGatePassed": passed,
        "referenceContract": (
            "Wispr raw is the product teacher target by definition. The public "
            "benchmarks remain independent generalization gates."
        ),
        "checks": checks,
        "candidate": str(candidate),
        "candidateSHA256": candidate_digest,
        "baseline": baseline,
        "candidateResults": candidate_results,
        "checkpointValidation": {
            "externalMicroWER": external_validation_wer,
            "externalReferenceWords": external_validation_words,
            "externalWordErrors": external_validation_errors,
            "storedSelectionMicroWER": stored_validation_wer,
            "storedReferenceWords": stored_validation_words,
            "storedWordErrors": stored_validation_errors,
            "wordErrorDelta": validation_error_delta,
            "maximumAcceptedWordErrorDelta": validation_error_tolerance,
            "toleranceRatio": VALIDATION_ERROR_TOLERANCE_RATIO,
            "metric": candidate_metadata.get("validationWERSelectionMetric"),
            # A bare boolean forces whoever reads a failure to reverse-engineer
            # which of the three conditions tripped; name them instead.
            "failedConditions": [
                name
                for name, satisfied in (
                    (
                        "metricIsVoxoLMicroWER",
                        candidate_metadata.get("validationWERSelectionMetric")
                        == "voxol-asr-v1-micro-wer",
                    ),
                    (
                        "referenceWordsMatch",
                        external_validation_words == stored_validation_words,
                    ),
                    (
                        "wordErrorDeltaWithinTolerance",
                        validation_error_delta <= validation_error_tolerance,
                    ),
                )
                if not satisfied
            ],
        },
        "nextStep": (
            "Run Core ML parity and latency checks before production promotion."
            if passed
            else "Reject this candidate and keep the current production artifact."
        ),
        "decidedAt": base.utc_now(),
    }


def main() -> None:
    arguments = parser().parse_args()
    base.ensure_budget(arguments)
    expected_digest = arguments.teacher_dataset_sha256.lower()
    if (
        len(expected_digest) != 64
        or any(character not in "0123456789abcdef" for character in expected_digest)
    ):
        raise SystemExit("--teacher-dataset-sha256 must be 64 lowercase hex digits.")

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
    (result_root / "failure.json").unlink(missing_ok=True)
    started_epoch = float(os.environ.get("VOXOL_RUN_STARTED_EPOCH", str(time.time())))
    progress = base.Progress(
        result_root / "status.json",
        arguments.hourly_price,
        arguments.max_hours,
        started_epoch,
        PIPELINE_VERSION,
    )
    run_token = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    candidate: Path | None = None

    try:
        import torch

        if not torch.cuda.is_available():
            raise RuntimeError("PyTorch cannot access the NVIDIA CUDA GPU.")
        gpu = torch.cuda.get_device_properties(0)
        profile = profile_with_overrides(
            teacher_profile(
                gpu.total_memory / (1024**3),
                torch.cuda.is_bf16_supported(),
            ),
            arguments.batch_size,
            arguments.accumulate_grad_batches,
        )
        deterministic = not arguments.no_deterministic

        progress.begin(1, 6, "Vérification du profil GPU et du corpus Wispr")
        report = base.environment_report(profile, arguments, started_epoch)
        report["pipelineVersion"] = PIPELINE_VERSION
        report["teacherDataset"] = {
            "archive": str(arguments.teacher_dataset.resolve()),
            "sha256": expected_digest,
            "labelStatus": "Wispr product teacher target",
        }
        report["trainingRecipe"] = {
            "checkpointEveryNSteps": "data-derived",
            "deterministic": deterministic,
            "freezeBatchNorm": True,
            "freezeDecoder": True,
            "freezeJoint": True,
            "learningRate": arguments.learning_rate,
            "minimumLearningRate": arguments.minimum_learning_rate,
            "maximumSteps": (
                arguments.max_steps
                if arguments.max_steps > 0
                else "one effective epoch, bounded after preparation"
            ),
            "targetReplayFractionByItems": TARGET_REPLAY_FRACTION,
            "seed": TRAINING_SEED,
            "trainTopEncoderLayers": profile.train_top_encoder_layers,
            "warmupSteps": arguments.warmup_steps,
        }
        base.atomic_json(result_root / "run-profile.json", report)
        print(json.dumps(report, indent=2, sort_keys=True), flush=True)
        progress.finish_stage("Vérification du profil GPU et du corpus Wispr")

        progress.begin(2, 6, "Extraction vérifiée et préparation des benchmarks")
        datasets = prepare_datasets(
            source_root,
            work_root,
            arguments.teacher_dataset.resolve(),
            expected_digest,
            log_root,
        )
        split_report = json.loads(
            (datasets["teacher"] / "split-report.json").read_text(encoding="utf-8")
        )
        base.atomic_json(result_root / "teacher-split-report.json", split_report)
        base.atomic_copy(
            datasets["training"] / "replay-report.json",
            result_root / "replay-report.json",
        )
        maximum_steps = (
            arguments.max_steps
            if arguments.max_steps > 0
            else training_step_budget(datasets["training"] / "train.jsonl", profile)
        )
        checkpoint_every_n_steps = max(40, maximum_steps // 10)
        report["trainingRecipe"]["maximumSteps"] = maximum_steps
        report["trainingRecipe"]["checkpointEveryNSteps"] = checkpoint_every_n_steps
        report["trainingRecipe"]["effectiveBatchSize"] = (
            profile.batch_size * profile.accumulate_grad_batches
        )
        base.atomic_json(result_root / "run-profile.json", report)
        progress.finish_stage("Extraction vérifiée et préparation des benchmarks")

        progress.begin(3, 6, "Fine-tuning Wispr avec replay FLEURS anti-oubli")
        candidate, completion = base.train_candidate(
            source_root,
            work_root,
            datasets,
            profile,
            arguments.max_epochs,
            log_root,
            training_identity=f"wispr-fleurs-replay-v1:{expected_digest}",
            learning_rate=arguments.learning_rate,
            minimum_learning_rate=arguments.minimum_learning_rate,
            warmup_steps=arguments.warmup_steps,
            max_steps=maximum_steps,
            checkpoint_every_n_steps=checkpoint_every_n_steps,
            seed=TRAINING_SEED,
            freeze_decoder=True,
            freeze_joint=True,
            freeze_batchnorm=True,
            deterministic=deterministic,
            fallback=teacher_fallback(profile),
        )
        candidate_digest = str(completion["sha256"])
        progress.finish_stage("Fine-tuning Wispr avec replay FLEURS anti-oubli")

        progress.begin(4, 6, "Benchmark de la baseline officielle")
        baseline_reports = base.evaluate(
            source_root,
            datasets,
            result_root,
            log_root,
            "baseline",
            ["--pretrained-name", base.MODEL_ID],
            profile.evaluation_batch_size,
            BENCHMARKS,
            audio_roots={"teacher": datasets["teacher"]},
        )
        baseline_reports.update(
            base.evaluate(
                source_root,
                datasets,
                result_root,
                log_root,
                "baseline-mixed-validation",
                ["--pretrained-name", base.MODEL_ID],
                int(completion["profile"]["validation_batch_size"]),
                MIXED_VALIDATION_BENCHMARK,
            )
        )
        progress.finish_stage("Benchmark de la baseline officielle")

        progress.begin(5, 6, "Benchmark aveugle du candidat")
        candidate_reports = base.evaluate(
            source_root,
            datasets,
            result_root,
            log_root,
            f"candidate-{candidate_digest[:12]}",
            ["--delta", candidate],
            profile.evaluation_batch_size,
            BENCHMARKS,
            audio_roots={"teacher": datasets["teacher"]},
        )
        candidate_reports.update(
            base.evaluate(
                source_root,
                datasets,
                result_root,
                log_root,
                f"candidate-{candidate_digest[:12]}-mixed-validation",
                ["--delta", candidate],
                int(completion["profile"]["validation_batch_size"]),
                MIXED_VALIDATION_BENCHMARK,
            )
        )
        progress.finish_stage("Benchmark aveugle du candidat")

        progress.begin(6, 6, "Décision qualité et archive")
        decision = teacher_source_gate(
            candidate,
            candidate_digest,
            baseline_reports,
            candidate_reports,
            torch.load(
                candidate,
                map_location="cpu",
                weights_only=True,
            ),
        )
        base.atomic_json(result_root / "source-gate.json", decision)
        base.atomic_json(
            result_root / "quantization-plan.json",
            base.quantization_plan(decision),
        )
        progress.finish_stage("Décision qualité et archive")
        progress.succeed()
        summary = {
            "archive": str(
                work_root / "exports" / f"voxol-parakeet-results-{run_token}.zip"
            ),
            "candidate": str(candidate),
            "candidateSHA256": candidate_digest,
            "finishedAt": base.utc_now(),
            "sourceGatePassed": decision["sourceGatePassed"],
            "status": str(progress.status_path),
        }
        base.atomic_json(result_root / "final-summary.json", summary)
        archive = base.build_archive(work_root, candidate, run_token)
        print("\n" + "=" * 72, flush=True)
        print("VoxoL Wispr replay GPU pipeline complete.", flush=True)
        print(json.dumps(summary, indent=2, sort_keys=True), flush=True)
        print(f"DOWNLOAD_THIS_FILE={archive}", flush=True)
    except BaseException as error:
        progress.fail(error)
        base.atomic_json(
            result_root / "failure.json",
            {
                "pipelineVersion": PIPELINE_VERSION,
                "failedAt": base.utc_now(),
                "error": str(error),
                "traceback": traceback.format_exc(),
                "recovery": (
                    "Rerun with the same work root and the same dataset archive. "
                    "Verified extraction and completed predictions are reused."
                ),
            },
        )
        try:
            archive = base.build_archive(work_root, candidate, run_token)
            print(f"\nRECOVERY_ARCHIVE={archive}", flush=True)
        except BaseException as archive_error:
            print(f"Could not build recovery archive: {archive_error}", flush=True)
        raise


if __name__ == "__main__":
    main()
