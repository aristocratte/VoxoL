#!/usr/bin/env python3
"""Apply sealed runtime-delta adjudications to a VoxoL Qwen source dataset."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
from typing import Any, Iterable
import zipfile

from validate_runtime_delta_review import validate_delta_review


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


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


def load_inputs(path: Path) -> dict[str, dict[str, Any]]:
    values: dict[str, dict[str, Any]] = {}
    with zipfile.ZipFile(path) as archive:
        if corrupt := archive.testzip():
            raise RuntimeError(f"Corrupt input archive entry: {corrupt}")
        for info in archive.infolist():
            parts = PurePosixPath(info.filename).parts
            if info.is_dir() or len(parts) != 3 or parts[0] != "segments" or parts[2] != "input.json":
                continue
            value = json.loads(archive.read(info))
            identifier = str(value.get("id", ""))
            if identifier != parts[1]:
                raise RuntimeError(f"Input filename/id mismatch: {info.filename}")
            if identifier in values:
                raise RuntimeError(f"Duplicate input id: {identifier}")
            values[identifier] = value
    if not values:
        raise RuntimeError("Input archive contains no sealed runtime-delta inputs")
    return values


def load_reviews(
    path: Path,
    inputs: dict[str, dict[str, Any]],
    schema: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    values: dict[str, dict[str, Any]] = {}
    with zipfile.ZipFile(path) as archive:
        if corrupt := archive.testzip():
            raise RuntimeError(f"Corrupt review archive entry: {corrupt}")
        for info in archive.infolist():
            if info.is_dir():
                continue
            parts = PurePosixPath(info.filename).parts
            if len(parts) != 2 or parts[0] != "review-results" or not parts[1].endswith(".json"):
                raise RuntimeError(f"Unexpected review archive entry: {info.filename}")
            value = json.loads(archive.read(info))
            filename_id = parts[1][:-5]
            identifier = str(value.get("id", ""))
            if identifier != filename_id:
                raise RuntimeError(f"Review filename/id mismatch: {info.filename}")
            if identifier not in inputs:
                raise RuntimeError(f"Unknown review id: {identifier}")
            if identifier in values:
                raise RuntimeError(f"Duplicate review id: {identifier}")
            errors = validate_delta_review(inputs[identifier], value, schema)
            if errors:
                raise RuntimeError(f"Invalid review {identifier}: {'; '.join(errors)}")
            values[identifier] = value
    if set(values) != set(inputs):
        missing = sorted(set(inputs) - set(values))
        raise RuntimeError(f"Review coverage mismatch; first missing id: {missing[:1]}")
    return values


def apply_reviews(
    source_rows: list[dict[str, Any]],
    inputs: dict[str, dict[str, Any]],
    reviews: dict[str, dict[str, Any]],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    source_ids = {str(row["id"]) for row in source_rows}
    if len(source_ids) != len(source_rows):
        raise RuntimeError("Source dataset contains duplicate IDs")
    if not set(inputs).issubset(source_ids):
        missing = sorted(set(inputs) - source_ids)
        raise RuntimeError(f"Source dataset lacks reviewed IDs: {missing[:1]}")

    outputs: list[dict[str, Any]] = []
    decisions: Counter[str] = Counter()
    splits: Counter[str] = Counter()
    excluded: list[str] = []
    changed_targets = 0
    for source in source_rows:
        identifier = str(source["id"])
        if identifier not in reviews:
            outputs.append(source)
            continue
        review = reviews[identifier]
        input_data = inputs[identifier]
        decision = str(review["decision"])
        decisions[decision] += 1
        splits[str(source["split"])] += 1
        if decision == "exclude_unrecoverable":
            excluded.append(identifier)
            continue
        target = str(review["final_target"])
        updated = dict(source)
        if target != str(source["target_text"]):
            changed_targets += 1
        updated["target_text"] = target
        updated["source"] = "gpt-5.6-pro-runtime-delta-adjudicated-v1"
        updated["operations"] = sorted(
            set(map(str, source.get("operations", [])))
            | {f"runtime_delta:{decision}"}
        )
        if str(input_data["split"]) != str(updated["split"]):
            raise RuntimeError(f"Frozen split mismatch: {identifier}")
        outputs.append(updated)

    report = {
        "changedTargetCount": changed_targets,
        "decisionCounts": dict(sorted(decisions.items())),
        "excludedCount": len(excluded),
        "excludedIDs": sorted(excluded),
        "inputSourceCount": len(source_rows),
        "outputSourceCount": len(outputs),
        "reviewedSplitCounts": dict(sorted(splits.items())),
    }
    return outputs, report


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--input-archive", required=True, type=Path)
    parser.add_argument("--review-archive", required=True, type=Path)
    parser.add_argument("--schema", required=True, type=Path)
    parser.add_argument("--output-source", required=True, type=Path)
    parser.add_argument("--output-report", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    for output in (arguments.output_source, arguments.output_report):
        if output.exists():
            raise RuntimeError(f"Output already exists: {output}")
    inputs = load_inputs(arguments.input_archive)
    schema = json.loads(arguments.schema.read_text(encoding="utf-8"))
    reviews = load_reviews(arguments.review_archive, inputs, schema)
    outputs, report = apply_reviews(read_jsonl(arguments.source), inputs, reviews)
    write_jsonl(arguments.output_source, outputs)
    report.update(
        {
            "completedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "inputArchiveSHA256": sha256_file(arguments.input_archive),
            "outputSource": str(arguments.output_source.resolve()),
            "outputSourceSHA256": sha256_file(arguments.output_source),
            "reviewArchiveSHA256": sha256_file(arguments.review_archive),
            "schemaVersion": "voxol-runtime-delta-application-v1",
        }
    )
    write_json(arguments.output_report, report)
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
