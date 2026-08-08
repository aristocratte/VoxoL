#!/usr/bin/env python3
"""Convert full-text Qwen cleanup targets into lossless compact edits."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path

from compact_polisher_edits import apply_compact_edits, encode_compact_edits
from evaluate_qwen_polisher import transcript_from_user_message


SCHEMA_VERSION = "voxol-qwen-compact-dataset-v1"


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    with temporary.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(temporary, path)


def compact_system_prompt(original: str) -> str:
    language = "French" if "French" in original else "English"
    return (
        f"You correct {language} dictation. Return only a JSON array of exact "
        'replacements: [["old","new"]]. Each old must occur exactly once in the '
        "dictation. Use [] when no change is needed."
    )


def transform_record(record: dict[str, object]) -> tuple[dict[str, object], int, int]:
    messages = record.get("messages")
    if not isinstance(messages, list) or len(messages) != 3:
        raise ValueError("Expected exactly three chat messages")
    source = transcript_from_user_message(str(messages[1]["content"]))
    target = str(messages[2]["content"])
    payload = encode_compact_edits(source, target)
    if apply_compact_edits(source, payload) != target:
        raise ValueError("Compact target is not lossless")
    transformed = {
        "messages": [
            {"role": "system", "content": compact_system_prompt(str(messages[0]["content"]))},
            messages[1],
            {"role": "assistant", "content": payload},
        ]
    }
    return transformed, len(payload), len(json.loads(payload))


def prepare(
    input_root: Path,
    output_root: Path,
    *,
    training_edits_only: bool = False,
) -> dict[str, object]:
    split_reports = {}
    total_examples = 0
    edit_counts: Counter[int] = Counter()
    dropped_training_noops = 0
    for source_name, destination_name in (
        ("train.jsonl", "train.jsonl"),
        ("valid.jsonl", "valid.jsonl"),
        ("test.jsonl", "test.jsonl"),
    ):
        transformed = []
        payload_characters = []
        for record in read_jsonl(input_root / source_name):
            compact, character_count, edit_count = transform_record(record)
            if source_name == "train.jsonl" and training_edits_only and edit_count == 0:
                dropped_training_noops += 1
                continue
            transformed.append(compact)
            payload_characters.append(character_count)
            edit_counts[edit_count] += 1
        write_jsonl(output_root / destination_name, transformed)
        total_examples += len(transformed)
        split_reports[destination_name] = {
            "exampleCount": len(transformed),
            "meanPayloadCharacters": (
                sum(payload_characters) / max(1, len(payload_characters))
            ),
        }
    summary = json.loads((input_root / "summary.json").read_text(encoding="utf-8"))
    summary["train"] = split_reports["train.jsonl"]["exampleCount"]
    summary_path = output_root / "summary.json"
    summary_path.write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    report = {
        "completedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "droppedTrainingNoopCount": dropped_training_noops,
        "editCountDistribution": dict(sorted(edit_counts.items())),
        "exampleCount": total_examples,
        "schemaVersion": SCHEMA_VERSION,
        "splits": split_reports,
        "trainingEditsOnly": training_edits_only,
    }
    report_path = output_root / "compact-dataset-report.json"
    temporary = report_path.with_suffix(".json.partial")
    temporary.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, report_path)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--training-edits-only", action="store_true")
    arguments = parser.parse_args()
    print(
        json.dumps(
            prepare(
                arguments.input_root,
                arguments.output_root,
                training_edits_only=arguments.training_edits_only,
            ),
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
