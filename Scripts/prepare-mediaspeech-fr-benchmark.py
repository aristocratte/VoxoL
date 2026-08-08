#!/usr/bin/env python3
"""Prepare the complete official OpenSLR MediaSpeech French corpus."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import tarfile

import resumable_dataset_download


ARCHIVE_URL = "https://www.openslr.org/resources/108/FR.tgz"
ARCHIVE_SHA256 = "edefa83dab25acc2c99d18605a9362e0d7d28953435f128efaabf3bbda79f390"


def download(destination: Path) -> Path:
    return resumable_dataset_download.download_verified(
        ARCHIVE_URL,
        ARCHIVE_SHA256,
        destination,
    )


def build_manifest(archive_path: Path, output_root: Path) -> Path:
    audio_root = output_root / "audio"
    transcriptions = {}
    audio_identifiers = set()
    with tarfile.open(archive_path, mode="r:gz") as archive:
        for member in archive:
            if not member.isfile():
                continue
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit(f"Could not read MediaSpeech item: {member.name}")
            source_identifier = Path(member.name).stem
            if member.name.endswith(".txt"):
                transcription = source.read().decode("utf-8").strip()
                if not transcription:
                    raise SystemExit(f"Empty MediaSpeech transcript: {member.name}")
                transcriptions[source_identifier] = transcription
                continue
            if not member.name.endswith(".flac"):
                continue
            audio_identifiers.add(source_identifier)
            relative_audio_path = Path("mediaspeech-fr") / f"{source_identifier}.flac"
            destination = audio_root / relative_audio_path
            if not destination.exists() or destination.stat().st_size != member.size:
                destination.parent.mkdir(parents=True, exist_ok=True)
                temporary = destination.with_suffix(".flac.partial")
                with temporary.open("wb") as output:
                    shutil.copyfileobj(source, output)
                if temporary.stat().st_size != member.size:
                    temporary.unlink(missing_ok=True)
                    raise SystemExit(f"Incomplete MediaSpeech audio: {member.name}")
                os.replace(temporary, destination)

    missing_transcripts = audio_identifiers - transcriptions.keys()
    missing_audio = transcriptions.keys() - audio_identifiers
    if missing_transcripts or missing_audio:
        raise SystemExit("MediaSpeech archive has unpaired audio or transcript items.")
    items = []
    for source_identifier in sorted(audio_identifiers):
        relative_audio_path = Path("mediaspeech-fr") / f"{source_identifier}.flac"
        transcription = transcriptions[source_identifier]
        items.append(
            {
                "id": f"mediaspeech-fr-{source_identifier}",
                "audioPath": relative_audio_path.as_posix(),
                "speakerID": "mediaspeech-fr-speaker-unknown",
                "sessionID": "mediaspeech-fr-media-unknown",
                "split": "blind",
                "language": "french",
                "microphone": "media-source",
                "environment": "real-media",
                "tags": [
                    "public",
                    "mediaspeech",
                    "official-benchmark",
                    "media",
                ],
                "reference": {
                    "verbatim": transcription,
                    "clean": transcription,
                    "criticalSpans": [],
                    "reviewed": True,
                },
            }
        )

    manifest = {
        "schemaVersion": 1,
        "benchmarkID": "voxol-mediaspeech-fr-openslr108",
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
    archive = download(arguments.cache_root / "FR.tgz")
    print(build_manifest(archive, arguments.output_root))


if __name__ == "__main__":
    main()
