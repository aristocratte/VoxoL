#!/usr/bin/env python3
"""Prepare leakage-safe Wispr raw-to-edited examples for VoxoL's Qwen polisher."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
from typing import Iterable

from prepare_wispr_teacher_asr import (
    SPLITS,
    assign_groups,
    source_groups,
    speaker_ids,
)


SCHEMA_VERSION = "voxol-wispr-polisher-source-v1"
DEFAULT_MINIMUM_LENGTH_RATIO = 0.80
DEFAULT_MAXIMUM_LENGTH_RATIO = 1.20
DEFAULT_MAXIMUM_WORD_EDIT_RATE = 0.35
DEFAULT_MINIMUM_WORDS = 3
DEFAULT_MAXIMUM_WORDS = 160
DEFAULT_NOOP_FRACTION = 0.50
HTML_PATTERN = re.compile(r"<(?:html|body|script|style|div|p|br)\b", re.IGNORECASE)


def read_jsonl(path: Path) -> list[dict[str, object]]:
    rows = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise SystemExit(f"Invalid JSON at {path}:{line_number}") from error
        if not isinstance(row, dict):
            raise SystemExit(f"Expected a JSON object at {path}:{line_number}")
        rows.append(row)
    if not rows:
        raise SystemExit(f"Empty manifest: {path}")
    return rows


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def write_jsonl(path: Path, rows: Iterable[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    with temporary.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(temporary, path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def normalized_text(value: object) -> str:
    return " ".join(str(value or "").split())


def words(text: str) -> list[str]:
    return re.findall(r"[^\W_]+(?:['’][^\W_]+)*", text.casefold(), re.UNICODE)


def edit_distance(source: list[str], target: list[str]) -> int:
    previous = list(range(len(target) + 1))
    for source_index, source_word in enumerate(source, 1):
        current = [source_index]
        for target_index, target_word in enumerate(target, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[target_index] + 1,
                    previous[target_index - 1] + (source_word != target_word),
                )
            )
        previous = current
    return previous[-1]


def pair_metrics(raw: str, edited: str) -> tuple[float, float]:
    raw_words = words(raw)
    edited_words = words(edited)
    length_ratio = len(edited_words) / max(1, len(raw_words))
    word_edit_rate = edit_distance(raw_words, edited_words) / max(
        1, len(raw_words), len(edited_words)
    )
    return length_ratio, word_edit_rate


def quality_reasons(
    row: dict[str, object],
    *,
    minimum_length_ratio: float,
    maximum_length_ratio: float,
    maximum_word_edit_rate: float,
    minimum_words: int,
    maximum_words: int,
) -> tuple[list[str], float, float]:
    reasons = []
    raw = normalized_text(row.get("raw"))
    edited = normalized_text(row.get("edited"))
    requested_language = str(row.get("requested_language", ""))
    detected_language = str(row.get("detected_language", ""))
    raw_word_count = len(words(raw))
    edited_word_count = len(words(edited))
    length_ratio, word_edit_rate = pair_metrics(raw, edited)

    if not raw:
        reasons.append("empty_raw")
    if not edited:
        reasons.append("empty_edited")
    if requested_language not in {"fr", "en"}:
        reasons.append("unsupported_language")
    if detected_language != requested_language:
        reasons.append("language_mismatch")
    if raw_word_count < minimum_words:
        reasons.append("too_few_raw_words")
    if raw_word_count > maximum_words or edited_word_count > maximum_words:
        reasons.append("too_many_words")
    if not minimum_length_ratio <= length_ratio <= maximum_length_ratio:
        reasons.append("length_ratio_out_of_range")
    if word_edit_rate > maximum_word_edit_rate:
        reasons.append("word_edit_rate_too_high")
    if HTML_PATTERN.search(raw) or HTML_PATTERN.search(edited):
        reasons.append("html_payload")
    return reasons, length_ratio, word_edit_rate


def split_assignments(
    rows: list[dict[str, object]],
    split_report: Path | None,
) -> tuple[dict[str, str], list[dict[str, object]]]:
    groups = source_groups(rows)
    if split_report is None:
        assignments = assign_groups(groups)
    else:
        report = json.loads(split_report.read_text(encoding="utf-8"))
        assignments = {}
        splits_by_recording: dict[str, str] = {}
        for report_group in report.get("groups", []):
            split = str(report_group.get("split", ""))
            if split not in SPLITS:
                raise SystemExit(f"Invalid split in {split_report}: {split!r}")
            for recording in report_group.get("recordings", []):
                splits_by_recording[str(recording)] = split
        for group in groups:
            group_splits = {
                splits_by_recording.get(recording) for recording in group.recordings
            }
            if None in group_splits:
                missing = [
                    recording
                    for recording in group.recordings
                    if recording not in splits_by_recording
                ]
                raise SystemExit(f"Split report does not cover recordings: {missing}")
            if len(group_splits) != 1:
                raise SystemExit(
                    f"Shared-speaker group crosses splits in {split_report}: "
                    f"{group.identifier}"
                )
            assignments[group.identifier] = group_splits.pop()  # type: ignore[arg-type]

    recording_assignments = {
        recording: assignments[group.identifier]
        for group in groups
        for recording in group.recordings
    }
    serialized_groups = [
        {
            "identifier": group.identifier,
            "itemCount": group.item_count,
            "language": group.language,
            "recordings": list(group.recordings),
            "speakers": list(group.speakers),
            "split": assignments[group.identifier],
        }
        for group in groups
    ]
    return recording_assignments, serialized_groups


def selected_for_noop(identifier: str, fraction: float) -> bool:
    threshold = int(fraction * (1 << 64))
    value = int.from_bytes(hashlib.sha256(identifier.encode()).digest()[:8], "big")
    return value < threshold


def source_example(
    row: dict[str, object],
    *,
    identifier: str,
    raw: str,
    target: str,
    split: str,
    split_group: str,
    operations: list[str],
) -> dict[str, object]:
    return {
        "after_cursor": "",
        "app_category": "other",
        "approved": True,
        "before_cursor": "",
        "dictionary": [],
        "id": identifier,
        "language": row["requested_language"],
        "operations": operations,
        "profile": "document",
        "protected_tokens": [],
        "raw_transcript": raw,
        "source": "wispr-teacher-product-reference",
        "split": split,
        "split_group": split_group,
        "target_text": target,
    }


def prepare(
    input_manifest: Path,
    output_root: Path,
    *,
    split_report: Path | None = None,
    minimum_length_ratio: float = DEFAULT_MINIMUM_LENGTH_RATIO,
    maximum_length_ratio: float = DEFAULT_MAXIMUM_LENGTH_RATIO,
    maximum_word_edit_rate: float = DEFAULT_MAXIMUM_WORD_EDIT_RATE,
    minimum_words: int = DEFAULT_MINIMUM_WORDS,
    maximum_words: int = DEFAULT_MAXIMUM_WORDS,
    noop_fraction: float = DEFAULT_NOOP_FRACTION,
    raw_predictions: Path | None = None,
    require_complete_boundary: bool = False,
) -> dict[str, object]:
    if not 0 <= noop_fraction <= 1:
        raise SystemExit("--noop-fraction must be between zero and one")
    source_rows = read_jsonl(input_manifest)
    prediction_rows = read_jsonl(raw_predictions) if raw_predictions else []
    prediction_map = {
        str(row.get("id", "")): str(row.get("rawText", ""))
        for row in prediction_rows
    }
    if len(prediction_map) != len(prediction_rows) or "" in prediction_map:
        raise SystemExit("Raw predictions contain a missing or duplicate ID")
    seen_ids: set[str] = set()
    seen_pairs: set[tuple[str, str, str]] = set()
    included = []
    excluded = []
    for original_row in source_rows:
        row = dict(original_row)
        identifier = str(row.get("id", ""))
        if not identifier or identifier in seen_ids:
            raise SystemExit(f"Missing or duplicate item id: {identifier!r}")
        seen_ids.add(identifier)
        boundary_excluded = (
            require_complete_boundary and row.get("boundary_complete") is not True
        )
        if raw_predictions is not None:
            prediction = prediction_map.get(identifier)
            if prediction is None:
                # The predictions come from the benchmark manifest, which the
                # same boundary filter already emptied of these rows. A gap
                # here is the two filters agreeing, not a truncated prediction
                # file, so only demand a prediction for a row that can still be
                # included.
                if not boundary_excluded:
                    raise SystemExit(f"Missing raw prediction for {identifier}")
            else:
                row["raw"] = prediction
        reasons, length_ratio, word_edit_rate = quality_reasons(
            row,
            minimum_length_ratio=minimum_length_ratio,
            maximum_length_ratio=maximum_length_ratio,
            maximum_word_edit_rate=maximum_word_edit_rate,
            minimum_words=minimum_words,
            maximum_words=maximum_words,
        )
        if boundary_excluded:
            reasons.append("incomplete_or_legacy_boundary")
        raw = normalized_text(row.get("raw"))
        edited = normalized_text(row.get("edited"))
        pair = (str(row.get("requested_language", "")), raw, edited)
        if pair in seen_pairs:
            reasons.append("duplicate_pair")
        if reasons:
            excluded.append(
                {
                    "id": identifier,
                    "lengthRatio": round(length_ratio, 6),
                    "reasons": sorted(set(reasons)),
                    "recordingID": row.get("recording_id"),
                    "wordEditRate": round(word_edit_rate, 6),
                }
            )
            continue
        seen_pairs.add(pair)
        included.append(row)

    recording_splits, groups = split_assignments(included, split_report)
    recording_groups = {
        recording: str(group["identifier"])
        for group in groups
        for recording in group["recordings"]
    }
    examples = []
    references = []
    emitted_pairs: set[tuple[str, str, str]] = set()

    def append_example(
        row: dict[str, object],
        identifier: str,
        raw: str,
        target: str,
        case_type: str,
    ) -> None:
        pair = (str(row["requested_language"]), raw, target)
        if pair in emitted_pairs:
            return
        emitted_pairs.add(pair)
        recording = str(row["recording_id"])
        split = recording_splits[recording]
        group = recording_groups[recording]
        examples.append(
            source_example(
                row,
                identifier=identifier,
                raw=raw,
                target=target,
                split=split,
                split_group=group,
                operations=["noop" if case_type == "noop" else "faithful_cleanup"],
            )
        )
        references.append(
            {
                "case_type": case_type,
                "id": identifier,
                "language": row["requested_language"],
                "recording_id": recording,
                "split": split,
                "split_group": group,
            }
        )

    for row in sorted(included, key=lambda item: str(item["id"])):
        identifier = str(row["id"])
        raw = normalized_text(row["raw"])
        edited = normalized_text(row["edited"])
        case_type = "noop" if raw == edited else "edit"
        append_example(row, identifier, raw, edited, case_type)
        if raw != edited and selected_for_noop(identifier, noop_fraction):
            append_example(row, f"{identifier}-noop", edited, edited, "noop")

    examples.sort(key=lambda item: str(item["id"]))
    references.sort(key=lambda item: str(item["id"]))
    output_root.mkdir(parents=True, exist_ok=True)
    write_jsonl(output_root / "source.jsonl", examples)
    write_jsonl(output_root / "evaluation-reference.jsonl", references)
    write_jsonl(output_root / "excluded.jsonl", excluded)

    counts = Counter(
        (str(reference["split"]), str(reference["language"]), str(reference["case_type"]))
        for reference in references
    )
    report = {
        "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "filter": {
            "excludedByReason": dict(
                sorted(
                    Counter(
                        reason for item in excluded for reason in item["reasons"]
                    ).items()
                )
            ),
            "excludedItemCount": len(excluded),
            "includedTeacherPairCount": len(included),
            "maximumLengthRatio": maximum_length_ratio,
            "maximumWordEditRate": maximum_word_edit_rate,
            "maximumWords": maximum_words,
            "minimumLengthRatio": minimum_length_ratio,
            "minimumWords": minimum_words,
        },
        "groups": groups,
        "input": {
            "itemCount": len(source_rows),
            "manifest": str(input_manifest.resolve()),
            "manifestSHA256": sha256(input_manifest),
            "rawPredictionSHA256": (
                sha256(raw_predictions) if raw_predictions is not None else None
            ),
        },
        "labelContract": {
            "input": "VoxoL final runtime raw" if raw_predictions else "Wispr raw",
            "target": "Wispr edited",
            "teacherStatus": "product reference",
        },
        "noopFraction": noop_fraction,
        "output": {
            "exampleCount": len(examples),
            "sourceSHA256": sha256(output_root / "source.jsonl"),
        },
        "schemaVersion": SCHEMA_VERSION,
        "splits": {
            split: {
                language: {
                    case_type: counts[(split, language, case_type)]
                    for case_type in ("edit", "noop")
                }
                for language in ("en", "fr")
            }
            for split in SPLITS
        },
    }
    write_json(output_root / "split-report.json", report)
    return report


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--split-report", type=Path)
    parser.add_argument("--raw-predictions", type=Path)
    parser.add_argument("--require-complete-boundary", action="store_true")
    parser.add_argument(
        "--minimum-length-ratio",
        type=float,
        default=DEFAULT_MINIMUM_LENGTH_RATIO,
    )
    parser.add_argument(
        "--maximum-length-ratio",
        type=float,
        default=DEFAULT_MAXIMUM_LENGTH_RATIO,
    )
    parser.add_argument(
        "--maximum-word-edit-rate",
        type=float,
        default=DEFAULT_MAXIMUM_WORD_EDIT_RATE,
    )
    parser.add_argument("--minimum-words", type=int, default=DEFAULT_MINIMUM_WORDS)
    parser.add_argument("--maximum-words", type=int, default=DEFAULT_MAXIMUM_WORDS)
    parser.add_argument("--noop-fraction", type=float, default=DEFAULT_NOOP_FRACTION)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    report = prepare(
        arguments.input,
        arguments.output_root,
        split_report=arguments.split_report,
        minimum_length_ratio=arguments.minimum_length_ratio,
        maximum_length_ratio=arguments.maximum_length_ratio,
        maximum_word_edit_rate=arguments.maximum_word_edit_rate,
        minimum_words=arguments.minimum_words,
        maximum_words=arguments.maximum_words,
        noop_fraction=arguments.noop_fraction,
        raw_predictions=arguments.raw_predictions,
        require_complete_boundary=arguments.require_complete_boundary,
    )
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
