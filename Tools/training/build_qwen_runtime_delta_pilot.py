#!/usr/bin/env python3
"""Build a product-shaped Qwen pilot from adjudicated runtime deltas."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
from typing import Any, Iterable


SCHEMA_VERSION = "voxol-qwen-runtime-delta-pilot-v1"
PRODUCT_SOURCE = "gpt-5.6-pro-runtime-delta-product-canonical-v1"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            value = json.loads(line)
            if not isinstance(value, dict):
                raise RuntimeError(f"Expected object at {path}:{line_number}")
            rows.append(value)
    return rows


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    with temporary.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(temporary, path)


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def first_letter_index(text: str) -> int | None:
    return next((index for index, character in enumerate(text) if character.isalpha()), None)


def canonical_baseline(text: str) -> str:
    """Mirror the product contract for an utterance captured at both ends."""
    value = text.strip()
    return re.sub(r",\.$", ".", value)


def canonical_target_boundary(target: str, baseline: str) -> str:
    """Remove video-chunk boundary artifacts without changing internal edits."""
    base = canonical_baseline(baseline)
    value = re.sub(r",\.$", ".", target.strip())

    base_index = first_letter_index(base)
    target_index = first_letter_index(value)
    if (
        base_index is not None
        and target_index is not None
        and base[base_index].casefold() == value[target_index].casefold()
    ):
        replacement = (
            value[target_index].upper()
            if base[base_index].isupper()
            else value[target_index].lower()
        )
        value = value[:target_index] + replacement + value[target_index + 1 :]

    base_terminal = base[-1] if base and base[-1] in ".!?…" else "."
    if value.endswith(","):
        value = value[:-1].rstrip() + base_terminal
    elif value and value[-1] not in ".!?…:;":
        value += base_terminal
    return value


def unique_by_id(rows: list[dict[str, Any]], label: str) -> dict[str, dict[str, Any]]:
    values: dict[str, dict[str, Any]] = {}
    for row in rows:
        identifier = str(row.get("id", ""))
        if not identifier:
            raise RuntimeError(f"{label} contains an empty ID")
        if identifier in values:
            raise RuntimeError(f"{label} contains duplicate ID: {identifier}")
        values[identifier] = row
    return values


def build_pilot(
    source_rows: list[dict[str, Any]],
    prepared_rows: list[dict[str, Any]],
    rejected_ids: set[str],
    curriculum_rows: list[dict[str, Any]],
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any]]:
    sources = unique_by_id(source_rows, "source")
    prepared = unique_by_id(prepared_rows, "prepared source")
    curriculum = unique_by_id(curriculum_rows, "curriculum")
    if set(sources) != set(prepared):
        raise RuntimeError("Source and prepared-source IDs differ")
    unknown_rejections = rejected_ids - set(sources)
    if unknown_rejections:
        raise RuntimeError(f"Unknown rejected ID: {sorted(unknown_rejections)[0]}")
    if any(row.get("split") != "train" for row in curriculum_rows):
        raise RuntimeError("The existing curriculum must remain train-only")

    nominal_deltas = 0
    boundary_only: list[str] = []
    product_train: list[dict[str, Any]] = []
    product_evaluation: list[dict[str, Any]] = []
    delta_counts: Counter[tuple[str, str]] = Counter()

    for identifier in sorted(sources):
        if identifier in rejected_ids:
            continue
        source = sources[identifier]
        baseline = str(prepared[identifier]["normalized_text"])
        target = str(source["target_text"])
        if target == baseline:
            continue
        nominal_deltas += 1
        canonical_base = canonical_baseline(baseline)
        canonical_target = canonical_target_boundary(target, baseline)
        if canonical_target == canonical_base:
            boundary_only.append(identifier)
            continue

        updated = dict(source)
        updated["target_text"] = canonical_target
        updated["source"] = PRODUCT_SOURCE
        updated["operations"] = sorted(
            set(map(str, source.get("operations", [])))
            | {"runtime_delta:product_canonical"}
        )
        split = str(updated.get("split", ""))
        language = str(updated.get("language", ""))
        if split not in {"train", "validation", "test"}:
            raise RuntimeError(f"Invalid frozen split for {identifier}: {split!r}")
        if language not in {"en", "fr"}:
            raise RuntimeError(f"Invalid language for {identifier}: {language!r}")
        delta_counts[(split, language)] += 1
        if split == "train":
            product_train.append(updated)
        else:
            product_evaluation.append(updated)

    collisions = set(curriculum) & {str(row["id"]) for row in product_train}
    if collisions:
        raise RuntimeError(f"Curriculum collision: {sorted(collisions)[0]}")
    combined = sorted(
        [*curriculum_rows, *product_train],
        key=lambda row: str(row["id"]),
    )
    product_all = sorted(
        [*product_train, *product_evaluation],
        key=lambda row: str(row["id"]),
    )
    product_references = [
        {
            "case_type": "edit",
            "id": row["id"],
            "language": row["language"],
            "recording_id": row.get("split_group", row["id"]),
            "split": row["split"],
            "split_group": row.get("split_group", row["id"]),
        }
        for row in product_evaluation
    ]

    report = {
        "acceptedSourceCount": len(sources) - len(rejected_ids),
        "boundaryOnlyArtifactCount": len(boundary_only),
        "curriculumExampleCount": len(curriculum_rows),
        "mergedTrainingExampleCount": len(combined),
        "nominalRuntimeDeltaCount": nominal_deltas,
        "pilotEligible": len(product_train) >= 30,
        "productDeltaCount": len(product_all),
        "productDeltaCounts": {
            split: {
                language: delta_counts[(split, language)]
                for language in ("en", "fr")
            }
            for split in ("train", "validation", "test")
        },
        "productEvaluationCount": len(product_evaluation),
        "productTrainingCount": len(product_train),
        "promotionEligible": len(product_evaluation) >= 50,
        "rejectedSourceCount": len(rejected_ids),
        "sourceExampleCount": len(source_rows),
    }
    return {
        "combined": combined,
        "product_all": product_all,
        "product_evaluation": product_evaluation,
        "product_references": product_references,
        "product_train": product_train,
    }, report


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--prepared-source", required=True, type=Path)
    parser.add_argument("--dataset-summary", required=True, type=Path)
    parser.add_argument("--curriculum", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    if arguments.output_root.exists():
        raise RuntimeError(f"Output already exists: {arguments.output_root}")
    summary = json.loads(arguments.dataset_summary.read_text(encoding="utf-8"))
    outputs, report = build_pilot(
        read_jsonl(arguments.source),
        read_jsonl(arguments.prepared_source),
        set(map(str, summary.get("rejected_ids", []))),
        read_jsonl(arguments.curriculum),
    )

    paths = {
        "combinedTrainingSource": arguments.output_root / "training-source.jsonl",
        "productDeltaSource": arguments.output_root / "product-deltas.jsonl",
        "productEvaluationSource": arguments.output_root / "product-evaluation.jsonl",
        "productEvaluationReferences":
            arguments.output_root / "product-evaluation-reference.jsonl",
        "productTrainingSource": arguments.output_root / "product-training.jsonl",
    }
    write_jsonl(paths["combinedTrainingSource"], outputs["combined"])
    write_jsonl(paths["productDeltaSource"], outputs["product_all"])
    write_jsonl(paths["productEvaluationSource"], outputs["product_evaluation"])
    write_jsonl(
        paths["productEvaluationReferences"],
        outputs["product_references"],
    )
    write_jsonl(paths["productTrainingSource"], outputs["product_train"])
    report.update(
        {
            "completedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "files": {
                name: {
                    "path": str(path.resolve()),
                    "sha256": sha256_file(path),
                }
                for name, path in paths.items()
            },
            "schemaVersion": SCHEMA_VERSION,
        }
    )
    write_json(arguments.output_root / "audit-report.json", report)
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
