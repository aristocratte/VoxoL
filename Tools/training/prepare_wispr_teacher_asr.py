#!/usr/bin/env python3
"""Prepare leakage-safe Parakeet manifests from the local Wispr teacher corpus."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
import gzip
import hashlib
import itertools
import json
import os
from pathlib import Path
import tarfile
from typing import Iterable


SCHEMA_VERSION = "voxol-wispr-asr-package-v1"
PACKAGE_ROOT = "voxol-wispr-asr-v1"
FREEZE_TIMESTAMP = "2026-07-29T00:00:00Z"
LANGUAGE_NAMES = {"fr": "french", "en": "english"}
SPLITS = ("train", "validation", "test")
TARGET_RATIOS = {"train": 0.70, "validation": 0.15, "test": 0.15}
MINIMUM_WORDS_PER_SECOND = 0.5
MAXIMUM_WORDS_PER_SECOND = 5.5
MINIMUM_DURATION_SECONDS = 1.0
MAXIMUM_DURATION_SECONDS = 30.1
TRANSCRIPTION_CREDIT_MARKERS = ("sous-titre", "sous titre", "subtitle")


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


def canonical_manifest_bytes(manifest: dict[str, object]) -> bytes:
    canonical = {
        "benchmarkID": manifest["benchmarkID"],
        "frozenAt": manifest["frozenAt"],
        "items": manifest["items"],
        "normalizationVersion": manifest["normalizationVersion"],
        "schemaVersion": manifest["schemaVersion"],
    }
    return json.dumps(
        canonical,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()


def speaker_ids(row: dict[str, object]) -> frozenset[str]:
    speakers = {
        speaker.strip()
        for speaker in str(row.get("speaker_id", "")).split(";")
        if speaker.strip()
    }
    if not speakers:
        speakers.add(f"unknown:{row['recording_id']}")
    return frozenset(speakers)


def resolved_audio_path(dataset_root: Path, row: dict[str, object]) -> Path:
    relative = Path(str(row["audio_path"]))
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit(f"Unsafe audio_path for {row.get('id')}: {relative}")
    row_root = Path(str(row.get("__dataset_root", dataset_root)))
    return row_root / relative


def read_corpus_rows(manifest: Path, dataset_root: Path) -> list[dict[str, object]]:
    rows = read_jsonl(manifest)
    for row in rows:
        # This private field is assigned locally; an input manifest cannot redirect reads.
        row["__dataset_root"] = str(dataset_root)
    return rows


def quality_reasons(
    dataset_root: Path,
    row: dict[str, object],
    seen_audio_hashes: set[str],
) -> list[str]:
    reasons = []
    text = " ".join(str(row.get("raw", "")).split())
    duration = float(row.get("duration", 0.0))
    requested_language = str(row.get("requested_language", ""))
    detected_language = str(row.get("detected_language", ""))
    digest = str(row.get("audio_sha256", ""))

    if row.get("usable_for_asr") is not True:
        reasons.append("teacher_marked_unusable")
    if str(row.get("raw_http_status", "")) != "200":
        reasons.append("raw_http_not_200")
    if not text:
        reasons.append("empty_transcript")
    folded_text = text.casefold()
    if "amara.org" in folded_text and any(
        marker in folded_text for marker in TRANSCRIPTION_CREDIT_MARKERS
    ):
        reasons.append("transcription_credit_boilerplate")
    if requested_language not in LANGUAGE_NAMES:
        reasons.append("unsupported_language")
    if detected_language != requested_language:
        reasons.append("language_mismatch")
    if not MINIMUM_DURATION_SECONDS <= duration <= MAXIMUM_DURATION_SECONDS:
        reasons.append("duration_out_of_range")
    if duration > 0:
        density = len(text.split()) / duration
        if density < MINIMUM_WORDS_PER_SECOND:
            reasons.append("very_low_word_density")
        if density > MAXIMUM_WORDS_PER_SECOND:
            reasons.append("very_high_word_density")
    if not digest:
        reasons.append("missing_audio_sha256")
    elif digest in seen_audio_hashes:
        reasons.append("duplicate_audio")

    audio = resolved_audio_path(dataset_root, row)
    if not audio.is_file() or audio.stat().st_size <= 44:
        reasons.append("missing_or_empty_audio")
    elif digest and sha256(audio) != digest:
        reasons.append("audio_sha256_mismatch")
    return reasons


@dataclass(frozen=True)
class SourceGroup:
    identifier: str
    language: str
    recordings: tuple[str, ...]
    speakers: tuple[str, ...]
    duration_seconds: float
    item_count: int


def source_groups(rows: list[dict[str, object]]) -> list[SourceGroup]:
    recordings: dict[str, list[dict[str, object]]] = {}
    for row in rows:
        recordings.setdefault(str(row["recording_id"]), []).append(row)

    parent = {recording: recording for recording in recordings}

    def find(recording: str) -> str:
        while parent[recording] != recording:
            parent[recording] = parent[parent[recording]]
            recording = parent[recording]
        return recording

    def union(first: str, second: str) -> None:
        first_root = find(first)
        second_root = find(second)
        if first_root != second_root:
            parent[max(first_root, second_root)] = min(first_root, second_root)

    owners: dict[str, str] = {}
    for recording, recording_rows in sorted(recordings.items()):
        for speaker in speaker_ids(recording_rows[0]):
            if speaker in owners:
                union(recording, owners[speaker])
            else:
                owners[speaker] = recording

    components: dict[str, list[str]] = {}
    for recording in recordings:
        components.setdefault(find(recording), []).append(recording)

    groups = []
    for component in components.values():
        component_rows = [
            row for recording in component for row in recordings[recording]
        ]
        languages = {str(row["requested_language"]) for row in component_rows}
        if len(languages) != 1:
            raise SystemExit(
                f"A shared-speaker group crosses languages: {sorted(component)}"
            )
        speakers = sorted(
            {
                speaker
                for row in component_rows
                for speaker in speaker_ids(row)
            }
        )
        recordings_in_group = tuple(sorted(component))
        groups.append(
            SourceGroup(
                identifier="+".join(recordings_in_group),
                language=languages.pop(),
                recordings=recordings_in_group,
                speakers=tuple(speakers),
                duration_seconds=sum(float(row["duration"]) for row in component_rows),
                item_count=len(component_rows),
            )
        )
    return sorted(groups, key=lambda group: group.identifier)


def assignment_score(
    groups: list[SourceGroup],
    assignment: tuple[int, ...],
) -> tuple[float, float, tuple[int, ...]]:
    total_duration = sum(group.duration_seconds for group in groups)
    total_count = sum(group.item_count for group in groups)
    duration_error = 0.0
    count_error = 0.0
    for split_index, split in enumerate(SPLITS):
        duration = sum(
            group.duration_seconds
            for group, assigned in zip(groups, assignment, strict=True)
            if assigned == split_index
        )
        count = sum(
            group.item_count
            for group, assigned in zip(groups, assignment, strict=True)
            if assigned == split_index
        )
        duration_error += (duration / total_duration - TARGET_RATIOS[split]) ** 2
        count_error += (count / total_count - TARGET_RATIOS[split]) ** 2
    return duration_error, count_error, assignment


def recording_splits_from_report(path: Path) -> dict[str, str]:
    report = json.loads(path.read_text(encoding="utf-8"))
    assignments: dict[str, str] = {}
    for group in report.get("groups", []):
        split = str(group.get("split", ""))
        if split not in SPLITS:
            raise SystemExit(f"Invalid split in base report: {split!r}")
        for recording in group.get("recordings", []):
            identifier = str(recording)
            previous = assignments.get(identifier)
            if previous is not None and previous != split:
                raise SystemExit(
                    f"Conflicting base splits for recording {identifier}: "
                    f"{previous} vs {split}"
                )
            assignments[identifier] = split
    if not assignments:
        raise SystemExit(f"Base split report contains no recordings: {path}")
    return assignments


def _greedy_assignment(
    groups: list[SourceGroup],
    fixed: dict[int, int],
) -> tuple[int, ...]:
    assignment = [-1] * len(groups)
    for index, split_index in fixed.items():
        assignment[index] = split_index

    movable = [index for index in range(len(groups)) if index not in fixed]
    movable.sort(
        key=lambda index: (
            -groups[index].duration_seconds,
            -groups[index].item_count,
            groups[index].identifier,
        )
    )
    missing_splits = [
        split_index
        for split_index in range(len(SPLITS))
        if split_index not in assignment
    ]
    if len(movable) < len(missing_splits):
        raise SystemExit("Fixed assignments leave too few groups to populate every split")
    for split_index in missing_splits:
        assignment[movable.pop(0)] = split_index

    for index in movable:
        candidates = []
        for split_index in range(len(SPLITS)):
            candidate = list(assignment)
            candidate[index] = split_index
            candidates.append(tuple(candidate))
        assignment = list(
            min(candidates, key=lambda value: assignment_score(groups, value))
        )

    movable_indices = {index for index in range(len(groups)) if index not in fixed}
    while True:
        current = tuple(assignment)
        current_score = assignment_score(groups, current)
        split_counts = Counter(assignment)
        candidates: list[tuple[int, ...]] = []
        for index in sorted(movable_indices):
            original_split = assignment[index]
            if split_counts[original_split] <= 1:
                continue
            for split_index in range(len(SPLITS)):
                if split_index == original_split:
                    continue
                candidate = list(assignment)
                candidate[index] = split_index
                candidates.append(tuple(candidate))
        if not candidates:
            return current
        best = min(candidates, key=lambda value: assignment_score(groups, value))
        if assignment_score(groups, best) >= current_score:
            return current
        assignment = list(best)


def assign_groups(
    groups: list[SourceGroup],
    fixed_recording_splits: dict[str, str] | None = None,
) -> dict[str, str]:
    fixed_recording_splits = fixed_recording_splits or {}
    assignments: dict[str, str] = {}
    for language in sorted(LANGUAGE_NAMES):
        language_groups = [group for group in groups if group.language == language]
        if len(language_groups) < 3:
            raise SystemExit(
                f"At least three speaker-disjoint groups are required for {language}."
            )
        fixed: dict[int, int] = {}
        for index, group in enumerate(language_groups):
            inherited = {
                fixed_recording_splits[recording]
                for recording in group.recordings
                if recording in fixed_recording_splits
            }
            if len(inherited) > 1:
                raise SystemExit(
                    "A shared-speaker group crosses frozen base splits: "
                    f"{group.identifier} -> {sorted(inherited)}"
                )
            if inherited:
                fixed[index] = SPLITS.index(inherited.pop())

        movable_indices = [
            index for index in range(len(language_groups)) if index not in fixed
        ]
        if len(movable_indices) <= 10:
            candidates = []
            for values in itertools.product(
                range(len(SPLITS)), repeat=len(movable_indices)
            ):
                assignment = [-1] * len(language_groups)
                for index, split_index in fixed.items():
                    assignment[index] = split_index
                for index, split_index in zip(movable_indices, values, strict=True):
                    assignment[index] = split_index
                candidate = tuple(assignment)
                if set(candidate) == set(range(len(SPLITS))):
                    candidates.append(candidate)
            if not candidates:
                raise SystemExit(f"Could not populate every split for {language}")
            best = min(
                candidates,
                key=lambda value: assignment_score(language_groups, value),
            )
        else:
            best = _greedy_assignment(language_groups, fixed)
        for group, split_index in zip(language_groups, best, strict=True):
            assignments[group.identifier] = SPLITS[split_index]
    return assignments


def split_rows(
    rows: list[dict[str, object]],
    groups: list[SourceGroup],
    assignments: dict[str, str],
) -> dict[str, list[dict[str, object]]]:
    recording_splits = {
        recording: assignments[group.identifier]
        for group in groups
        for recording in group.recordings
    }
    result = {split: [] for split in SPLITS}
    for row in rows:
        result[recording_splits[str(row["recording_id"])]].append(row)
    for split in SPLITS:
        result[split].sort(key=lambda row: str(row["id"]))
    return result


def packaged_audio_path(row: dict[str, object]) -> str:
    return f"audio/{row['recording_id']}/chunk_{int(row['chunk']):04d}.wav"


def nemo_row(row: dict[str, object]) -> dict[str, object]:
    return {
        "audio_path": packaged_audio_path(row),
        "duration": round(float(row["duration"]), 6),
        "id": row["id"],
        "language": row["requested_language"],
        "recording_id": row["recording_id"],
        "speaker_id": row["speaker_id"],
        "text": " ".join(str(row["raw"]).split()),
    }


def benchmark_manifest(
    test_rows: list[dict[str, object]],
    timestamp: str,
) -> dict[str, object]:
    manifest: dict[str, object] = {
        "benchmarkID": "voxol-wispr-teacher-heldout-v1",
        "frozenAt": timestamp,
        "items": [
            {
                "audioPath": packaged_audio_path(row),
                "durationSeconds": round(float(row["duration"]), 6),
                "id": row["id"],
                "language": LANGUAGE_NAMES[str(row["requested_language"])],
                "recordingID": row["recording_id"],
                "reference": {
                    "clean": " ".join(str(row["raw"]).split()),
                    "verbatim": " ".join(str(row["raw"]).split()),
                },
                "speakerID": row["speaker_id"],
                "split": "test",
            }
            for row in test_rows
        ],
        "normalizationVersion": "voxol-asr-v1",
        "schemaVersion": 1,
    }
    manifest["contentSHA256"] = hashlib.sha256(
        canonical_manifest_bytes(manifest)
    ).hexdigest()
    return manifest


def entities_for_split(
    rows: list[dict[str, object]],
) -> tuple[set[str], set[str]]:
    return (
        {str(row["recording_id"]) for row in rows},
        {speaker for row in rows for speaker in speaker_ids(row)},
    )


def split_summary(rows: list[dict[str, object]]) -> dict[str, object]:
    by_language = {}
    for language in sorted(LANGUAGE_NAMES):
        language_rows = [
            row for row in rows if str(row["requested_language"]) == language
        ]
        by_language[language] = {
            "durationHours": round(
                sum(float(row["duration"]) for row in language_rows) / 3600,
                6,
            ),
            "itemCount": len(language_rows),
            "recordingCount": len(
                {str(row["recording_id"]) for row in language_rows}
            ),
            "speakerCount": len(
                {speaker for row in language_rows for speaker in speaker_ids(row)}
            ),
        }
    return {
        "byLanguage": by_language,
        "durationHours": round(
            sum(float(row["duration"]) for row in rows) / 3600,
            6,
        ),
        "itemCount": len(rows),
        "recordingCount": len({str(row["recording_id"]) for row in rows}),
        "speakerCount": len(
            {speaker for row in rows for speaker in speaker_ids(row)}
        ),
    }


def add_file(
    archive: tarfile.TarFile,
    source: Path,
    archive_name: str,
) -> None:
    info = archive.gettarinfo(str(source), arcname=archive_name)
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    with source.open("rb") as stream:
        archive.addfile(info, stream)


def build_archive(
    dataset_root: Path,
    output_root: Path,
    rows: list[dict[str, object]],
    archive_path: Path,
) -> None:
    temporary = archive_path.with_suffix(archive_path.suffix + ".partial")
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_files = (
        "train.template.jsonl",
        "validation.template.jsonl",
        "test.template.jsonl",
        "test-manifest-frozen.json",
        "split-report.json",
        "excluded.jsonl",
        "package-files.json",
    )
    with temporary.open("wb") as output:
        with gzip.GzipFile(fileobj=output, mode="wb", compresslevel=1, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                for filename in metadata_files:
                    add_file(
                        archive,
                        output_root / filename,
                        f"{PACKAGE_ROOT}/{filename}",
                    )
                for row in sorted(rows, key=lambda item: str(item["id"])):
                    add_file(
                        archive,
                        resolved_audio_path(dataset_root, row),
                        f"{PACKAGE_ROOT}/{packaged_audio_path(row)}",
                    )
    os.replace(temporary, archive_path)
    digest = sha256(archive_path)
    archive_path.with_suffix(archive_path.suffix + ".sha256").write_text(
        f"{digest}  {archive_path.name}\n",
        encoding="utf-8",
    )


def prepare(
    input_manifest: Path,
    dataset_root: Path,
    output_root: Path,
    archive_path: Path | None,
    freeze_timestamp: str,
    base_split_report: Path | None = None,
    additional_corpora: list[tuple[Path, Path]] | None = None,
) -> dict[str, object]:
    corpora = [(input_manifest, dataset_root), *(additional_corpora or [])]
    source_rows = [
        row
        for manifest, root in corpora
        for row in read_corpus_rows(manifest, root)
    ]
    seen_ids: set[str] = set()
    seen_audio_hashes: set[str] = set()
    included = []
    excluded = []
    for row in source_rows:
        identifier = str(row.get("id", ""))
        if not identifier or identifier in seen_ids:
            raise SystemExit(f"Missing or duplicate item id: {identifier!r}")
        seen_ids.add(identifier)
        reasons = quality_reasons(dataset_root, row, seen_audio_hashes)
        if reasons:
            excluded.append(
                {
                    "duration": row.get("duration"),
                    "id": identifier,
                    "reasons": reasons,
                    "recording_id": row.get("recording_id"),
                    "requested_language": row.get("requested_language"),
                }
            )
            continue
        seen_audio_hashes.add(str(row["audio_sha256"]))
        included.append(row)

    groups = source_groups(included)
    fixed_recording_splits = (
        recording_splits_from_report(base_split_report)
        if base_split_report is not None
        else {}
    )
    assignments = assign_groups(groups, fixed_recording_splits)
    splits = split_rows(included, groups, assignments)
    overlap_checks = {}
    for first, second in itertools.combinations(SPLITS, 2):
        first_recordings, first_speakers = entities_for_split(splits[first])
        second_recordings, second_speakers = entities_for_split(splits[second])
        overlap_checks[f"{first}Vs{second}"] = {
            "recordings": sorted(first_recordings & second_recordings),
            "speakers": sorted(first_speakers & second_speakers),
        }
    if any(
        values["recordings"] or values["speakers"]
        for values in overlap_checks.values()
    ):
        raise RuntimeError(f"Split leakage detected: {overlap_checks}")

    output_root.mkdir(parents=True, exist_ok=True)
    for split in SPLITS:
        write_jsonl(
            output_root / f"{split}.template.jsonl",
            (nemo_row(row) for row in splits[split]),
        )
    write_json(
        output_root / "test-manifest-frozen.json",
        benchmark_manifest(splits["test"], freeze_timestamp),
    )
    write_jsonl(output_root / "excluded.jsonl", excluded)

    report = {
        "schemaVersion": SCHEMA_VERSION,
        "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "input": {
            "itemCount": len(source_rows),
            "manifest": str(input_manifest.resolve()),
            "manifestSHA256": sha256(input_manifest),
        },
        "inputs": [
            {
                "datasetRoot": str(root.resolve()),
                "itemCount": len(read_jsonl(manifest)),
                "manifest": str(manifest.resolve()),
                "manifestSHA256": sha256(manifest),
            }
            for manifest, root in corpora
        ],
        "filter": {
            "excludedByReason": dict(
                sorted(
                    Counter(
                        reason
                        for item in excluded
                        for reason in item["reasons"]
                    ).items()
                )
            ),
            "excludedItemCount": len(excluded),
            "includedItemCount": len(included),
            "maximumDurationSeconds": MAXIMUM_DURATION_SECONDS,
            "maximumWordsPerSecond": MAXIMUM_WORDS_PER_SECOND,
            "minimumDurationSeconds": MINIMUM_DURATION_SECONDS,
            "minimumWordsPerSecond": MINIMUM_WORDS_PER_SECOND,
        },
        "groups": [
            {
                "durationHours": round(group.duration_seconds / 3600, 6),
                "identifier": group.identifier,
                "itemCount": group.item_count,
                "language": group.language,
                "recordings": list(group.recordings),
                "speakers": list(group.speakers),
                "split": assignments[group.identifier],
            }
            for group in groups
        ],
        "labelContract": {
            "source": "Wispr raw transcript",
            "status": "product teacher target",
            "trainingUse": "audio-to-Wispr-raw ASR adaptation",
        },
        "splitPolicy": {
            "algorithm": (
                "exact_search_up_to_10_movable_groups_else_"
                "deterministic_greedy_local_search"
            ),
            "baseSplitReport": (
                str(base_split_report.resolve()) if base_split_report else None
            ),
            "baseSplitReportSHA256": (
                sha256(base_split_report) if base_split_report else None
            ),
            "frozenRecordingCount": len(fixed_recording_splits),
            "preserveExistingRecordings": bool(base_split_report),
        },
        "overlapChecks": overlap_checks,
        "splits": {
            split: split_summary(splits[split])
            for split in SPLITS
        },
        "targetRatios": TARGET_RATIOS,
    }
    write_json(output_root / "split-report.json", report)

    package_files = {
        "schemaVersion": SCHEMA_VERSION,
        "audio": [
            {
                "archivePath": packaged_audio_path(row),
                "bytes": resolved_audio_path(dataset_root, row).stat().st_size,
                "sha256": row["audio_sha256"],
            }
            for row in sorted(included, key=lambda item: str(item["id"]))
        ],
        "metadata": {
            filename: sha256(output_root / filename)
            for filename in (
                "train.template.jsonl",
                "validation.template.jsonl",
                "test.template.jsonl",
                "test-manifest-frozen.json",
                "split-report.json",
                "excluded.jsonl",
            )
        },
    }
    write_json(output_root / "package-files.json", package_files)
    if archive_path is not None:
        build_archive(dataset_root, output_root, included, archive_path)
        write_json(
            output_root / "archive-info.json",
            {
                "bytes": archive_path.stat().st_size,
                "path": str(archive_path.resolve()),
                "schemaVersion": SCHEMA_VERSION,
                "sha256": sha256(archive_path),
            },
        )
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--base-split-report", type=Path)
    parser.add_argument(
        "--additional-corpus",
        action="append",
        nargs=2,
        metavar=("MANIFEST", "DATASET_ROOT"),
        default=[],
        help="Add another corpus without copying its audio files.",
    )
    parser.add_argument("--freeze-timestamp", default=FREEZE_TIMESTAMP)
    arguments = parser.parse_args()
    report = prepare(
        arguments.input.resolve(),
        arguments.dataset_root.resolve(),
        arguments.output_root.resolve(),
        arguments.archive.resolve() if arguments.archive else None,
        arguments.freeze_timestamp,
        arguments.base_split_report.resolve() if arguments.base_split_report else None,
        [
            (Path(manifest).resolve(), Path(root).resolve())
            for manifest, root in arguments.additional_corpus
        ],
    )
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
