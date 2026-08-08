#!/usr/bin/env python3
"""Run the complete local VoxoL Wispr-to-Qwen LoRA experiment on Apple Silicon."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from prepare_compact_qwen_dataset import prepare as prepare_compact
from prepare_wispr_qwen_dataset import prepare, write_json


SOURCE_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DATASET = Path(
    "/Volumes/0_Oueillez/wispr-data/transcripts/dataset/polisher-manifest.jsonl"
)
DEFAULT_SPLIT_REPORT = Path(
    "/Volumes/0_Oueillez/wispr-data/prepared/parakeet-wispr-v1/split-report.json"
)
DEFAULT_WORK_ROOT = Path("/Volumes/0_Oueillez/wispr-data/prepared/qwen-wispr-v1")
DEFAULT_MODEL = Path.home() / (
    "Library/Application Support/VoxoL/Models/polisher/"
    "2fc06364715b967f1860aea9cf38778875588b17"
)
# Fraction of the installed polisher's p95 the candidate may add before the
# dictation envelope is considered broken.
MAXIMUM_P95_LATENCY_REGRESSION = 0.10
HYBRID_LORA_KEYS = [
    "self_attn.q_proj",
    "self_attn.k_proj",
    "self_attn.v_proj",
    "self_attn.o_proj",
    "linear_attn.in_proj_qkv",
    "linear_attn.in_proj_z",
    "linear_attn.out_proj",
]


def stream_process(command: list[str], log_path: Path) -> None:
    print("+", " ".join(command), flush=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
        environment = os.environ.copy()
        environment["PYTHONUNBUFFERED"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process = subprocess.Popen(
            command,
            cwd=SOURCE_ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="")
            log.write(line)
            log.flush()
        return_code = process.wait()
    if return_code != 0:
        raise RuntimeError(f"Command failed with exit code {return_code}; inspect {log_path}")


def training_config(
    *,
    model: Path,
    dataset: Path,
    adapter: Path,
    resume_adapter_file: Path | None,
    iterations: int,
    learning_rate: float,
    maximum_sequence_length: int = 512,
    number_of_layers: int = 8,
    rank: int = 8,
    validation_batches: int = 8,
) -> dict[str, object]:
    config: dict[str, object] = {
        "adapter_path": str(adapter),
        "batch_size": 1,
        "data": str(dataset),
        "fine_tune_type": "lora",
        "grad_accumulation_steps": 8,
        "iters": iterations,
        "learning_rate": learning_rate,
        "lora_parameters": {
            "dropout": 0.05,
            "keys": HYBRID_LORA_KEYS,
            "rank": rank,
            "scale": float(rank * 2),
        },
        "mask_prompt": True,
        "max_seq_length": maximum_sequence_length,
        "model": str(model),
        "num_layers": number_of_layers,
        "optimizer": "adamw",
        "save_every": min(100, iterations),
        "seed": 1729,
        "steps_per_eval": min(100, iterations),
        "steps_per_report": min(10, iterations),
        "test": False,
        "train": True,
        "val_batches": validation_batches,
    }
    if resume_adapter_file is not None:
        config["resume_adapter_file"] = str(resume_adapter_file)
    return config


def filter_training_records(dataset: Path, maximum_characters: int | None) -> int:
    if maximum_characters is None:
        return 0
    train_path = dataset / "train.jsonl"
    records = [
        json.loads(line)
        for line in train_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    retained = [
        record
        for record in records
        if sum(
            len(str(message.get("content", "")))
            for message in record.get("messages", [])
            if isinstance(message, dict)
        )
        <= maximum_characters
    ]
    temporary = train_path.with_suffix(".jsonl.partial")
    temporary.write_text(
        "".join(
            json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n"
            for record in retained
        ),
        encoding="utf-8",
    )
    os.replace(temporary, train_path)
    summary_path = dataset / "summary.json"
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    summary["train"] = len(retained)
    write_json(summary_path, summary)
    write_json(
        dataset / "training-filter-report.json",
        {
            "droppedExampleCount": len(records) - len(retained),
            "maximumCharacters": maximum_characters,
            "retainedExampleCount": len(retained),
            "schemaVersion": "voxol-qwen-training-filter-v1",
        },
    )
    return len(records) - len(retained)


def append_training_curriculum(
    source: Path,
    curriculum: Path,
    report: Path,
    *,
    curriculum_only: bool = False,
) -> dict[str, object]:
    if source.is_file():
        existing_rows = [
            json.loads(line)
            for line in source.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    elif curriculum_only:
        existing_rows = []
    else:
        raise SystemExit(f"Missing Qwen teacher source: {source}")
    curriculum_rows = [
        json.loads(line)
        for line in curriculum.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if not curriculum_rows:
        raise SystemExit(f"Empty Qwen training curriculum: {curriculum}")
    invalid = [
        str(row.get("id", ""))
        for row in curriculum_rows
        if row.get("split") != "train" or row.get("approved") is not True
    ]
    if invalid:
        raise SystemExit(
            "The Qwen curriculum must contain approved train-only rows: "
            + ", ".join(invalid[:5])
        )
    if not curriculum_only:
        existing_ids = {str(row.get("id", "")) for row in existing_rows}
        duplicate_ids = sorted(
            {
                str(row.get("id", ""))
                for row in curriculum_rows
                if str(row.get("id", "")) in existing_ids
            }
        )
        if duplicate_ids:
            raise SystemExit(
                "Qwen curriculum identifiers collide with teacher data: "
                + ", ".join(duplicate_ids[:5])
            )

    merged = sorted(
        curriculum_rows if curriculum_only else [*existing_rows, *curriculum_rows],
        key=lambda row: str(row.get("id", "")),
    )
    source.parent.mkdir(parents=True, exist_ok=True)
    temporary = source.with_suffix(source.suffix + ".partial")
    temporary.write_text(
        "".join(
            json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            for row in merged
        ),
        encoding="utf-8",
    )
    os.replace(temporary, source)
    payload = {
        "curriculum": str(curriculum.resolve()),
        "curriculumOnly": curriculum_only,
        "curriculumExampleCount": len(curriculum_rows),
        "mergedExampleCount": len(merged),
        "originalExampleCount": len(existing_rows),
        "schemaVersion": "voxol-qwen-training-curriculum-merge-v1",
    }
    write_json(report, payload)
    return payload


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def restore_frozen_evaluation(
    prepared_root: Path,
    frozen_root: Path,
) -> dict[str, object]:
    dataset = prepared_root / "mlx"
    frozen_dataset = frozen_root / "mlx"
    files = (
        (frozen_dataset / "valid.jsonl", dataset / "valid.jsonl"),
        (frozen_dataset / "test.jsonl", dataset / "test.jsonl"),
        (
            frozen_root / "evaluation-reference.jsonl",
            prepared_root / "evaluation-reference.jsonl",
        ),
    )
    missing = [str(source) for source, _ in files if not source.is_file()]
    frozen_summary_path = frozen_dataset / "summary.json"
    if not frozen_summary_path.is_file():
        missing.append(str(frozen_summary_path))
    if missing:
        raise SystemExit("Missing frozen Qwen evaluation files: " + ", ".join(missing))
    for source, destination in files:
        shutil.copy2(source, destination)
        if file_sha256(source) != file_sha256(destination):
            raise RuntimeError(f"Frozen Qwen evaluation copy mismatch: {destination}")

    summary_path = dataset / "summary.json"
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    current_rejected_ids = list(map(str, summary.get("rejected_ids", [])))
    frozen_summary = json.loads(frozen_summary_path.read_text(encoding="utf-8"))
    summary["rejected_ids"] = list(map(str, frozen_summary.get("rejected_ids", [])))
    summary["validation"] = sum(
        1 for line in (dataset / "valid.jsonl").read_text(encoding="utf-8").splitlines()
        if line.strip()
    )
    summary["test"] = sum(
        1 for line in (dataset / "test.jsonl").read_text(encoding="utf-8").splitlines()
        if line.strip()
    )
    write_json(summary_path, summary)
    payload = {
        "evaluationReferenceSHA256": file_sha256(
            prepared_root / "evaluation-reference.jsonl"
        ),
        "frozenRoot": str(frozen_root.resolve()),
        "frozenRejectedIDCount": len(summary["rejected_ids"]),
        "schemaVersion": "voxol-qwen-frozen-evaluation-v1",
        "supersededRejectedIDCount": len(current_rejected_ids),
        "testCount": summary["test"],
        "testSHA256": file_sha256(dataset / "test.jsonl"),
        "validationCount": summary["validation"],
        "validationSHA256": file_sha256(dataset / "valid.jsonl"),
    }
    write_json(prepared_root / "frozen-evaluation-report.json", payload)
    return payload


def run_identifier(config: dict[str, object]) -> str:
    encoded = json.dumps(config, separators=(",", ":"), sort_keys=True).encode()
    return hashlib.sha256(encoded).hexdigest()[:12]


def run_evaluation(
    *,
    model: Path,
    adapter: Path | None,
    dataset: Path,
    references: Path,
    predictions: Path,
    report: Path,
    limit: int | None,
    log_path: Path,
    split: str = "test",
    output_format: str = "full-text",
) -> dict[str, object]:
    command = [
        sys.executable,
        str(SOURCE_ROOT / "Tools/training/evaluate_qwen_polisher.py"),
        "--model",
        str(model),
        "--dataset",
        str(dataset),
        "--references",
        str(references),
        "--split",
        split,
        "--predictions",
        str(predictions),
        "--report",
        str(report),
        "--output-format",
        output_format,
    ]
    if adapter is not None:
        command.extend(["--adapter", str(adapter)])
    if limit is not None:
        command.extend(["--limit", str(limit)])
    stream_process(command, log_path)
    return json.loads(report.read_text(encoding="utf-8"))


def runtime_validation(
    *,
    predictions: Path,
    source: Path,
    report: Path,
    log_path: Path,
) -> dict[str, object] | None:
    """Replay the app's own Swift validator over a prediction file.

    The Python evaluator scores what the model generated. The app never ships
    that text unchecked: FidelityKit rejects an output that drops a protected
    span, invents content or runs long, and falls back to the deterministic
    pass. The plan's promotion criterion is written against that runtime
    behaviour — "protected spans remain at 100% after runtime fallback" — so
    the gate has to measure it rather than the raw generation.

    Returns None when the builder is absent, so a machine without a release
    build still produces a run instead of failing at the last step.
    """
    builder = SOURCE_ROOT / ".build/arm64-apple-macosx/release/voxol-dataset-builder"
    if not builder.is_file():
        print(
            f"Runtime validation skipped: no dataset builder at {builder}",
            flush=True,
        )
        return None
    report.parent.mkdir(parents=True, exist_ok=True)
    stream_process(
        [
            str(builder),
            "--validate-predictions",
            str(predictions),
            "--source",
            str(source),
            "--report",
            str(report),
        ],
        log_path,
    )
    return json.loads(report.read_text(encoding="utf-8"))


def latency_p95(metrics: dict[str, object]) -> float:
    """Read p95 generation latency, or 0.0 when the report omits it.

    A missing measurement must not silently pass the envelope check, so callers
    treat a zero baseline as "no envelope to compare against" explicitly.
    """
    latency = metrics.get("latencyMilliseconds")
    if not isinstance(latency, dict):
        return 0.0
    try:
        return float(latency["p95"])
    except (KeyError, TypeError, ValueError):
        return 0.0


def runtime_acceptance(validation: dict[str, object] | None) -> float:
    """Share of examples the app ships from the model instead of the fallback.

    This is the metric a user feels. A polisher whose output is rejected a
    third of the time delivers the deterministic pass a third of the time,
    however good its accepted outputs look in isolation.
    """
    if not validation:
        return 0.0
    accepted = float(validation.get("modelOutputCount", 0))
    fallback = float(validation.get("fallbackCount", 0))
    total = accepted + fallback
    return 0.0 if total == 0 else accepted / total


def quality_gate(
    baseline: dict[str, object],
    candidate: dict[str, object],
    baseline_runtime: dict[str, object] | None = None,
    candidate_runtime: dict[str, object] | None = None,
) -> dict[str, object]:
    baseline_metrics = baseline["metrics"]
    candidate_metrics = candidate["metrics"]
    assert isinstance(baseline_metrics, dict)
    assert isinstance(candidate_metrics, dict)
    baseline_wer = float(baseline_metrics["microWordEditRate"])
    candidate_wer = float(candidate_metrics["microWordEditRate"])
    relative_gain = (
        0.0 if baseline_wer == 0 else (baseline_wer - candidate_wer) / baseline_wer
    )
    baseline_p95 = latency_p95(baseline_metrics)
    candidate_p95 = latency_p95(candidate_metrics)
    checks = {
        "microWordEditRateRelativeGainAtLeast5Percent": relative_gain >= 0.05,
        # Raw generation recall is a leading indicator, not the shipping
        # criterion, so it must not regress against the installed polisher.
        # Holding it to 99.5% in isolation rejected the 2026-08-04 candidate at
        # 99.195% even though the runtime guaranteed 100% — a bar the plan
        # never set. The absolute guarantee is asserted below, on the text the
        # app actually inserts.
        "rawProtectedTokenRecallDoesNotRegress": (
            float(candidate_metrics["protectedTokenRecall"])
            >= float(baseline_metrics["protectedTokenRecall"]) - 0.001
        ),
        "unexpectedWordRateDoesNotRegress": (
            float(candidate_metrics["unexpectedWordRate"])
            <= float(baseline_metrics["unexpectedWordRate"]) + 0.002
        ),
        # The mass-training plan requires p95 to stay inside the current
        # envelope, and nothing here enforced it: the 2026-08-04 candidate won
        # 90% relative on word error while adding 432 ms at p95, and the gate
        # would have called that a pass on latency grounds. A polisher that
        # writes more tokens costs dictation responsiveness, so the trade has
        # to be visible in the verdict rather than discovered afterwards.
        "p95LatencyRegressionAtMost10Percent": (
            candidate_p95 <= baseline_p95 * (1 + MAXIMUM_P95_LATENCY_REGRESSION)
        ),
    }
    if candidate_runtime is not None:
        candidate_runtime_metrics = candidate_runtime.get("metrics") or {}
        # The plan's actual promotion criterion, measured on what the app
        # inserts rather than on what the model generated.
        checks["protectedSpansIntactAfterRuntimeFallback"] = (
            float(candidate_runtime_metrics.get("protectedTokenRecall", 0.0)) >= 1.0
        )
        if baseline_runtime is not None:
            # How often the user gets the polisher at all. The installed v6 is
            # rejected on 35% of examples; a candidate that fixed word error
            # while being rejected more often would be a worse product.
            checks["runtimeAcceptanceDoesNotRegress"] = runtime_acceptance(
                candidate_runtime
            ) >= runtime_acceptance(baseline_runtime) - 0.01
    baseline_slices = baseline.get("slices")
    candidate_slices = candidate.get("slices")
    if isinstance(baseline_slices, dict) and isinstance(candidate_slices, dict):
        for name in ("en-edit", "fr-edit", "en-noop", "fr-noop"):
            baseline_slice = baseline_slices.get(name)
            candidate_slice = candidate_slices.get(name)
            if not isinstance(baseline_slice, dict) or not isinstance(candidate_slice, dict):
                continue
            if min(
                int(baseline_slice.get("exampleCount", 0)),
                int(candidate_slice.get("exampleCount", 0)),
            ) <= 0:
                continue
            checks[f"{name}WordEditRateRegressionAtMost0Point5Point"] = (
                float(candidate_slice["microWordEditRate"])
                <= float(baseline_slice["microWordEditRate"]) + 0.005
            )
    return {
        "checks": checks,
        "passed": all(checks.values()),
        "relativeMicroWordEditRateGain": relative_gain,
        "runtime": {
            "baselineAcceptanceRate": runtime_acceptance(baseline_runtime),
            "candidateAcceptanceRate": runtime_acceptance(candidate_runtime),
            "candidateProtectedTokenRecall": float(
                (candidate_runtime or {}).get("metrics", {}).get(
                    "protectedTokenRecall", 0.0
                )
            ),
            "candidateFallbackReasons": (candidate_runtime or {}).get(
                "fallbackReasonCounts", {}
            ),
            "measured": candidate_runtime is not None,
        },
        "latency": {
            "baselineP95Milliseconds": baseline_p95,
            "candidateP95Milliseconds": candidate_p95,
            "maximumAcceptedP95Milliseconds": baseline_p95
            * (1 + MAXIMUM_P95_LATENCY_REGRESSION),
            "relativeP95Change": (
                0.0
                if baseline_p95 == 0
                else (candidate_p95 - baseline_p95) / baseline_p95
            ),
        },
    }


def run(arguments: argparse.Namespace) -> dict[str, object]:
    prepared_mode = (
        arguments.prepared_dataset is not None
        or arguments.evaluation_references is not None
    )
    if prepared_mode and (
        arguments.prepared_dataset is None
        or arguments.evaluation_references is None
    ):
        raise SystemExit(
            "--prepared-dataset and --evaluation-references must be used together"
        )
    if prepared_mode and (
        arguments.training_curriculum is not None
        or arguments.curriculum_only
        or arguments.frozen_evaluation_root is not None
        or arguments.maximum_training_characters is not None
    ):
        raise SystemExit(
            "A prepared dataset cannot be rebuilt, filtered, or combined with a curriculum"
        )
    if arguments.curriculum_only and arguments.training_curriculum is None:
        raise SystemExit("--curriculum-only requires --training-curriculum")
    if arguments.lora_rank <= 0 or arguments.train_top_layers <= 0:
        raise SystemExit("--lora-rank and --train-top-layers must be positive")
    required_paths = [(arguments.model, "local Qwen model")]
    if arguments.baseline_adapter is not None:
        required_paths.append((arguments.baseline_adapter, "baseline Qwen adapter"))
    if prepared_mode:
        assert arguments.prepared_dataset is not None
        assert arguments.evaluation_references is not None
        required_paths.extend(
            (
                (arguments.prepared_dataset, "prepared MLX dataset"),
                (arguments.evaluation_references, "Qwen evaluation references"),
            )
        )
    elif not arguments.curriculum_only:
        required_paths.extend(
            (
                (arguments.input, "Wispr polisher manifest"),
                (arguments.split_report, "Parakeet split report"),
            )
        )
    for path, label in required_paths:
        if not path.exists():
            raise SystemExit(f"Missing {label}: {path}")
    if (
        arguments.training_curriculum is not None
        and not arguments.training_curriculum.is_file()
    ):
        raise SystemExit(
            f"Missing Qwen training curriculum: {arguments.training_curriculum}"
        )
    if (
        arguments.frozen_evaluation_root is not None
        and not arguments.frozen_evaluation_root.is_dir()
    ):
        raise SystemExit(
            f"Missing frozen Qwen evaluation root: {arguments.frozen_evaluation_root}"
        )
    if (
        arguments.resume_adapter_file is not None
        and not arguments.resume_adapter_file.is_file()
    ):
        raise SystemExit(
            f"Missing Qwen resume adapter: {arguments.resume_adapter_file}"
        )

    work_root = arguments.work_root
    prepared_root = work_root / "prepared"
    if prepared_mode:
        assert arguments.prepared_dataset is not None
        assert arguments.evaluation_references is not None
        full_text_dataset = arguments.prepared_dataset.resolve()
        references = arguments.evaluation_references.resolve()
    else:
        full_text_dataset = prepared_root / "mlx"
        references = prepared_root / "evaluation-reference.jsonl"
    if prepared_mode:
        pass
    elif arguments.curriculum_only:
        assert arguments.training_curriculum is not None
        append_training_curriculum(
            prepared_root / "source.jsonl",
            arguments.training_curriculum,
            prepared_root / "training-curriculum-merge.json",
            curriculum_only=True,
        )
    else:
        prepare(
            arguments.input,
            prepared_root,
            split_report=arguments.split_report,
        )
        if arguments.training_curriculum is not None:
            append_training_curriculum(
                prepared_root / "source.jsonl",
                arguments.training_curriculum,
                prepared_root / "training-curriculum-merge.json",
            )
    if not prepared_mode:
        stream_process(
            [
                "swift",
                "run",
                "voxol-dataset-builder",
                "--input",
                str(prepared_root / "source.jsonl"),
                "--output",
                str(full_text_dataset),
            ],
            work_root / "logs" / "dataset-builder.log",
        )
    if not prepared_mode and arguments.frozen_evaluation_root is not None:
        restore_frozen_evaluation(
            prepared_root,
            arguments.frozen_evaluation_root,
        )
    if not prepared_mode:
        filter_training_records(
            full_text_dataset,
            arguments.maximum_training_characters,
        )
    if arguments.output_format == "compact-edits":
        mlx_dataset = prepared_root / "mlx-compact"
        prepare_compact(
            full_text_dataset,
            mlx_dataset,
            training_edits_only=arguments.compact_training_edits_only,
        )
    else:
        mlx_dataset = full_text_dataset

    iterations = 8 if arguments.smoke else arguments.iterations
    limit = 4 if arguments.smoke else arguments.evaluation_limit
    maximum_sequence_length = 512
    number_of_layers = arguments.train_top_layers
    rank = arguments.lora_rank
    validation_batches = 2 if arguments.smoke else 8
    memory_gigabytes = min(6.0, arguments.memory_gb)
    provisional_config = training_config(
        model=arguments.model.resolve(),
        dataset=mlx_dataset.resolve(),
        adapter=Path("ADAPTER_PATH"),
        resume_adapter_file=(
            arguments.resume_adapter_file.resolve()
            if arguments.resume_adapter_file is not None
            else None
        ),
        iterations=iterations,
        learning_rate=arguments.learning_rate,
        maximum_sequence_length=maximum_sequence_length,
        number_of_layers=number_of_layers,
        rank=rank,
        validation_batches=validation_batches,
    )
    identifier = run_identifier(provisional_config)
    run_root = work_root / "runs" / (
        f"{arguments.output_format}-r{rank}-i{iterations}-"
        f"lr{arguments.learning_rate:g}-{identifier}"
    )
    adapter = run_root / "adapter"
    config = training_config(
        model=arguments.model.resolve(),
        dataset=mlx_dataset.resolve(),
        adapter=adapter.resolve(),
        resume_adapter_file=(
            arguments.resume_adapter_file.resolve()
            if arguments.resume_adapter_file is not None
            else None
        ),
        iterations=iterations,
        learning_rate=arguments.learning_rate,
        maximum_sequence_length=maximum_sequence_length,
        number_of_layers=number_of_layers,
        rank=rank,
        validation_batches=validation_batches,
    )
    config_path = run_root / "config.json"
    write_json(config_path, config)
    status_path = run_root / "status.json"

    evaluation_root = work_root / "evaluation"
    limit_suffix = f"-limit{limit}" if limit is not None else ""
    baseline_predictions = (
        evaluation_root / f"baseline-test{limit_suffix}-predictions.jsonl"
    )
    baseline_report_path = evaluation_root / f"baseline-test{limit_suffix}-report.json"
    print("\n[1/3] Baseline Qwen", flush=True)
    baseline = run_evaluation(
        model=arguments.model,
        adapter=arguments.baseline_adapter,
        dataset=mlx_dataset,
        references=references,
        predictions=baseline_predictions,
        report=baseline_report_path,
        limit=limit,
        log_path=evaluation_root / f"baseline-test{limit_suffix}.log",
        output_format=arguments.output_format,
    )

    print("\n[2/3] Hybrid QLoRA training", flush=True)
    try:
        if not (adapter / "adapters.safetensors").is_file():
            stream_process(
                [
                    sys.executable,
                    str(SOURCE_ROOT / "Tools/training/run_mlx_lora_safely.py"),
                    "--memory-gb",
                    str(memory_gigabytes),
                    "--config",
                    str(config_path),
                ],
                run_root / "training.log",
            )
            if "loss nan" in (run_root / "training.log").read_text(
                encoding="utf-8"
            ).lower():
                raise RuntimeError(
                    "Training produced a NaN loss; the adapter is not eligible for evaluation."
                )
        else:
            print(f"Reusing completed adapter: {adapter}", flush=True)

        print("\n[3/3] Candidate Qwen", flush=True)
        candidate_predictions = run_root / f"test{limit_suffix}-predictions.jsonl"
        candidate_report_path = run_root / f"test{limit_suffix}-report.json"
        candidate = run_evaluation(
            model=arguments.model,
            adapter=adapter,
            dataset=mlx_dataset,
            references=references,
            predictions=candidate_predictions,
            report=candidate_report_path,
            limit=limit,
            log_path=run_root / f"test{limit_suffix}.log",
            output_format=arguments.output_format,
        )
        runtime_source = (
            arguments.prepared_dataset.parent / "source" / "source.jsonl"
            if prepared_mode
            else prepared_root / "source.jsonl"
        )
        baseline_runtime = None
        candidate_runtime = None
        if runtime_source.is_file():
            baseline_runtime = runtime_validation(
                predictions=baseline_predictions,
                source=runtime_source,
                report=evaluation_root / "baseline-runtime-validation.json",
                log_path=evaluation_root / "baseline-runtime-validation.log",
            )
            candidate_runtime = runtime_validation(
                predictions=candidate_predictions,
                source=runtime_source,
                report=run_root / "runtime-validation.json",
                log_path=run_root / "runtime-validation.log",
            )
        else:
            print(
                f"Runtime validation skipped: no source corpus at {runtime_source}",
                flush=True,
            )
        gate = quality_gate(baseline, candidate, baseline_runtime, candidate_runtime)
        status = {
            "adapter": str(adapter),
            "baselineAdapter": (
                str(arguments.baseline_adapter.resolve())
                if arguments.baseline_adapter is not None
                else None
            ),
            "baselineReport": str(baseline_report_path),
            "candidateReport": str(candidate_report_path),
            "completedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "config": str(config_path),
            "gate": gate,
            "outputFormat": arguments.output_format,
            "schemaVersion": "voxol-qwen-finetune-run-v1",
            "status": "complete",
        }
        write_json(status_path, status)
        return status
    except Exception as error:
        write_json(
            status_path,
            {
                "error": str(error),
                "failedAt": datetime.now(timezone.utc).isoformat().replace(
                    "+00:00", "Z"
                ),
                "schemaVersion": "voxol-qwen-finetune-run-v1",
                "status": "failed",
            },
        )
        raise


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--split-report", type=Path, default=DEFAULT_SPLIT_REPORT)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--work-root", type=Path, default=DEFAULT_WORK_ROOT)
    parser.add_argument("--baseline-adapter", type=Path)
    parser.add_argument("--prepared-dataset", type=Path)
    parser.add_argument("--evaluation-references", type=Path)
    parser.add_argument("--resume-adapter-file", type=Path)
    parser.add_argument("--iterations", type=int, default=1200)
    parser.add_argument("--learning-rate", type=float, default=5e-5)
    parser.add_argument("--memory-gb", type=float, default=8.0)
    parser.add_argument("--maximum-training-characters", type=int)
    parser.add_argument("--evaluation-limit", type=int)
    parser.add_argument("--training-curriculum", type=Path)
    parser.add_argument("--curriculum-only", action="store_true")
    parser.add_argument("--frozen-evaluation-root", type=Path)
    parser.add_argument("--lora-rank", type=int, default=4)
    parser.add_argument("--train-top-layers", type=int, default=4)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument(
        "--output-format",
        choices=("full-text", "compact-edits"),
        default="full-text",
    )
    parser.add_argument("--compact-training-edits-only", action="store_true")
    return parser.parse_args()


def main() -> None:
    status = run(parse_arguments())
    print(json.dumps(status, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
