#!/usr/bin/env python3
"""Merge leakage-safe Qwen source datasets and rebuild evaluation references."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(
        "".join(
            json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            for row in rows
        ),
        encoding="utf-8",
    )
    os.replace(temporary, path)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def merge(inputs: list[Path], output_root: Path) -> dict[str, object]:
    by_id: dict[str, dict[str, object]] = {}
    group_splits: dict[str, str] = {}
    input_counts: dict[str, int] = {}
    for path in inputs:
        rows = read_jsonl(path)
        input_counts[str(path.resolve())] = len(rows)
        for row in rows:
            identifier = str(row.get("id", ""))
            split = str(row.get("split", ""))
            group = str(row.get("split_group", ""))
            if not identifier or identifier in by_id:
                raise RuntimeError(f"Missing or duplicate Qwen source id: {identifier!r}")
            if split not in {"train", "validation", "test"} or not group:
                raise RuntimeError(f"Invalid frozen split for {identifier}")
            if group in group_splits and group_splits[group] != split:
                raise RuntimeError(f"Split leakage for group {group}")
            group_splits[group] = split
            by_id[identifier] = row

    rows = [by_id[identifier] for identifier in sorted(by_id)]
    references = []
    counts: Counter[str] = Counter()
    for row in rows:
        case_type = (
            "noop"
            if str(row["raw_transcript"]).strip() == str(row["target_text"]).strip()
            else "edit"
        )
        split = str(row["split"])
        language = str(row["language"])
        counts[f"{split}:{language}:{case_type}"] += 1
        references.append(
            {
                "case_type": case_type,
                "id": row["id"],
                "language": language,
                "recording_id": row["split_group"],
                "split": split,
                "split_group": row["split_group"],
            }
        )

    source_path = output_root / "source.jsonl"
    reference_path = output_root / "evaluation-reference.jsonl"
    write_jsonl(source_path, rows)
    write_jsonl(reference_path, references)
    report = {
        "counts": dict(sorted(counts.items())),
        "evaluationReferenceSHA256": sha256(reference_path),
        "inputCounts": input_counts,
        "itemCount": len(rows),
        "schemaVersion": "voxol-qwen-source-merge-v1",
        "sourceSHA256": sha256(source_path),
        "splitGroupCount": len(group_splits),
    }
    report_path = output_root / "merge-report.json"
    report_path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", action="append", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    arguments = parser.parse_args()
    print(json.dumps(merge(arguments.input, arguments.output_root), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
