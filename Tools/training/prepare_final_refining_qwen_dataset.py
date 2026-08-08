#!/usr/bin/env python3
"""Validate GPT reviews and prepare leakage-safe Qwen refining datasets."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
from typing import Any, Iterable
import zipfile

from validate_review_output_v2 import input_sha256, validate_review


SCHEMA_VERSION = "voxol-final-refining-dataset-v1"
RESULT_PATH = re.compile(
    r"^(batch-(?:en|fr)-\d{2})/review-results/([^/]+)\.json$"
)
INPUT_PATH = re.compile(r"^segments/([^/]+)/input\.json$")


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


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    with temporary.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(temporary, path)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verify_original_batches(
    campaign_root: Path,
    expected_inputs: dict[str, dict[str, Any]],
) -> dict[str, str]:
    index = json.loads((campaign_root / "package-index.json").read_text(encoding="utf-8"))
    batch_by_id: dict[str, str] = {}
    seen: set[str] = set()
    for batch in index["batches"]:
        name = str(batch["batch"])
        path = campaign_root / str(batch["archive"])
        if sha256_file(path) != batch["sha256"]:
            raise RuntimeError(f"Original batch hash mismatch: {name}")
        with zipfile.ZipFile(path) as archive:
            corrupt = archive.testzip()
            if corrupt is not None:
                raise RuntimeError(f"Corrupt original batch entry: {name}/{corrupt}")
            batch_count = 0
            for member in archive.namelist():
                match = INPUT_PATH.fullmatch(member)
                if match is None:
                    continue
                identifier = match.group(1)
                value = json.loads(archive.read(member))
                if identifier not in expected_inputs or value != expected_inputs[identifier]:
                    raise RuntimeError(f"Original batch input mismatch: {identifier}")
                if identifier in seen:
                    raise RuntimeError(f"Duplicate original batch input: {identifier}")
                seen.add(identifier)
                batch_by_id[identifier] = name
                batch_count += 1
            if batch_count != int(batch["segmentCount"]):
                raise RuntimeError(f"Original batch count mismatch: {name}")
    if seen != set(expected_inputs):
        raise RuntimeError("Original batch coverage does not match selected manifest")
    return batch_by_id


def load_reviews(
    archive_path: Path,
    inputs: dict[str, dict[str, Any]],
    batch_by_id: dict[str, str],
    schema: dict[str, Any],
) -> tuple[dict[str, dict[str, Any]], dict[str, list[str]]]:
    reviews: dict[str, dict[str, Any]] = {}
    warnings: dict[str, list[str]] = {}
    with zipfile.ZipFile(archive_path) as archive:
        corrupt = archive.testzip()
        if corrupt is not None:
            raise RuntimeError(f"Corrupt result entry: {corrupt}")
        for info in archive.infolist():
            if info.is_dir() or info.filename.startswith("__MACOSX/"):
                raise RuntimeError(f"Unexpected result archive entry: {info.filename}")
            match = RESULT_PATH.fullmatch(info.filename)
            if match is None:
                raise RuntimeError(f"Unexpected result path: {info.filename}")
            batch, filename_id = match.groups()
            value = json.loads(archive.read(info))
            identifier = str(value.get("id", ""))
            if identifier != filename_id:
                raise RuntimeError(f"Result filename/id mismatch: {info.filename}")
            if identifier not in inputs:
                raise RuntimeError(f"Unknown result id: {identifier}")
            if identifier in reviews:
                raise RuntimeError(f"Duplicate result id: {identifier}")
            if batch_by_id[identifier] != batch:
                raise RuntimeError(f"Result placed in wrong batch: {identifier}")
            validation = validate_review(inputs[identifier], value, schema)
            if not validation["valid"]:
                raise RuntimeError(
                    f"Invalid result {identifier}: " + "; ".join(validation["errors"])
                )
            reviews[identifier] = value
            if validation["warnings"]:
                warnings[identifier] = list(validation["warnings"])
    if set(reviews) != set(inputs):
        missing = sorted(set(inputs) - set(reviews))
        raise RuntimeError(f"Result coverage mismatch; first missing id: {missing[:1]}")
    return reviews, warnings


def split_maps(split_report: Path) -> tuple[dict[str, str], dict[str, str]]:
    report = json.loads(split_report.read_text(encoding="utf-8"))
    split_by_recording: dict[str, str] = {}
    group_by_recording: dict[str, str] = {}
    for group in report.get("groups", []):
        split = str(group.get("split", ""))
        if split not in {"train", "validation", "test"}:
            raise RuntimeError(f"Invalid split: {split!r}")
        group_id = str(group["identifier"])
        for recording in group.get("recordings", []):
            recording = str(recording)
            if recording in split_by_recording:
                raise RuntimeError(f"Recording appears in multiple groups: {recording}")
            split_by_recording[recording] = split
            group_by_recording[recording] = group_id
    return split_by_recording, group_by_recording


def base_exclusion_reasons(
    input_data: dict[str, Any],
    review: dict[str, Any],
) -> list[str]:
    reasons: list[str] = []
    if input_data["quality_control"]["training_rights_status"] != "verified":
        reasons.append("rights_hold")
    if review["decision"] == "exclude_unrecoverable":
        reasons.append("review_excluded_unrecoverable")
    if review["usable_for_polisher"] is not True:
        reasons.append("review_not_usable")
    if review["recoverable_from_raw"] is not True:
        reasons.append("not_recoverable_from_raw")
    if review["raw_content_preserved"] is not True:
        reasons.append("raw_content_not_preserved")
    if review["runtime_support"] != "raw_only":
        reasons.append("runtime_context_required")
    if review["confidence"] == "low":
        reasons.append("low_confidence")
    if not str(input_data.get("raw", "")).strip():
        reasons.append("empty_raw")
    if not str(review.get("refined_edited") or "").strip():
        reasons.append("empty_target")
    return list(dict.fromkeys(reasons))


def gold_deferral_reasons(
    input_data: dict[str, Any],
    review: dict[str, Any],
    warnings: list[str],
) -> list[str]:
    reasons: list[str] = []
    if review["confidence"] != "high":
        reasons.append("not_high_confidence")
    if review["boundary_status"] != "complete":
        reasons.append("boundary_not_complete")
    if input_data["quality_control"]["second_review_required"] is True:
        reasons.append("input_requires_second_review")
    if "requires_second_review" in review["review_flags"]:
        reasons.append("output_requires_second_review")
    if warnings:
        reasons.append("validator_warning")
    return reasons


def dictionary_terms(input_data: dict[str, Any], target: str) -> list[str]:
    raw_folded = str(input_data["raw"]).casefold()
    target_folded = target.casefold()
    values = {
        str(item.get("canonical", "")).strip()
        for item in input_data.get("entity_lexicon", [])
        if isinstance(item, dict)
    }
    return sorted(
        value
        for value in values
        if value and value.casefold() in raw_folded and value.casefold() in target_folded
    )


def source_example(
    input_data: dict[str, Any],
    review: dict[str, Any],
    *,
    split: str,
    split_group: str,
    tier: str,
) -> dict[str, Any]:
    target = str(review["refined_edited"])
    operations = list(review["edit_types"])
    operations.extend(
        f"format:{value}" for value in review["formatting"] if value != "none"
    )
    if str(input_data["raw"]).strip() == target.strip():
        operations = ["noop"]
    return {
        "after_cursor": "",
        "app_category": "other",
        "approved": True,
        "before_cursor": "",
        "dictionary": dictionary_terms(input_data, target),
        "id": str(input_data["id"]),
        "language": str(input_data["language"]),
        "operations": sorted(set(operations)),
        "profile": "document",
        "protected_tokens": [],
        "raw_transcript": str(input_data["raw"]),
        "source": f"gpt-5.6-pro-final-runtime-{tier}",
        "split": split,
        "split_group": split_group,
        "target_text": target,
    }


def verify_speaker_separation(
    source_rows: dict[str, dict[str, Any]],
    split_by_recording: dict[str, str],
) -> None:
    splits_by_speaker: dict[str, set[str]] = defaultdict(set)
    for row in source_rows.values():
        recording = str(row["recording_id"])
        if recording not in split_by_recording:
            continue
        speaker = str(row.get("speaker_id") or recording)
        splits_by_speaker[speaker].add(split_by_recording[recording])
    conflicts = {
        speaker: sorted(splits)
        for speaker, splits in splits_by_speaker.items()
        if len(splits) > 1
    }
    if conflicts:
        raise RuntimeError(f"Speaker leakage across splits: {conflicts}")


def prepare(arguments: argparse.Namespace) -> dict[str, Any]:
    campaign_root = arguments.campaign_root.resolve()
    result_archive = arguments.review_archive.resolve()
    output_root = arguments.output_root.resolve()
    if output_root.exists():
        raise RuntimeError(f"Output already exists: {output_root}")

    selected_rows = read_jsonl(campaign_root / "selected-review-manifest.jsonl")
    inputs = {str(row["id"]): row for row in selected_rows}
    if len(inputs) != len(selected_rows):
        raise RuntimeError("Duplicate selected input id")
    for identifier, value in inputs.items():
        if value.get("input_sha256") != input_sha256(value):
            raise RuntimeError(f"Invalid selected input seal: {identifier}")

    predictions = {
        str(row["id"]): row for row in read_jsonl(arguments.parakeet_predictions)
    }
    index = json.loads((campaign_root / "package-index.json").read_text(encoding="utf-8"))
    if sha256_file(arguments.parakeet_predictions) != index["source"]["parakeetPredictionSHA256"]:
        raise RuntimeError("Parakeet prediction file hash differs from campaign index")
    for identifier, value in inputs.items():
        if identifier not in predictions or value["raw"] != predictions[identifier]["rawText"]:
            raise RuntimeError(f"Selected raw differs from final runtime: {identifier}")

    batch_by_id = verify_original_batches(campaign_root, inputs)
    schema = json.loads((campaign_root / "review-output.schema.v2.json").read_text(encoding="utf-8"))
    reviews, warnings = load_reviews(
        result_archive,
        inputs,
        batch_by_id,
        schema,
    )

    manifest_rows = read_jsonl(arguments.dataset_manifest)
    source_rows = {str(row["id"]): row for row in manifest_rows}
    if not set(inputs).issubset(source_rows):
        raise RuntimeError("Dataset manifest does not cover every selected input")
    split_by_recording, group_by_recording = split_maps(arguments.split_report)
    verify_speaker_separation(source_rows, split_by_recording)

    counts: Counter[str] = Counter()
    edit_counts: Counter[str] = Counter()
    formatting_counts: Counter[str] = Counter()
    exclusions: list[dict[str, Any]] = []
    ledger: list[dict[str, Any]] = []
    gold_examples: list[dict[str, Any]] = []
    high_train_examples: list[dict[str, Any]] = []
    all_eligible_examples: list[dict[str, Any]] = []

    for identifier in sorted(inputs):
        input_data = inputs[identifier]
        review = reviews[identifier]
        recording = str(input_data["segment"]["recording_id"])
        rights = str(input_data["quality_control"]["training_rights_status"])
        base_reasons = base_exclusion_reasons(input_data, review)
        deferrals = gold_deferral_reasons(
            input_data,
            review,
            warnings.get(identifier, []),
        )
        split = split_by_recording.get(recording)
        split_group = group_by_recording.get(recording)
        if rights == "verified" and (split is None or split_group is None):
            raise RuntimeError(f"Rights-verified recording lacks a frozen split: {recording}")
        tier = "excluded"
        if not base_reasons:
            tier = "gold" if not deferrals else "silver"
            example = source_example(
                input_data,
                review,
                split=str(split),
                split_group=str(split_group),
                tier=tier,
            )
            all_eligible_examples.append(example)
            if tier == "gold":
                gold_examples.append(example)
            if str(split) == "train" and review["confidence"] == "high":
                high_train_examples.append(example)
        else:
            exclusions.append(
                {
                    "id": identifier,
                    "language": input_data["language"],
                    "reasons": base_reasons,
                    "recording_id": recording,
                    "rights_status": rights,
                }
            )

        case_type = (
            "noop"
            if isinstance(review.get("refined_edited"), str)
            and str(input_data["raw"]).strip() == str(review["refined_edited"]).strip()
            else "edit"
        )
        counts[f"decision:{review['decision']}"] += 1
        counts[f"confidence:{review['confidence']}"] += 1
        counts[f"rights:{rights}"] += 1
        counts[f"tier:{tier}"] += 1
        counts[f"case:{case_type}"] += 1
        if not base_reasons:
            counts[f"eligible:{split}:{input_data['language']}:{case_type}"] += 1
        for value in review["edit_types"]:
            edit_counts[str(value)] += 1
        for value in review["formatting"]:
            formatting_counts[str(value)] += 1
        ledger.append(
            {
                "base_exclusion_reasons": base_reasons,
                "batch": batch_by_id[identifier],
                "case_type": case_type,
                "confidence": review["confidence"],
                "gold_deferral_reasons": deferrals,
                "id": identifier,
                "input_sha256": input_data["input_sha256"],
                "language": input_data["language"],
                "recording_id": recording,
                "review_decision": review["decision"],
                "rights_status": rights,
                "split": split,
                "split_group": split_group,
                "tier": tier,
                "validator_warnings": warnings.get(identifier, []),
            }
        )

    # The default pilot honors every second-review flag. A larger high-confidence
    # staging set is emitted separately, but is not approved as the default source.
    high_confidence_staging = list(high_train_examples)
    high_confidence_staging.extend(
        example
        for example in gold_examples
        if example["split"] in {"validation", "test"}
    )
    high_confidence_staging.sort(key=lambda row: str(row["id"]))
    gold_examples.sort(key=lambda row: str(row["id"]))
    all_eligible_examples.sort(key=lambda row: str(row["id"]))
    recommended = gold_examples

    references = [
        {
            "case_type": (
                "noop"
                if row["raw_transcript"].strip() == row["target_text"].strip()
                else "edit"
            ),
            "id": row["id"],
            "language": row["language"],
            "recording_id": source_rows[str(row["id"])]["recording_id"],
            "split": row["split"],
            "split_group": row["split_group"],
        }
        for row in recommended
    ]

    output_root.mkdir(parents=True)
    write_jsonl(output_root / "review-ledger.jsonl", ledger)
    write_jsonl(output_root / "excluded.jsonl", exclusions)
    write_jsonl(output_root / "all-eligible-source.jsonl", all_eligible_examples)
    write_jsonl(
        output_root / "high-confidence-staging-source.jsonl",
        high_confidence_staging,
    )
    write_jsonl(output_root / "source.jsonl", recommended)
    write_jsonl(output_root / "evaluation-reference.jsonl", references)

    split_counts: Counter[str] = Counter(
        f"{row['split']}:{row['language']}:"
        + (
            "noop"
            if row["raw_transcript"].strip() == row["target_text"].strip()
            else "edit"
        )
        for row in recommended
    )
    report = {
        "completedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "counts": dict(sorted(counts.items())),
        "editTypes": dict(sorted(edit_counts.items())),
        "formatting": dict(sorted(formatting_counts.items())),
        "inputs": {
            "campaignIndexSHA256": sha256_file(campaign_root / "package-index.json"),
            "datasetManifestSHA256": sha256_file(arguments.dataset_manifest),
            "parakeetPredictionSHA256": sha256_file(arguments.parakeet_predictions),
            "reviewArchiveSHA256": sha256_file(result_archive),
            "splitReportSHA256": sha256_file(arguments.split_report),
        },
        "outputs": {
            "allEligibleCount": len(all_eligible_examples),
            "goldCount": len(gold_examples),
            "highConfidenceStagingCount": len(high_confidence_staging),
            "recommendedCount": len(recommended),
            "recommendedSHA256": sha256_file(output_root / "source.jsonl"),
            "splitCounts": dict(sorted(split_counts.items())),
        },
        "reviewCount": len(reviews),
        "schemaVersion": SCHEMA_VERSION,
        "validatorWarningCount": sum(len(value) for value in warnings.values()),
        "validatorWarnings": [
            {"id": identifier, "warnings": value}
            for identifier, value in sorted(warnings.items())
        ],
    }
    write_json(output_root / "audit-report.json", report)
    return report


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--campaign-root", required=True, type=Path)
    parser.add_argument("--review-archive", required=True, type=Path)
    parser.add_argument("--dataset-manifest", required=True, type=Path)
    parser.add_argument("--split-report", required=True, type=Path)
    parser.add_argument("--parakeet-predictions", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    print(json.dumps(prepare(parse_arguments()), ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
