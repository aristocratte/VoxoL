#!/usr/bin/env python3
"""Run one human-reference benchmark across Parakeet, Gemini, and Wispr."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


REPO_ROOT = Path(__file__).resolve().parent.parent
PERSONAL_BUILDER_PATH = Path(__file__).with_name("build-personal-benchmark.py")
CONVERTER = REPO_ROOT / "Tools/benchmarks/convert_transcriber_records.py"
COMPARATOR = REPO_ROOT / "Tools/benchmarks/compare_transcriber_reports.py"
ADJUDICATOR = REPO_ROOT / "Tools/benchmarks/adjudicate_transcriber_predictions.py"
GEMINI_BATCH_COLLECTOR = REPO_ROOT / "Scripts/collect-gemini-app-batches.py"
SUPPORTED_SYSTEMS = {"parakeet", "gemini", "wispr"}


def load_personal_builder():
    specification = importlib.util.spec_from_file_location(
        "build_personal_benchmark",
        PERSONAL_BUILDER_PATH,
    )
    if not specification or not specification.loader:
        raise RuntimeError("Could not load the personal benchmark builder")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def run(command: list[str], environment: dict[str, str] | None = None) -> None:
    subprocess.run(command, cwd=REPO_ROOT, env=environment, check=True)


def runtime_roots() -> tuple[Path, Path]:
    manifest = json.loads((REPO_ROOT / "Models/manifests/runtime-models.json").read_text())
    revisions = {str(row["role"]): str(row["revision"]) for row in manifest["models"]}
    installed = Path.home() / "Library/Application Support/VoxoL/Models"
    return installed / "asr" / revisions["asr"], installed / "polisher" / revisions["polisher"]


def ensure_mlx_metallib(cli: Path) -> Path:
    destination = cli.with_name("mlx.metallib")
    if destination.is_file():
        return destination
    candidates = (
        REPO_ROOT
        / ".build/ReleaseBuild/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
        REPO_ROOT
        / ".build/DerivedData/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
    )
    source = next((path for path in candidates if path.is_file()), None)
    if source is None:
        raise SystemExit(
            "Qwen benchmark requires default.metallib from an Xcode VoxoL build"
        )
    shutil.copy2(source, destination)
    return destination


def write_manifest(path: Path, payload: dict[str, object]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if path.exists() and path.read_text(encoding="utf-8") != encoded:
        raise SystemExit(f"Existing run uses a different benchmark manifest: {path}")
    path.write_text(encoded, encoding="utf-8")


def adjudicated_benchmark_root(
    output_root: Path, manifest: dict[str, object]
) -> Path:
    encoded = json.dumps(
        manifest,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    fingerprint = hashlib.sha256(encoded).hexdigest()[:12]
    return output_root / "adjudicated-benchmarks" / fingerprint


def score(cli: Path, manifest: Path, predictions: Path, report: Path, items: Path) -> None:
    stamp = report.with_suffix(".inputs.json")
    inputs = {
        "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
        "predictions_sha256": hashlib.sha256(predictions.read_bytes()).hexdigest(),
    }
    if report.exists() and items.exists() and stamp.exists() and json.loads(stamp.read_text()) == inputs:
        return
    # The CLI refuses existing outputs. Publish replacements only after scoring succeeds.
    with tempfile.TemporaryDirectory(prefix="score-", dir=report.parent) as temporary:
        pending_report = Path(temporary) / "report.json"
        pending_items = Path(temporary) / "items.jsonl"
        run(
            [str(cli), "score", "--manifest", str(manifest),
             "--predictions", str(predictions), "--output", str(pending_report),
             "--per-item", str(pending_items)]
        )
        pending_report.replace(report)
        pending_items.replace(items)
    stamp.write_text(json.dumps(inputs, sort_keys=True) + "\n", encoding="utf-8")


def filter_predictions(source: Path, destination: Path, accepted_ids: set[str]) -> None:
    rows = [
        json.loads(line)
        for line in source.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    selected = [row for row in rows if str(row.get("id", "")) in accepted_ids]
    destination.write_text(
        "".join(
            json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            for row in selected
        ),
        encoding="utf-8",
    )


def predictions_cover(path: Path, required_ids: set[str]) -> bool:
    if not path.is_file():
        return False
    try:
        found = {
            str(json.loads(line).get("id", ""))
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        }
    except (json.JSONDecodeError, OSError):
        return False
    return required_ids.issubset(found)


def gemini_predictions_cover(path: Path, manifest: Path, audio_root: Path) -> bool:
    specification = importlib.util.spec_from_file_location("gemini_batch_cache", GEMINI_BATCH_COLLECTOR)
    assert specification and specification.loader
    collector = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(collector)
    expected = {
        str(item["id"]): collector.sha256(audio_root / str(item["audioPath"]))
        for item in json.loads(manifest.read_text())["items"]
    }
    return set(expected).issubset(collector.load_cached_rows(path, expected))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument(
        "--personal-root",
        type=Path,
        default=Path.home() / "Library/Application Support/VoxoL/PersonalBenchmark",
    )
    result.add_argument("--output-root", type=Path)
    result.add_argument("--limit", type=int, default=0, help="Use only the newest N captured sessions.")
    result.add_argument(
        "--systems",
        default="parakeet,gemini,wispr",
        help="Comma-separated subset of parakeet,gemini,wispr.",
    )
    result.add_argument("--cli", type=Path, default=REPO_ROOT / ".build/release/voxol-asr-benchmark")
    result.add_argument("--model-root", type=Path)
    result.add_argument("--polisher-root", type=Path)
    result.add_argument("--gemini-root", type=Path, default=Path.home() / "Documents/stt-factory")
    result.add_argument(
        "--gemini-transport",
        choices=("batch-app", "app"),
        default="batch-app",
        help="Use background multi-file chats by default; app preserves the legacy one-file flow.",
    )
    result.add_argument("--gemini-batch-size", type=int, default=4)
    result.add_argument("--gemini-process-timeout", type=int, default=300)
    result.add_argument("--wispr-script", type=Path, default=REPO_ROOT / "Scripts/wispr-transcribe.sh")
    result.add_argument("--vocabulary", type=Path, help="One preferred spelling per line.")
    result.add_argument(
        "--language",
        default="auto",
        choices=("fr", "en", "auto"),
        help="Expected language for the personal corpus; genuine language switches are preserved.",
    )
    result.add_argument(
        "--references-reviewed",
        action="store_true",
        help="Assert that every selected corrected.txt was checked by a human.",
    )
    result.add_argument(
        "--adjudicate",
        action="store_true",
        help="Build auditable ensemble references after all three systems finish.",
    )
    result.add_argument(
        "--apply-adjudication",
        action="store_true",
        help="Write accepted ensemble references back to their captured sessions.",
    )
    result.add_argument(
        "--adjudication-decisions",
        type=Path,
        help="Optional JSONL context decisions for ambiguous items.",
    )
    result.add_argument("--prepare-only", action="store_true")
    return result


def main() -> int:
    arguments = parser().parse_args()
    systems = [value.strip() for value in arguments.systems.split(",") if value.strip()]
    unknown = set(systems) - SUPPORTED_SYSTEMS
    if not systems or unknown:
        raise SystemExit(f"Unsupported systems: {', '.join(sorted(unknown)) or '(none)'}")
    if arguments.limit < 0:
        raise SystemExit("--limit must be zero or positive")

    builder = load_personal_builder()
    sessions = builder.sessions_in(arguments.personal_root)
    if arguments.limit:
        sessions = sessions[-arguments.limit :]
    if not sessions:
        raise SystemExit("No personal benchmark sessions were found")

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_root = arguments.output_root or arguments.personal_root / "head-to-head" / timestamp
    output_root.mkdir(parents=True, exist_ok=True)
    source_manifest = output_root / "manifest-unfrozen.json"
    frozen_manifest = output_root / "manifest-frozen.json"
    if source_manifest.exists():
        existing_manifest = json.loads(source_manifest.read_text(encoding="utf-8"))
        existing_ids = [str(item["id"]) for item in existing_manifest.get("items", [])]
        available_by_id = {
            session["name"]: session
            for session in builder.sessions_in(arguments.personal_root)
        }
        missing_ids = [identifier for identifier in existing_ids if identifier not in available_by_id]
        if missing_ids:
            raise SystemExit(
                "Existing run references missing sessions: " + ", ".join(missing_ids)
            )
        sessions = [available_by_id[identifier] for identifier in existing_ids]
    else:
        write_manifest(source_manifest, builder.manifest_for(sessions))

    if not arguments.cli.exists():
        run(["swift", "build", "-c", "release", "--product", "voxol-asr-benchmark"])
    if not frozen_manifest.exists():
        run(
            [
                str(arguments.cli),
                "freeze",
                "--manifest",
                str(source_manifest),
                "--audio-root",
                str(arguments.personal_root),
                "--output",
                str(frozen_manifest),
            ]
        )

    corrected_count = sum(
        session["clean_reference"] != session["meta"].get("finalText", "").strip()
        for session in sessions
    )
    reference_tiers = Counter(str(session["reference_tier"]) for session in sessions)
    all_human_reviewed = arguments.references_reviewed or all(
        session["human_reviewed"] for session in sessions
    )
    all_adjudicated = all(session["reference_ready"] for session in sessions)
    if all_human_reviewed:
        reference_status = "human-reviewed"
    elif all_adjudicated:
        reference_status = "ensemble-adjudicated"
    else:
        reference_status = "unverified-capture"
    metadata_path = output_root / "run-metadata.json"
    existing_metadata = (
        json.loads(metadata_path.read_text(encoding="utf-8"))
        if metadata_path.exists()
        else {}
    )
    run_metadata = {
        "schema_version": 1,
        "created_at": existing_metadata.get("created_at", timestamp),
        "systems": systems,
        "session_ids": [session["name"] for session in sessions],
        "item_count": len(sessions),
        "manually_changed_reference_count": corrected_count,
        "references_reviewed": all_human_reviewed,
        "references_adjudicated": all_adjudicated,
        "reference_tiers": dict(sorted(reference_tiers.items())),
        "reference_status": reference_status,
        "language": arguments.language,
        "gemini_transport": arguments.gemini_transport if "gemini" in systems else None,
        "interpretation": (
            "candidate-gate"
            if all_human_reviewed and len(sessions) >= 50
            else "silver-diagnostic" if all_adjudicated else "diagnostic"
        ),
        "status": "running",
    }
    metadata_path.write_text(
        json.dumps(run_metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"Prepared {len(sessions)} sessions ({corrected_count} manually changed references) at {output_root}"
    )
    if arguments.prepare_only:
        run_metadata["status"] = "prepared"
        metadata_path.write_text(
            json.dumps(run_metadata, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return 0

    default_asr, default_polisher = runtime_roots()
    model_root = arguments.model_root or default_asr
    polisher_root = arguments.polisher_root or default_polisher
    audio_paths = [str(arguments.personal_root / session["audioPath"]) for session in sessions]
    vocabulary = ""
    if arguments.vocabulary:
        vocabulary = ", ".join(
            line.strip()
            for line in arguments.vocabulary.read_text(encoding="utf-8").splitlines()
            if line.strip()
        )

    reports: list[tuple[str, Path]] = []
    if "parakeet" in systems:
        if not model_root.is_dir() or not polisher_root.is_dir():
            raise SystemExit("The installed Parakeet or Qwen runtime is missing")
        ensure_mlx_metallib(arguments.cli)
        predictions = output_root / "parakeet-predictions.jsonl"
        command = [
            str(arguments.cli),
            "run-parakeet",
            "--manifest",
            str(frozen_manifest),
            "--audio-root",
            str(arguments.personal_root),
            "--model-root",
            str(model_root),
            "--polisher-root",
            str(polisher_root),
            "--compute-units",
            "all",
            "--output",
            str(predictions),
        ]
        if predictions.exists():
            command.append("--resume")
        if arguments.vocabulary:
            command.extend(["--vocabulary", str(arguments.vocabulary)])
        run(command)
        report = output_root / "parakeet-report.json"
        score(arguments.cli, frozen_manifest, predictions, report, output_root / "parakeet-items.jsonl")
        reports.append(("Parakeet + Qwen", report))

    if "gemini" in systems:
        predictions = output_root / "gemini-predictions.jsonl"
        gemini_cached = gemini_predictions_cover(predictions, frozen_manifest, arguments.personal_root)
        signed_app = arguments.gemini_root / "dist/Gemini Transcriber.app"
        signed_executable = signed_app / "Contents/MacOS/Gemini Transcriber"
        if signed_executable.is_file() and not gemini_cached:
            subprocess.run(
                ["/usr/bin/killall", "Gemini Transcriber"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            for _ in range(20):
                if subprocess.run(
                    ["/usr/bin/pgrep", "-x", "Gemini Transcriber"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                ).returncode != 0:
                    break
                time.sleep(0.1)
            run(["open", "-n", "-g", str(signed_app)])
            time.sleep(2)
        dataset = output_root / "gemini/dataset"
        environment = os.environ.copy()
        environment.pop("GEMINI_BRIDGE_HOSTED", None)
        environment.update(
            {
                "GEMINI_DATASET_DIR": str(dataset),
                "GEMINI_TRANSCRIPTION_MODE": "training",
                "GEMINI_TRANSPORT": "app",
                "GEMINI_APP_MODEL": "3.7 Flash",
                "GEMINI_APP_FORCE_FAST": "1",
                "GEMINI_SEGMENTATION": "utterance",
                "GEMINI_SPEAKER_ID": "owner",
                "GEMINI_SESSION_ID": output_root.name,
                "GEMINI_LANG": arguments.language,
                "GEMINI_VOCABULARY": vocabulary,
            }
        )
        if signed_executable.is_file():
            environment["GEMINI_BRIDGE_EXECUTABLE"] = str(signed_executable)
            environment["GEMINI_BRIDGE_HOSTED"] = "1"
        if gemini_cached:
            print(f"Gemini cache complete: {predictions}")
        elif arguments.gemini_transport == "batch-app":
            if not signed_executable.is_file():
                raise SystemExit(f"Signed Gemini batch bridge is missing: {signed_executable}")
            run(
                [
                    sys.executable,
                    str(GEMINI_BATCH_COLLECTOR),
                    "--manifest",
                    str(frozen_manifest),
                    "--audio-root",
                    str(arguments.personal_root),
                    "--records",
                    str(dataset / "records"),
                    "--output",
                    str(predictions),
                    "--bridge",
                    str(signed_executable),
                    *(["--alignment-reference", str(output_root / "parakeet-predictions.jsonl")]
                      if (output_root / "parakeet-predictions.jsonl").is_file() else []),
                    "--batch-size",
                    str(arguments.gemini_batch_size),
                    "--timeout",
                    str(int(arguments.gemini_process_timeout)),
                    "--language",
                    arguments.language,
                    "--vocabulary",
                    vocabulary,
                ]
            )
        else:
            collector = arguments.gemini_root / "gemini-transcribe.sh"
            if not collector.exists():
                raise SystemExit(f"Gemini collector is missing: {collector}")
            run([str(collector), *audio_paths], environment)
            run(
                [
                    sys.executable,
                    str(CONVERTER),
                    "--manifest",
                    str(frozen_manifest),
                    "--audio-root",
                    str(arguments.personal_root),
                    "--records",
                    str(dataset / "records"),
                    "--capture-profile",
                    f"training-utterance-v5-app-fast-lang-{arguments.language}",
                    "--output",
                    str(predictions),
                ]
            )
        report = output_root / "gemini-report.json"
        score(arguments.cli, frozen_manifest, predictions, report, output_root / "gemini-items.jsonl")
        reports.append(("Gemini", report))

    if "wispr" in systems:
        dataset = output_root / "wispr/dataset"
        environment = os.environ.copy()
        environment.update(
            {
                "WISPR_DATASET_DIR": str(dataset),
                "WISPR_SPEAKER_ID": "owner",
                "WISPR_SESSION_ID": output_root.name,
                "WISPR_LANG": arguments.language,
            }
        )
        run([str(arguments.wispr_script), *audio_paths], environment)
        predictions = output_root / "wispr-predictions.jsonl"
        run(
            [
                sys.executable,
                str(CONVERTER),
                "--manifest",
                str(frozen_manifest),
                "--audio-root",
                str(arguments.personal_root),
                "--records",
                str(dataset / "records"),
                "--output",
                str(predictions),
            ]
        )
        report = output_root / "wispr-report.json"
        score(arguments.cli, frozen_manifest, predictions, report, output_root / "wispr-items.jsonl")
        reports.append(("Wispr Flow", report))

    comparison = output_root / "comparison.json"
    comparison_markdown = output_root / "comparison.md"
    compare_command = [sys.executable, str(COMPARATOR)]
    for name, report in reports:
        compare_command.extend(["--report", f"{name}={report}"])
    compare_command.extend(["--output", str(comparison), "--markdown", str(comparison_markdown)])
    run(compare_command)
    if arguments.apply_adjudication:
        arguments.adjudicate = True
    if arguments.adjudicate:
        if set(systems) != SUPPORTED_SYSTEMS:
            raise SystemExit("Adjudication requires parakeet, gemini, and wispr")
        adjudication_output = output_root / "adjudication"
        adjudication_command = [
            sys.executable,
            str(ADJUDICATOR),
            "--manifest",
            str(frozen_manifest),
            "--parakeet",
            str(output_root / "parakeet-predictions.jsonl"),
            "--gemini",
            str(output_root / "gemini-predictions.jsonl"),
            "--wispr",
            str(output_root / "wispr-predictions.jsonl"),
            "--personal-root",
            str(arguments.personal_root),
            "--output",
            str(adjudication_output),
        ]
        if arguments.adjudication_decisions:
            adjudication_command.extend(["--decisions", str(arguments.adjudication_decisions)])
        if arguments.apply_adjudication:
            adjudication_command.append("--apply")
        run(adjudication_command)
        run_metadata["adjudication"] = json.loads(
            (adjudication_output / "summary.json").read_text(encoding="utf-8")
        )
        run_metadata["adjudication"]["output"] = str(adjudication_output)
        if arguments.apply_adjudication:
            reviews = [
                json.loads(line)
                for line in (adjudication_output / "review.jsonl")
                .read_text(encoding="utf-8")
                .splitlines()
                if line.strip()
            ]
            accepted_ids = {
                str(review["id"])
                for review in reviews
                if review.get("status") == "accepted"
            }
            refreshed_by_id = {
                session["name"]: session
                for session in builder.sessions_in(arguments.personal_root)
            }
            accepted_sessions = [
                refreshed_by_id[session["name"]]
                for session in sessions
                if session["name"] in accepted_ids
                and session["name"] in refreshed_by_id
                and refreshed_by_id[session["name"]]["reference_ready"]
            ]
            if accepted_sessions:
                accepted_manifest = builder.manifest_for(accepted_sessions)
                accepted_root = adjudicated_benchmark_root(output_root, accepted_manifest)
                accepted_root.mkdir(parents=True, exist_ok=True)
                accepted_source = accepted_root / "manifest-unfrozen.json"
                accepted_frozen = accepted_root / "manifest-frozen.json"
                write_manifest(accepted_source, accepted_manifest)
                if not accepted_frozen.exists():
                    run(
                        [
                            str(arguments.cli),
                            "freeze",
                            "--manifest",
                            str(accepted_source),
                            "--audio-root",
                            str(arguments.personal_root),
                            "--output",
                            str(accepted_frozen),
                        ]
                    )
                accepted_reports: list[tuple[str, Path]] = []
                for system, label in (
                    ("parakeet", "Parakeet + Qwen"),
                    ("gemini", "Gemini"),
                    ("wispr", "Wispr Flow"),
                ):
                    accepted_predictions = accepted_root / f"{system}-predictions.jsonl"
                    filter_predictions(
                        output_root / f"{system}-predictions.jsonl",
                        accepted_predictions,
                        accepted_ids,
                    )
                    accepted_report = accepted_root / f"{system}-report.json"
                    score(
                        arguments.cli,
                        accepted_frozen,
                        accepted_predictions,
                        accepted_report,
                        accepted_root / f"{system}-items.jsonl",
                    )
                    accepted_reports.append((label, accepted_report))
                accepted_comparison = accepted_root / "comparison.json"
                accepted_markdown = accepted_root / "comparison.md"
                accepted_compare_command = [sys.executable, str(COMPARATOR)]
                for name, report in accepted_reports:
                    accepted_compare_command.extend(["--report", f"{name}={report}"])
                accepted_compare_command.extend(
                    [
                        "--output",
                        str(accepted_comparison),
                        "--markdown",
                        str(accepted_markdown),
                    ]
                )
                run(accepted_compare_command)
                run_metadata["adjudicated_benchmark"] = {
                    "interpretation": "silver-diagnostic",
                    "item_count": len(accepted_sessions),
                    "manifest": str(accepted_frozen),
                    "comparison": str(accepted_comparison),
                    "markdown": str(accepted_markdown),
                }
            else:
                run_metadata["adjudicated_benchmark"] = {
                    "interpretation": "empty",
                    "item_count": 0,
                }
    run_metadata["status"] = "complete"
    metadata_path.write_text(
        json.dumps(run_metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Head-to-head complete: {comparison_markdown}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
