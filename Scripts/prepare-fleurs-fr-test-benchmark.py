#!/usr/bin/env python3
"""Prepare the complete official FLEURS fr_fr test split."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile


DATASET_REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
ARCHIVE_SHA256 = "d23690e102f373554d1b544cd2ff1e76e4fedeb04953c0b72751a1b7c518cfdd"
TSV_SHA256 = "5d06d338b242e00786fcf12c4c92008b9f399d5a5c872c91dca90572e7869c0d"


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def download(relative_path: str, expected_sha256: str, destination: Path) -> Path:
    if destination.exists():
        if digest(destination) != expected_sha256:
            raise SystemExit(f"Cached dataset checksum mismatch: {destination}")
        return destination

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".partial")
    url = (
        "https://huggingface.co/datasets/google/fleurs/resolve/"
        f"{DATASET_REVISION}/data/fr_fr/{relative_path}"
    )
    try:
        subprocess.run(
            [
                "/usr/bin/curl",
                "-fL",
                "--retry",
                "3",
                "--output",
                str(temporary),
                url,
            ],
            check=True,
        )
        if digest(temporary) != expected_sha256:
            raise SystemExit("Downloaded FLEURS checksum mismatch.")
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def load_rows(source: Path) -> list[dict]:
    rows = []
    with source.open(encoding="utf-8", newline="") as stream:
        for columns in csv.reader(stream, delimiter="\t", quoting=csv.QUOTE_NONE):
            if len(columns) != 7:
                raise SystemExit(f"Unexpected FLEURS TSV row in {source}")
            rows.append(
                {
                    "sentence_id": columns[0],
                    "audio_path": columns[1],
                    "clean": columns[2].strip(),
                    "verbatim": columns[3].strip(),
                    "gender": columns[6].lower(),
                }
            )
    return rows


def build_manifest(tsv: Path, archive_path: Path, output_root: Path) -> Path:
    audio_root = output_root / "audio"
    rows = load_rows(tsv)
    rows_by_audio_path = {row["audio_path"]: row for row in rows}
    extracted_audio_paths = set()
    with tarfile.open(archive_path, mode="r:gz") as archive:
        for member in archive:
            audio_path = Path(member.name).name
            row = rows_by_audio_path.get(audio_path)
            if row is None or not member.isfile():
                continue
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit(f"Could not read FLEURS audio: {audio_path}")
            identity = hashlib.sha256(
                (
                    f"fr_fr\0{row['sentence_id']}\0{row['audio_path']}"
                ).encode()
            ).hexdigest()[:12]
            identifier = f"fleurs-fr-test-{identity}"
            relative_audio_path = (
                Path("fleurs-fr-test") / f"{identifier}.wav"
            )
            destination = audio_root / relative_audio_path
            if not destination.exists():
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(source.read())
            extracted_audio_paths.add(audio_path)
    missing_audio = rows_by_audio_path.keys() - extracted_audio_paths
    if missing_audio:
        raise SystemExit("FLEURS archive is missing referenced audio files.")

    items = []
    for row in rows:
        identity = hashlib.sha256(
            f"fr_fr\0{row['sentence_id']}\0{row['audio_path']}".encode()
        ).hexdigest()[:12]
        identifier = f"fleurs-fr-test-{identity}"
        relative_audio_path = Path("fleurs-fr-test") / f"{identifier}.wav"
        items.append(
            {
                "id": identifier,
                "audioPath": relative_audio_path.as_posix(),
                "speakerID": "fleurs-fr-test-speaker-unknown",
                "sessionID": "fleurs-fr-test",
                "split": "blind",
                "language": "french",
                "microphone": "fleurs-source",
                "environment": "source-unknown",
                "tags": [
                    "public",
                    "fleurs",
                    "official-test",
                    "read-speech",
                    row["gender"],
                ],
                "reference": {
                    "verbatim": row["verbatim"],
                    "clean": row["clean"],
                    "criticalSpans": [],
                    "reviewed": True,
                },
            }
        )

    items.sort(key=lambda item: item["id"])
    manifest = {
        "schemaVersion": 1,
        "benchmarkID": f"voxol-fleurs-fr-test-{DATASET_REVISION[:12]}",
        "normalizationVersion": "voxol-asr-normalizer-v1",
        "items": items,
    }
    output_root.mkdir(parents=True, exist_ok=True)
    manifest_path = output_root / "manifest-unfrozen.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest_path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    arguments = parser.parse_args()
    tsv = download(
        "test.tsv",
        TSV_SHA256,
        arguments.cache_root / "fr_fr-test.tsv",
    )
    archive = download(
        "audio/test.tar.gz",
        ARCHIVE_SHA256,
        arguments.cache_root / "fr_fr-test.tar.gz",
    )
    print(build_manifest(tsv, archive, arguments.output_root))


if __name__ == "__main__":
    main()
