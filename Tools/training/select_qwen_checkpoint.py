#!/usr/bin/env python3
"""Select a Qwen LoRA checkpoint on a fixed validation generation subset."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil

from prepare_wispr_qwen_dataset import write_json
from run_qwen_wispr_finetune import quality_gate, run_evaluation


def selection_key(report: dict[str, object]) -> tuple[float, float, float]:
    metrics = report["metrics"]
    assert isinstance(metrics, dict)
    return (
        -float(metrics["protectedTokenRecall"]),
        float(metrics["microWordEditRate"]),
        float(metrics["unexpectedWordRate"]),
    )


def materialize_adapter(
    checkpoint: Path,
    adapter_config: Path,
    destination: Path,
) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(adapter_config, destination / "adapter_config.json")
    shutil.copy2(checkpoint, destination / "adapters.safetensors")
    return destination


def select(arguments: argparse.Namespace) -> dict[str, object]:
    source_adapter = arguments.run_root / "adapter"
    adapter_config = source_adapter / "adapter_config.json"
    checkpoints = sorted(source_adapter.glob("[0-9]*_adapters.safetensors"))
    if not adapter_config.is_file() or not checkpoints:
        raise SystemExit(f"No completed checkpoints in {source_adapter}")

    evaluation_root = arguments.run_root / "checkpoint-evaluation"
    baseline_report = run_evaluation(
        model=arguments.model,
        adapter=arguments.baseline_adapter,
        dataset=arguments.dataset,
        references=arguments.references,
        predictions=evaluation_root / "baseline-validation-predictions.jsonl",
        report=evaluation_root / "baseline-validation-report.json",
        limit=arguments.limit,
        log_path=evaluation_root / "baseline-validation.log",
        split="validation",
    )
    candidates = []
    for checkpoint in checkpoints:
        step = checkpoint.name.split("_", 1)[0]
        checkpoint_root = evaluation_root / step
        adapter = materialize_adapter(
            checkpoint,
            adapter_config,
            checkpoint_root / "adapter",
        )
        report_path = checkpoint_root / "validation-report.json"
        report = run_evaluation(
            model=arguments.model,
            adapter=adapter,
            dataset=arguments.dataset,
            references=arguments.references,
            predictions=checkpoint_root / "validation-predictions.jsonl",
            report=report_path,
            limit=arguments.limit,
            log_path=checkpoint_root / "validation.log",
            split="validation",
        )
        candidates.append(
            {
                "adapter": str(adapter),
                "checkpoint": str(checkpoint),
                "metrics": report["metrics"],
                "report": str(report_path),
                "step": int(step),
            }
        )

    selected = min(
        candidates,
        key=lambda candidate: selection_key({"metrics": candidate["metrics"]}),
    )
    result = {
        "baselineMetrics": baseline_report["metrics"],
        "candidates": candidates,
        "completedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "limit": arguments.limit,
        "schemaVersion": "voxol-qwen-checkpoint-selection-v1",
        "selected": selected,
        "selectionOrder": [
            "highest protected-token recall",
            "lowest micro word edit rate",
            "lowest unexpected word rate",
        ],
    }
    if arguments.test_output is not None:
        test_root = arguments.run_root / "checkpoint-evaluation" / "selected-test"
        baseline_test = run_evaluation(
            model=arguments.model,
            adapter=arguments.baseline_adapter,
            dataset=arguments.dataset,
            references=arguments.references,
            predictions=test_root / "baseline-predictions.jsonl",
            report=test_root / "baseline-report.json",
            limit=arguments.test_limit,
            log_path=test_root / "baseline.log",
            split="test",
        )
        candidate_test = run_evaluation(
            model=arguments.model,
            adapter=Path(str(selected["adapter"])),
            dataset=arguments.dataset,
            references=arguments.references,
            predictions=test_root / "candidate-predictions.jsonl",
            report=test_root / "candidate-report.json",
            limit=arguments.test_limit,
            log_path=test_root / "candidate.log",
            split="test",
        )
        result["test"] = {
            "baselineReport": str(test_root / "baseline-report.json"),
            "candidateReport": str(test_root / "candidate-report.json"),
            "limit": arguments.test_limit,
            "promotionGate": quality_gate(baseline_test, candidate_test),
            "selectedAdapter": str(selected["adapter"]),
        }
        write_json(arguments.test_output, result["test"])
    write_json(arguments.output, result)
    return result


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-root", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--baseline-adapter", type=Path)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--references", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=64)
    parser.add_argument("--test-limit", type=int)
    parser.add_argument("--test-output", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    result = select(parse_arguments())
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
