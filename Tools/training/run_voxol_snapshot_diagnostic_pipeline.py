#!/usr/bin/env python3
"""Prepare and run VoxoL's no-training Parakeet snapshot diagnostics."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import zipfile

from Tools.training import run_voxol_gpu_pipeline as base
from Tools.training.convert_nemo_manifest_to_benchmark import convert
from Tools.training.run_voxol_wispr_gpu_pipeline import extract_verified_dataset


PIPELINE_VERSION = "2026-07-29-snapshot-diagnostics-v1"
FREEZE_TIMESTAMP = "2026-07-29T00:00:00Z"


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--source-root", type=Path, required=True)
    result.add_argument("--work-root", type=Path, required=True)
    result.add_argument("--teacher-dataset", type=Path, required=True)
    result.add_argument("--teacher-dataset-sha256", required=True)
    result.add_argument("--research-archive", type=Path, required=True)
    result.add_argument("--research-archive-sha256", required=True)
    result.add_argument("--secondary-research-archive", type=Path)
    result.add_argument("--secondary-research-archive-sha256")
    result.add_argument("--batch-size", type=int, default=8)
    return result


def safe_digest(value: str, label: str) -> str:
    normalized = value.lower()
    if (
        len(normalized) != 64
        or any(character not in "0123456789abcdef" for character in normalized)
    ):
        raise SystemExit(f"{label} must be 64 lowercase hex digits.")
    return normalized


def extract_research_archive(
    archive_path: Path,
    expected_digest: str,
    work_root: Path,
) -> Path:
    if not archive_path.is_file() or archive_path.stat().st_size == 0:
        raise RuntimeError(f"Missing research archive: {archive_path}")
    actual_digest = base.sha256(archive_path)
    if actual_digest != expected_digest:
        raise RuntimeError(f"Research archive SHA-256 mismatch: {actual_digest}")
    destination = work_root / "data" / f"research-{actual_digest[:12]}"
    marker = destination / ".verified-archive-sha256"
    if marker.is_file() and marker.read_text(encoding="utf-8").strip() == actual_digest:
        return destination

    temporary = destination.with_name(destination.name + ".partial")
    if temporary.exists():
        shutil.rmtree(temporary)
    temporary.mkdir(parents=True)
    with zipfile.ZipFile(archive_path) as archive:
        for member in archive.infolist():
            relative = Path(member.filename)
            if (
                relative.is_absolute()
                or ".." in relative.parts
                or not relative.parts
                or relative.parts[0] != "VoxoL-Parakeet"
            ):
                raise RuntimeError(f"Unsafe research archive path: {member.filename}")
            if member.is_dir():
                continue
            output = temporary / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, output.open("wb") as target:
                shutil.copyfileobj(source, target, length=8 * 1024 * 1024)
    root = temporary / "VoxoL-Parakeet"
    checksums = root / "SHA256SUMS.txt"
    if not checksums.is_file():
        raise RuntimeError("Research archive is missing SHA256SUMS.txt.")
    for line in checksums.read_text(encoding="utf-8").splitlines():
        digest, relative_name = line.split("  ", 1)
        relative = Path(relative_name)
        if relative.parts[0] != "VoxoL-Parakeet":
            raise RuntimeError(f"Unsafe checksum path: {relative_name}")
        path = temporary / relative
        if not path.is_file() or base.sha256(path) != digest:
            raise RuntimeError(f"Invalid research archive member: {relative_name}")
    marker = root / ".verified-archive-sha256"
    marker.write_text(actual_digest + "\n", encoding="utf-8")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    os.replace(root, destination)
    shutil.rmtree(temporary)
    return destination


def freeze_manifest(
    source_root: Path,
    manifest: Path,
    output: Path,
    log: Path,
) -> None:
    base.run_source_script(
        source_root,
        "Tools/training/freeze_asr_manifest.py",
        [
            "--input",
            manifest,
            "--output",
            output,
            "--timestamp",
            FREEZE_TIMESTAMP,
        ],
        log,
    )


def archived_candidate_paths(research_root: Path) -> dict[str, Path]:
    completion = json.loads(
        (research_root / "candidates" / "training-complete.json").read_text(
            encoding="utf-8"
        )
    )
    digest = str(completion["sha256"])
    candidate = research_root / "candidates" / Path(str(completion["candidate"])).name
    if not candidate.is_file() or base.sha256(candidate) != digest:
        raise RuntimeError("The research candidate does not match its completion record.")
    label = f"candidate-{digest[:12]}"
    evaluation = research_root / "results" / "evaluation"
    paths = {
        "snapshot": candidate,
        "baselineTeacher": (
            evaluation
            / "baseline"
            / "wispr-teacher-heldout-predictions.jsonl"
        ),
        "candidateTeacher": (
            evaluation
            / label
            / "wispr-teacher-heldout-predictions.jsonl"
        ),
    }
    missing = [name for name, path in paths.items() if not path.is_file()]
    if missing:
        raise RuntimeError(f"Research archive is missing: {', '.join(missing)}")
    return paths


def build_archive(work_root: Path, run_token: str) -> Path:
    results = work_root / "diagnostics"
    export_root = work_root / "exports"
    export_root.mkdir(parents=True, exist_ok=True)
    archive_path = export_root / f"voxol-snapshot-diagnostics-{run_token}.zip"
    files = sorted(
        path for path in results.rglob("*")
        if path.is_file()
    )
    checksums = "\n".join(
        f"{base.sha256(path)}  VoxoL-Diagnostics/{path.relative_to(results).as_posix()}"
        for path in files
    ) + "\n"
    with zipfile.ZipFile(
        archive_path,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=6,
    ) as archive:
        for path in files:
            archive.write(
                path,
                f"VoxoL-Diagnostics/{path.relative_to(results).as_posix()}",
            )
        archive.writestr("VoxoL-Diagnostics/SHA256SUMS.txt", checksums)
    with zipfile.ZipFile(archive_path) as archive:
        if archive.testzip() is not None:
            raise RuntimeError("The diagnostic archive failed ZIP verification.")
    base.atomic_copy(
        archive_path,
        work_root / "results" / archive_path.name,
    )
    (work_root / "results" / "latest-export.txt").write_text(
        str(archive_path) + "\n",
        encoding="utf-8",
    )
    return archive_path


def main() -> None:
    arguments = parser().parse_args()
    if arguments.batch_size < 1:
        raise SystemExit("--batch-size must be positive.")
    teacher_digest = safe_digest(
        arguments.teacher_dataset_sha256,
        "--teacher-dataset-sha256",
    )
    research_digest = safe_digest(
        arguments.research_archive_sha256,
        "--research-archive-sha256",
    )
    if bool(arguments.secondary_research_archive) != bool(
        arguments.secondary_research_archive_sha256
    ):
        raise SystemExit(
            "--secondary-research-archive and its SHA-256 must be provided together."
        )
    secondary_digest = (
        safe_digest(
            str(arguments.secondary_research_archive_sha256),
            "--secondary-research-archive-sha256",
        )
        if arguments.secondary_research_archive
        else None
    )
    source_root = arguments.source_root.resolve()
    work_root = arguments.work_root.resolve()
    diagnostic_root = work_root / "diagnostics"
    log_root = diagnostic_root / "logs"
    result_root = work_root / "results"
    diagnostic_root.mkdir(parents=True, exist_ok=True)
    log_root.mkdir(parents=True, exist_ok=True)
    result_root.mkdir(parents=True, exist_ok=True)
    run_token = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    status_path = result_root / "status.json"

    try:
        base.atomic_json(
            status_path,
            {
                "schemaVersion": 1,
                "pipelineVersion": PIPELINE_VERSION,
                "state": "running",
                "stage": "verified extraction",
            },
        )
        teacher_root = extract_verified_dataset(
            arguments.teacher_dataset.resolve(),
            teacher_digest,
            work_root,
        )
        research_root = extract_research_archive(
            arguments.research_archive.resolve(),
            research_digest,
            work_root,
        )
        research_paths = archived_candidate_paths(research_root)
        secondary_paths = None
        if arguments.secondary_research_archive and secondary_digest:
            secondary_root = extract_research_archive(
                arguments.secondary_research_archive.resolve(),
                secondary_digest,
                work_root,
            )
            secondary_paths = archived_candidate_paths(secondary_root)

        teacher_dev = diagnostic_root / "benchmarks" / "teacher-validation"
        teacher_dev.mkdir(parents=True, exist_ok=True)
        convert(
            teacher_root / "validation.template.jsonl",
            teacher_dev / "manifest-unfrozen.json",
            "voxol-wispr-teacher-validation-v1",
            teacher_root,
        )
        freeze_manifest(
            source_root,
            teacher_dev / "manifest-unfrozen.json",
            teacher_dev / "manifest-frozen.json",
            log_root / "freeze-teacher-validation.log",
        )

        fleurs_root = work_root / "benchmarks" / "fleurs-dev"
        base.run_source_script(
            source_root,
            "Scripts/prepare-parakeet-fleurs-finetune.py",
            [
                "--cache-root",
                work_root / "cache" / "datasets" / "fleurs-dev",
                "--output-root",
                fleurs_root,
                "--split",
                "dev",
            ],
            log_root / "prepare-fleurs-dev.log",
        )
        convert(
            fleurs_root / "validation.jsonl",
            diagnostic_root / "benchmarks" / "fleurs-validation"
            / "manifest-unfrozen.json",
            "voxol-fleurs-validation-en_us-fr_fr-v1",
            fleurs_root,
        )
        freeze_manifest(
            source_root,
            diagnostic_root / "benchmarks" / "fleurs-validation"
            / "manifest-unfrozen.json",
            diagnostic_root / "benchmarks" / "fleurs-validation"
            / "manifest-frozen.json",
            log_root / "freeze-fleurs-validation.log",
        )

        configuration = {
            "schemaVersion": 1,
            "legacySnapshot": str(research_paths["snapshot"]),
            "benchmarks": [
                {
                    "id": "teacher-test-parity",
                    "role": "parity",
                    "manifest": str(teacher_root / "test-manifest-frozen.json"),
                    "audioRoot": str(teacher_root),
                    "archivedBaselinePredictions": str(
                        research_paths["baselineTeacher"]
                    ),
                    "archivedCandidatePredictions": str(
                        research_paths["candidateTeacher"]
                    ),
                },
                {
                    "id": "teacher-validation",
                    "role": "dev",
                    "manifest": str(teacher_dev / "manifest-frozen.json"),
                    "audioRoot": str(teacher_root),
                },
                {
                    "id": "fleurs-validation",
                    "role": "dev",
                    "manifest": str(
                        diagnostic_root / "benchmarks" / "fleurs-validation"
                        / "manifest-frozen.json"
                    ),
                    "audioRoot": str(fleurs_root),
                },
            ],
        }
        if secondary_paths is not None:
            configuration["secondarySnapshots"] = [
                {
                    "id": "three-epoch-diagnostic",
                    "legacySnapshot": str(secondary_paths["snapshot"]),
                    "archivedCandidatePredictions": str(
                        secondary_paths["candidateTeacher"]
                    ),
                }
            ]
        config_path = diagnostic_root / "diagnostic-config.json"
        base.atomic_json(config_path, configuration)
        base.atomic_json(
            status_path,
            {
                "schemaVersion": 1,
                "pipelineVersion": PIPELINE_VERSION,
                "state": "running",
                "stage": "A/A parity and post-hoc grid",
            },
        )
        base.run_source_script(
            source_root,
            "Tools/training/run_voxol_nemo_snapshot_diagnostics.py",
            [
                "--config",
                config_path,
                "--output-root",
                diagnostic_root / "results",
                "--batch-size",
                arguments.batch_size,
            ],
            log_root / "snapshot-diagnostics.log",
        )
        report = json.loads(
            (diagnostic_root / "results" / "diagnostic-report.json").read_text(
                encoding="utf-8"
            )
        )
        if not report.get("parityPassed"):
            raise RuntimeError("A/A parity failed.")
        archive = build_archive(work_root, run_token)
        base.atomic_json(
            status_path,
            {
                "schemaVersion": 1,
                "pipelineVersion": PIPELINE_VERSION,
                "state": "complete",
                "stage": "complete",
                "archive": str(archive),
                "archiveSHA256": base.sha256(archive),
            },
        )
        print(f"DOWNLOAD_THIS_FILE={archive}", flush=True)
    except BaseException as error:
        base.atomic_json(
            status_path,
            {
                "schemaVersion": 1,
                "pipelineVersion": PIPELINE_VERSION,
                "state": "failed",
                "error": str(error),
            },
        )
        if diagnostic_root.exists():
            try:
                archive = build_archive(work_root, run_token + "-failed")
                print(f"RECOVERY_ARCHIVE={archive}", flush=True)
            except BaseException as archive_error:
                print(f"Could not build recovery archive: {archive_error}")
        raise


if __name__ == "__main__":
    main()
