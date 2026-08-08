#!/usr/bin/env python3
"""Prepare a small, deterministic French/English FLEURS ASR benchmark."""

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
CONFIGURATIONS = {
    "en_us": {
        "language": "english",
        "archive_sha256": (
            "2658fda72f199e12676ecac9415094667a4e14e149b146e568ea00b2a2f0954c"
        ),
        "tsv_sha256": (
            "9d57ee7e91e9d4c92edb39f6bbea668ef8dc2a3ff96eb510d5580b2ad05d17ec"
        ),
    },
    "fr_fr": {
        "language": "french",
        "archive_sha256": (
            "f2f065dec3b02212e27151c51162d2213df55d0a8efc6b88e36992673ddf66e6"
        ),
        "tsv_sha256": (
            "3e0b792358c1cb4a426fe1c18fc1571d5406b390d738a2ed1bfd3c8b9d28de44"
        ),
    },
}


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def download(
    locale: str,
    relative_path: str,
    expected_sha256: str,
    destination: Path,
) -> Path:
    if destination.exists():
        if digest(destination) != expected_sha256:
            raise SystemExit(f"Cached dataset checksum mismatch: {destination}")
        return destination

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".partial")
    url = (
        "https://huggingface.co/datasets/google/fleurs/resolve/"
        f"{DATASET_REVISION}/data/{locale}/{relative_path}"
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
            raise SystemExit(f"Downloaded dataset checksum mismatch: {locale}")
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
                    "transcription": columns[2],
                    "gender": columns[6].lower(),
                }
            )
    return rows


def selected_rows(source: Path, locale: str, count: int) -> list[dict]:
    by_sentence: dict[str, list[dict]] = {}
    for row in load_rows(source):
        by_sentence.setdefault(row["sentence_id"], []).append(row)
    if count > len(by_sentence):
        raise SystemExit(
            f"Requested {count} {locale} sentences, but dev has {len(by_sentence)}."
        )

    def hashed(value: str) -> str:
        return hashlib.sha256(f"{locale}\0{value}".encode()).hexdigest()

    selected = []
    for sentence_id in sorted(by_sentence, key=hashed)[:count]:
        selected.append(
            min(by_sentence[sentence_id], key=lambda row: hashed(row["audio_path"]))
        )
    return selected


def convert_audio(audio: bytes, destination: Path) -> None:
    if destination.exists():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    source = destination.with_suffix(".source.wav")
    temporary = destination.with_suffix(".partial.wav")
    try:
        source.write_bytes(audio)
        subprocess.run(
            [
                "/usr/bin/afconvert",
                str(source),
                str(temporary),
                "-f",
                "WAVE",
                "-d",
                "LEI16@16000",
                "-c",
                "1",
            ],
            check=True,
        )
        os.replace(temporary, destination)
    finally:
        source.unlink(missing_ok=True)
        temporary.unlink(missing_ok=True)


def build_items(
    rows: list[dict],
    locale: str,
    archive_path: Path,
    audio_root: Path,
) -> list[dict]:
    configuration = CONFIGURATIONS[locale]
    with tarfile.open(archive_path, mode="r:gz") as archive:
        members = {
            Path(member.name).name: member
            for member in archive.getmembers()
            if member.isfile()
        }
        items = []
        for row in rows:
            member = members.get(row["audio_path"])
            if member is None:
                raise SystemExit(f"Missing FLEURS audio: {row['audio_path']}")
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit(f"Could not read FLEURS audio: {row['audio_path']}")
            identity = hashlib.sha256(
                f"{locale}\0{row['sentence_id']}\0{row['audio_path']}".encode()
            ).hexdigest()[:12]
            short_language = configuration["language"][:2]
            identifier = f"fleurs-{short_language}-{identity}"
            relative_audio_path = (
                Path("fleurs-lite") / locale / f"{identifier}.wav"
            )
            convert_audio(source.read(), audio_root / relative_audio_path)
            transcription = row["transcription"].strip()
            items.append(
                {
                    "id": identifier,
                    "audioPath": relative_audio_path.as_posix(),
                    "speakerID": f"fleurs-{locale}-speaker-unknown",
                    "sessionID": f"fleurs-{locale}-dev",
                    "split": "blind",
                    "language": configuration["language"],
                    "microphone": "fleurs-source",
                    "environment": "source-unknown",
                    "tags": [
                        "public",
                        "fleurs",
                        "read-speech",
                        row["gender"],
                    ],
                    "reference": {
                        "verbatim": transcription,
                        "clean": transcription,
                        "criticalSpans": [],
                        "reviewed": True,
                    },
                }
            )
    return items


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--items-per-language", type=int, default=50)
    arguments = parser.parse_args()
    if arguments.items_per_language < 1:
        raise SystemExit("--items-per-language must be positive.")

    audio_root = arguments.output_root / "audio"
    items = []
    for locale in sorted(CONFIGURATIONS):
        configuration = CONFIGURATIONS[locale]
        tsv = download(
            locale,
            "dev.tsv",
            configuration["tsv_sha256"],
            arguments.cache_root / f"{locale}-dev.tsv",
        )
        archive = download(
            locale,
            "audio/dev.tar.gz",
            configuration["archive_sha256"],
            arguments.cache_root / f"{locale}-dev.tar.gz",
        )
        rows = selected_rows(tsv, locale, arguments.items_per_language)
        items.extend(build_items(rows, locale, archive, audio_root))
    items.sort(key=lambda item: item["id"])

    manifest = {
        "schemaVersion": 1,
        "benchmarkID": (
            "voxol-fleurs-lite-"
            f"{arguments.items_per_language}-per-language-{DATASET_REVISION[:12]}"
        ),
        "normalizationVersion": "voxol-asr-normalizer-v1",
        "items": items,
    }
    arguments.output_root.mkdir(parents=True, exist_ok=True)
    manifest_path = arguments.output_root / "manifest-unfrozen.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(manifest_path)


if __name__ == "__main__":
    main()
