#!/usr/bin/env python3
"""Short learning-rate probes for the Wispr teacher fine-tune.

The full GPU pipeline trains one candidate and scores it on five benchmarks.
That is the right shape for a promotion decision and the wrong shape for
choosing a learning rate: it spends most of its wall-clock on evaluation the
sweep does not need.

This driver reuses an already prepared work root and, for every requested
learning rate, trains a short probe and scores it on two signals only:

* the Wispr held-out split, which answers "does the model move toward the
  teacher at all";
* FLEURS FR/EN, which answers "does it forget in the process".

A learning rate that improves the first while holding the second is the one
worth spending a full step budget on.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

from Tools.training import run_voxol_gpu_pipeline as base


SWEEP_VERSION = "2026-08-03-parakeet-lr-sweep-v1"
DEFAULT_LEARNING_RATES = "3e-6,1e-5,3e-5"
DEFAULT_PROBE_STEPS = 200
DEFAULT_WARMUP_STEPS = 8
DEFAULT_BATCH_SIZE = 2
DEFAULT_ACCUMULATE_GRAD_BATCHES = 8
DEFAULT_MAX_DURATION = 30.1
DEFAULT_TRAIN_TOP_ENCODER_LAYERS = 4
DEFAULT_EVALUATION_BATCH_SIZE = 8
TRAINING_SEED = 1337


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Probe several learning rates on a prepared Wispr work root.",
    )
    result.add_argument("--source-root", type=Path, required=True)
    result.add_argument(
        "--work-root",
        type=Path,
        required=True,
        help="Work root of a completed pipeline run; its prepared data is reused.",
    )
    result.add_argument(
        "--learning-rates",
        default=DEFAULT_LEARNING_RATES,
        help=f"Comma-separated learning rates (default: {DEFAULT_LEARNING_RATES}).",
    )
    result.add_argument("--max-steps", type=int, default=DEFAULT_PROBE_STEPS)
    result.add_argument("--warmup-steps", type=int, default=DEFAULT_WARMUP_STEPS)
    result.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    result.add_argument(
        "--accumulate-grad-batches",
        type=int,
        default=DEFAULT_ACCUMULATE_GRAD_BATCHES,
    )
    result.add_argument("--max-duration", type=float, default=DEFAULT_MAX_DURATION)
    result.add_argument(
        "--train-top-encoder-layers",
        type=int,
        default=DEFAULT_TRAIN_TOP_ENCODER_LAYERS,
    )
    result.add_argument(
        "--evaluation-batch-size",
        type=int,
        default=DEFAULT_EVALUATION_BATCH_SIZE,
    )
    result.add_argument("--num-workers", type=int, default=4)
    result.add_argument("--output-root", type=Path)
    result.add_argument(
        "--skip-baseline",
        action="store_true",
        help="Reuse an existing baseline report instead of scoring the stock model.",
    )
    return result


def parse_learning_rates(raw: str) -> list[str]:
    rates = [value.strip() for value in raw.split(",") if value.strip()]
    if not rates:
        raise SystemExit("--learning-rates must list at least one value.")
    for rate in rates:
        try:
            parsed = float(rate)
        except ValueError as error:
            raise SystemExit(f"Invalid learning rate: {rate}") from error
        if parsed <= 0:
            raise SystemExit(f"Learning rate must be positive: {rate}")
    return rates


def rate_label(rate: str) -> str:
    return f"lr-{rate.replace('-', 'm').replace('+', 'p').replace('.', 'd')}"


def discover_training_root(work_root: Path) -> Path:
    """Locate the mixed Wispr+FLEURS training directory prepared by the pipeline."""
    candidates = sorted((work_root / "data").glob("wispr-fleurs-replay-*"))
    usable = [path for path in candidates if (path / "train.jsonl").is_file()]
    if not usable:
        raise SystemExit(
            f"No prepared training data under {work_root / 'data'}. "
            "Run the full pipeline once before sweeping."
        )
    if len(usable) > 1:
        raise SystemExit(
            "Several prepared training roots found; keep exactly one:\n  "
            + "\n  ".join(str(path) for path in usable)
        )
    return usable[0]


def discover_teacher_root(work_root: Path) -> Path:
    direct = work_root / "voxol-wispr-asr-v1"
    if (direct / "manifest-frozen.json").is_file():
        return direct
    matches = sorted(
        path.parent
        for path in work_root.glob("**/manifest-frozen.json")
        if path.parent.name == "voxol-wispr-asr-v1"
    )
    if not matches:
        raise SystemExit(
            f"No extracted Wispr teacher dataset under {work_root}. "
            "Run the full pipeline once before sweeping."
        )
    return matches[0]


def score_delta(
    source_root: Path,
    output_root: Path,
    log_root: Path,
    label: str,
    model_arguments: list[object],
    benchmarks: dict[str, tuple[Path, Path]],
    batch_size: int,
) -> dict[str, Path]:
    """Predict and score one model over each (manifest, audio root) benchmark."""
    reports: dict[str, Path] = {}
    for key, (manifest, audio_root) in benchmarks.items():
        evaluation_root = output_root / label
        evaluation_root.mkdir(parents=True, exist_ok=True)
        predictions = evaluation_root / f"{key}-predictions.jsonl"
        report = evaluation_root / f"{key}-report.json"
        if report.is_file():
            print(f"Reusing scored benchmark: {report}", flush=True)
            reports[key] = report
            continue
        base.run_source_script(
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
            log_root / f"{label}-{key}.log",
        )
        base.run_source_script(
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
            log_root / f"{label}-{key}-score.log",
        )
        reports[key] = report
    return reports


def train_probe(
    source_root: Path,
    arguments: argparse.Namespace,
    training_root: Path,
    experiment_root: Path,
    learning_rate: str,
    log_path: Path,
) -> Path:
    delta = experiment_root / "best-trainable-parameters.delta.pt"
    if delta.is_file() and delta.stat().st_size > 0:
        print(f"Reusing trained probe delta: {delta}", flush=True)
        return delta
    minimum_learning_rate = float(learning_rate) / 10
    base.run_source_script(
        source_root,
        "Tools/training/run_voxol_nemo_finetune.py",
        [
            "--train-manifest",
            training_root / "train.jsonl",
            "--validation-manifest",
            training_root / "validation.jsonl",
            "--experiment-root",
            experiment_root,
            "--precision",
            "bf16-mixed",
            "--batch-size",
            arguments.batch_size,
            "--validation-batch-size",
            1,
            "--accumulate-grad-batches",
            arguments.accumulate_grad_batches,
            "--max-duration",
            arguments.max_duration,
            "--train-top-encoder-layers",
            arguments.train_top_encoder_layers,
            "--freeze-decoder",
            "--freeze-joint",
            "--freeze-batchnorm",
            "--max-epochs",
            1,
            "--max-steps",
            arguments.max_steps,
            "--learning-rate",
            learning_rate,
            "--minimum-learning-rate",
            f"{minimum_learning_rate:g}",
            "--warmup-steps",
            arguments.warmup_steps,
            "--checkpoint-every-n-steps",
            max(40, arguments.max_steps // 4),
            "--num-workers",
            arguments.num_workers,
            "--seed",
            TRAINING_SEED,
        ],
        log_path,
    )
    if not delta.is_file() or delta.stat().st_size == 0:
        raise SystemExit(f"Probe at lr={learning_rate} produced no delta checkpoint.")
    return delta


def report_metrics(path: Path) -> dict[str, float]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    languages = payload.get("byLanguage") or {}
    metrics = {"microWER": float(payload["microWER"])}
    for language in ("french", "english"):
        entry = languages.get(language)
        if isinstance(entry, dict) and "microWER" in entry:
            metrics[language] = float(entry["microWER"])
    return metrics


def relative_change(candidate: float, baseline: float) -> float | None:
    if baseline <= 0:
        return None
    return (candidate - baseline) / baseline * 100


def render_table(summary: dict[str, object]) -> str:
    baseline = summary["baseline"]
    lines = [
        "",
        "=" * 78,
        f"Parakeet learning-rate sweep — {summary['probeSteps']} steps per probe, "
        f"effective batch {summary['effectiveBatchSize']}",
        "=" * 78,
        f"{'learning rate':>14} | {'Wispr WER':>10} | {'vs base':>9} | "
        f"{'FLEURS WER':>11} | {'vs base':>9}",
        "-" * 78,
        f"{'baseline':>14} | {baseline['teacher']['microWER'] * 100:>9.4f}% | "
        f"{'—':>9} | {baseline['fleurs']['microWER'] * 100:>10.4f}% | {'—':>9}",
    ]
    for probe in summary["probes"]:
        teacher_delta = relative_change(
            probe["teacher"]["microWER"],
            baseline["teacher"]["microWER"],
        )
        fleurs_delta = relative_change(
            probe["fleurs"]["microWER"],
            baseline["fleurs"]["microWER"],
        )
        lines.append(
            f"{probe['learningRate']:>14} | "
            f"{probe['teacher']['microWER'] * 100:>9.4f}% | "
            f"{teacher_delta:>+8.2f}% | "
            f"{probe['fleurs']['microWER'] * 100:>10.4f}% | "
            f"{fleurs_delta:>+8.2f}%"
        )
    lines.extend(
        [
            "-" * 78,
            "Negative 'vs base' is better. Pick the rate that lowers the Wispr WER",
            "without pushing FLEURS up: a FLEURS rise is catastrophic forgetting,",
            "not a trade to accept at probe scale.",
            "=" * 78,
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    arguments = parser().parse_args()
    source_root = arguments.source_root.resolve()
    work_root = arguments.work_root.resolve()
    learning_rates = parse_learning_rates(arguments.learning_rates)
    if arguments.max_steps <= 0:
        raise SystemExit("--max-steps must be positive.")
    if arguments.batch_size <= 0 or arguments.accumulate_grad_batches <= 0:
        raise SystemExit("--batch-size and --accumulate-grad-batches must be positive.")

    output_root = (arguments.output_root or work_root / "sweeps" / "learning-rate").resolve()
    log_root = output_root / "logs"
    output_root.mkdir(parents=True, exist_ok=True)
    log_root.mkdir(parents=True, exist_ok=True)

    training_root = discover_training_root(work_root)
    teacher_root = discover_teacher_root(work_root)
    fleurs_root = work_root / "benchmarks" / "fleurs-test"
    for required in (
        training_root / "train.jsonl",
        training_root / "validation.jsonl",
        teacher_root / "manifest-frozen.json",
        fleurs_root / "manifest-frozen.json",
    ):
        if not required.is_file():
            raise SystemExit(f"Missing prepared input: {required}")

    benchmarks = {
        "teacher": (teacher_root / "manifest-frozen.json", teacher_root),
        "fleurs": (fleurs_root / "manifest-frozen.json", fleurs_root / "audio"),
    }

    print(f"Sweep version: {SWEEP_VERSION}", flush=True)
    print(f"Training data: {training_root}", flush=True)
    print(f"Learning rates: {', '.join(learning_rates)}", flush=True)
    print(
        f"Probe: {arguments.max_steps} steps, batch {arguments.batch_size}"
        f" x {arguments.accumulate_grad_batches} accumulation",
        flush=True,
    )

    baseline_reports = score_delta(
        source_root,
        output_root,
        log_root,
        "baseline",
        ["--pretrained-name", base.MODEL_ID],
        benchmarks,
        arguments.evaluation_batch_size,
    )
    baseline = {key: report_metrics(path) for key, path in baseline_reports.items()}

    probes: list[dict[str, object]] = []
    for learning_rate in learning_rates:
        label = rate_label(learning_rate)
        print(f"\n--- probe {label} (lr={learning_rate}) ---", flush=True)
        delta = train_probe(
            source_root,
            arguments,
            training_root,
            output_root / label / "experiment",
            learning_rate,
            log_root / f"{label}-train.log",
        )
        reports = score_delta(
            source_root,
            output_root,
            log_root,
            label,
            ["--delta", delta],
            benchmarks,
            arguments.evaluation_batch_size,
        )
        probe = {
            "learningRate": learning_rate,
            "label": label,
            "delta": str(delta),
            **{key: report_metrics(path) for key, path in reports.items()},
        }
        probes.append(probe)
        base.atomic_json(output_root / "sweep-summary-partial.json", {"probes": probes})

    summary = {
        "sweepVersion": SWEEP_VERSION,
        "finishedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "trainingRoot": str(training_root),
        "probeSteps": arguments.max_steps,
        "warmupSteps": arguments.warmup_steps,
        "batchSize": arguments.batch_size,
        "accumulateGradBatches": arguments.accumulate_grad_batches,
        "effectiveBatchSize": arguments.batch_size * arguments.accumulate_grad_batches,
        "trainTopEncoderLayers": arguments.train_top_encoder_layers,
        "seed": TRAINING_SEED,
        "baseline": baseline,
        "probes": probes,
    }
    base.atomic_json(output_root / "sweep-summary.json", summary)
    (output_root / "sweep-summary-partial.json").unlink(missing_ok=True)
    print(render_table(summary), flush=True)
    print(f"SWEEP_SUMMARY={output_root / 'sweep-summary.json'}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
