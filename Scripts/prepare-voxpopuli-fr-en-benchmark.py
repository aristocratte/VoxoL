#!/usr/bin/env python3
"""Prepare a pinned, speaker-diverse VoxPopuli French/English test subset."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

import pyarrow.parquet as pq


DATASET_REVISION = "930c9a00c3aeff80a6b9fbb1175bcd07bf751cf8"
SAMPLE_COUNT = 1_000
MAXIMUM_PER_SPEAKER = 4
CONFIGURATIONS = {
    "en": {
        "bytes": 936_355_804,
        "language": "english",
        "rows": 1_842,
    },
    "fr": {
        "bytes": 957_942_040,
        "language": "french",
        "rows": 1_742,
    },
}


def source_url(configuration: str) -> str:
    return (
        "https://huggingface.co/datasets/facebook/voxpopuli/resolve/"
        f"{DATASET_REVISION}/{configuration}/test/0000.parquet"
    )


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def validate_parquet(path: Path, expected_rows: int) -> None:
    metadata = pq.ParquetFile(path).metadata
    if metadata.num_rows != expected_rows:
        raise RuntimeError(
            f"Unexpected VoxPopuli row count in {path}: "
            f"{metadata.num_rows}, expected {expected_rows}"
        )


def download(configuration: str, destination: Path) -> Path:
    expected_bytes = int(CONFIGURATIONS[configuration]["bytes"])
    expected_rows = int(CONFIGURATIONS[configuration]["rows"])
    if destination.is_file() and destination.stat().st_size == expected_bytes:
        validate_parquet(destination, expected_rows)
        print(f"[dataset-cache] Verified {destination}", flush=True)
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".partial")
    if partial.is_file() and partial.stat().st_size > expected_bytes:
        partial.unlink()
    curl = shutil.which("curl")
    if curl is None:
        raise SystemExit("curl is required to download VoxPopuli.")
    subprocess.run(
        [
            curl,
            "--fail",
            "--location",
            "--show-error",
            "--retry",
            "5",
            "--retry-delay",
            "2",
            "--retry-all-errors",
            "--connect-timeout",
            "30",
            "--continue-at",
            "-",
            "--output",
            str(partial),
            source_url(configuration),
        ],
        check=True,
    )
    if partial.stat().st_size != expected_bytes:
        raise SystemExit(
            f"Incomplete VoxPopuli download: {partial.stat().st_size} bytes; "
            f"expected {expected_bytes}"
        )
    validate_parquet(partial, expected_rows)
    os.replace(partial, destination)
    return destination


def metadata_rows(path: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    parquet = pq.ParquetFile(path, memory_map=True)
    columns = [
        "audio_id",
        "raw_text",
        "normalized_text",
        "speaker_id",
        "gender",
        "is_gold_transcript",
        "accent",
    ]
    for batch in parquet.iter_batches(
        batch_size=2_048,
        columns=columns,
        use_threads=False,
    ):
        for row in batch.to_pylist():
            identifier = str(row.get("audio_id") or "").strip()
            clean = str(row.get("normalized_text") or "").strip()
            if identifier and clean and row.get("is_gold_transcript") is not False:
                rows.append(row)
    return rows


def select_rows(
    rows: list[dict[str, object]],
    configuration: str,
    limit: int = SAMPLE_COUNT,
) -> list[dict[str, object]]:
    ranked = sorted(
        rows,
        key=lambda row: hashlib.sha256(
            f"{configuration}\0{row['audio_id']}".encode()
        ).hexdigest(),
    )
    selected: list[dict[str, object]] = []
    selected_ids: set[str] = set()
    speakers: Counter[str] = Counter()
    for row in ranked:
        speaker = str(row.get("speaker_id") or "unknown")
        if speakers[speaker] >= MAXIMUM_PER_SPEAKER:
            continue
        identifier = str(row["audio_id"])
        selected.append(row)
        selected_ids.add(identifier)
        speakers[speaker] += 1
        if len(selected) == limit:
            return selected
    for row in ranked:
        identifier = str(row["audio_id"])
        if identifier in selected_ids:
            continue
        selected.append(row)
        if len(selected) == limit:
            break
    if len(selected) != min(limit, len(rows)):
        raise RuntimeError(f"Could not select VoxPopuli {configuration} rows")
    return selected


def extract_items(
    parquet_path: Path,
    configuration: str,
    selected: list[dict[str, object]],
    output_root: Path,
) -> list[dict[str, object]]:
    configuration_data = CONFIGURATIONS[configuration]
    by_id = {str(row["audio_id"]): row for row in selected}
    emitted: set[str] = set()
    items: list[dict[str, object]] = []
    parquet = pq.ParquetFile(parquet_path, memory_map=True)
    columns = [
        "audio_id",
        "audio",
        "raw_text",
        "normalized_text",
        "speaker_id",
        "gender",
        "accent",
    ]
    for batch in parquet.iter_batches(
        batch_size=32,
        columns=columns,
        use_threads=False,
    ):
        for row in batch.to_pylist():
            audio_id = str(row.get("audio_id") or "")
            if audio_id not in by_id:
                continue
            audio = row.get("audio")
            if not isinstance(audio, dict) or not audio.get("bytes"):
                raise RuntimeError(f"Missing VoxPopuli audio bytes: {audio_id}")
            audio_bytes = bytes(audio["bytes"])
            suffix = Path(str(audio.get("path") or "audio.wav")).suffix.lower()
            if suffix not in {".wav", ".flac", ".mp3", ".ogg"}:
                suffix = ".wav"
            identity = hashlib.sha256(
                f"{configuration}\0{audio_id}".encode()
            ).hexdigest()[:16]
            identifier = f"voxpopuli-{configuration}-test-{identity}"
            relative = Path(f"voxpopuli-{configuration}-test") / f"{identifier}{suffix}"
            destination = output_root / "audio" / relative
            if not destination.is_file() or destination.stat().st_size != len(audio_bytes):
                destination.parent.mkdir(parents=True, exist_ok=True)
                temporary = destination.with_suffix(destination.suffix + ".partial")
                temporary.write_bytes(audio_bytes)
                os.replace(temporary, destination)
            speaker = str(row.get("speaker_id") or "unknown")
            accent = str(row.get("accent") or "none")
            gender = str(row.get("gender") or "unknown")
            clean = str(row.get("normalized_text") or "").strip()
            verbatim = str(row.get("raw_text") or clean).strip()
            items.append(
                {
                    "audioPath": relative.as_posix(),
                    "environment": "parliamentary-speech",
                    "id": identifier,
                    "language": configuration_data["language"],
                    "microphone": "voxpopuli-source",
                    "reference": {
                        "clean": clean,
                        "criticalSpans": [],
                        "reviewed": True,
                        "verbatim": verbatim,
                    },
                    "sessionID": f"voxpopuli-{configuration}-test",
                    "speakerID": f"voxpopuli-{configuration}-{speaker}",
                    "split": "blind",
                    "tags": [
                        "public",
                        "voxpopuli",
                        "official-test",
                        "parliamentary-speech",
                        f"accent-{accent}",
                        f"gender-{gender}",
                    ],
                }
            )
            emitted.add(audio_id)
    missing = sorted(set(by_id) - emitted)
    if missing:
        raise RuntimeError(f"VoxPopuli extraction missed IDs: {missing[:3]}")
    return items


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--sample-count", type=int, default=SAMPLE_COUNT)
    arguments = parser.parse_args()
    if arguments.sample_count <= 0:
        raise SystemExit("--sample-count must be positive")

    items: list[dict[str, object]] = []
    sources: dict[str, dict[str, object]] = {}
    for configuration in sorted(CONFIGURATIONS):
        parquet_path = download(
            configuration,
            arguments.cache_root / f"{configuration}-test-0000.parquet",
        )
        selected = select_rows(
            metadata_rows(parquet_path),
            configuration,
            arguments.sample_count,
        )
        items.extend(
            extract_items(
                parquet_path,
                configuration,
                selected,
                arguments.output_root,
            )
        )
        sources[parquet_path.name] = {
            "bytes": parquet_path.stat().st_size,
            "sha256": digest(parquet_path),
            "source": source_url(configuration),
        }

    items.sort(key=lambda item: str(item["id"]))
    manifest = {
        "benchmarkID": f"voxol-voxpopuli-fr-en-test-{DATASET_REVISION[:12]}-n{arguments.sample_count}",
        "items": items,
        "normalizationVersion": "voxol-asr-normalizer-v1",
        "schemaVersion": 1,
    }
    arguments.output_root.mkdir(parents=True, exist_ok=True)
    (arguments.output_root / "manifest-unfrozen.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (arguments.output_root / "source-checksums.json").write_text(
        json.dumps(sources, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (arguments.output_root / "provenance.json").write_text(
        json.dumps(
            {
                "dataset_revision": DATASET_REVISION,
                "maximum_per_speaker_before_fill": MAXIMUM_PER_SPEAKER,
                "sample_count_per_language": arguments.sample_count,
                "selection": "lowest deterministic SHA-256 score after a four-item speaker cap",
                "source": "https://huggingface.co/datasets/facebook/voxpopuli",
                "training_use": False,
            },
            indent=2,
            sort_keys=True,
        ) + "\n",
        encoding="utf-8",
    )
    print(arguments.output_root / "manifest-unfrozen.json")


if __name__ == "__main__":
    main()
