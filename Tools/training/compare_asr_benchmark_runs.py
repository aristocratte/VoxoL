#!/usr/bin/env python3
"""Compare two frozen VoxoL ASR benchmark-suite summaries."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schema_version") != 1:
        raise SystemExit(f"Unsupported summary schema: {path}")
    return payload


def indexed(summary: dict[str, Any]) -> dict[str, dict[str, Any]]:
    rows = {str(row["benchmark_id"]): row for row in summary.get("benchmarks", [])}
    if len(rows) != len(summary.get("benchmarks", [])):
        raise SystemExit("Duplicate benchmark ID in summary")
    return rows


def compare(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    baseline_rows = indexed(baseline)
    candidate_rows = indexed(candidate)
    if baseline_rows.keys() != candidate_rows.keys():
        raise SystemExit("Benchmark coverage differs between summaries")
    rows = []
    for identifier in sorted(baseline_rows):
        first = baseline_rows[identifier]
        second = candidate_rows[identifier]
        if first["item_count"] != second["item_count"]:
            raise SystemExit(f"Item count differs for {identifier}")
        baseline_wer = float(first["micro_wer"])
        candidate_wer = float(second["micro_wer"])
        absolute = candidate_wer - baseline_wer
        rows.append(
            {
                "benchmark_id": identifier,
                "item_count": first["item_count"],
                "baseline_micro_wer": baseline_wer,
                "candidate_micro_wer": candidate_wer,
                "absolute_wer_delta": absolute,
                "relative_wer_delta": absolute / baseline_wer if baseline_wer else None,
                "baseline_p95_ms": first["p95_ms"],
                "candidate_p95_ms": second["p95_ms"],
                "p95_ratio": float(second["p95_ms"]) / float(first["p95_ms"]),
            }
        )
    return {
        "schema_version": 1,
        "baseline": {
            "candidate_delta_sha256": baseline.get("candidate_delta_sha256"),
            "encoder_weight_sha256": baseline.get("encoder_weight_sha256"),
            "runtime_root": baseline.get("runtime_root"),
        },
        "candidate": {
            "candidate_delta_sha256": candidate.get("candidate_delta_sha256"),
            "encoder_weight_sha256": candidate.get("encoder_weight_sha256"),
            "runtime_root": candidate.get("runtime_root"),
        },
        "benchmarks": rows,
        "candidate_passes_non_regression": all(
            row["absolute_wer_delta"] <= 0.005 and row["p95_ratio"] <= 1.5 for row in rows
        ),
    }


def markdown(report: dict[str, Any]) -> str:
    lines = [
        "# VoxoL ASR benchmark comparison",
        "",
        "| Benchmark | Baseline WER | Candidate WER | Relative delta | Baseline p95 | Candidate p95 |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in report["benchmarks"]:
        lines.append(
            "| {benchmark_id} | {baseline_micro_wer:.2%} | {candidate_micro_wer:.2%} | "
            "{relative_wer_delta:+.2%} | {baseline_p95_ms:.1f} ms | {candidate_p95_ms:.1f} ms |".format(
                **row
            )
        )
    lines.extend(
        [
            "",
            f"Non-regression gate: **{'pass' if report['candidate_passes_non_regression'] else 'fail'}**.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    arguments = parser.parse_args()
    report = compare(load(arguments.baseline), load(arguments.candidate))
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    arguments.markdown.parent.mkdir(parents=True, exist_ok=True)
    arguments.markdown.write_text(markdown(report), encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
