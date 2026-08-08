#!/usr/bin/env python3
"""Prepare the official AMI full-corpus ASR evaluation meetings."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET
import zipfile


ANNOTATIONS_URL = (
    "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/"
    "ami_public_manual_1.6.2.zip"
)
AUDIO_BASE_URL = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus"
EVALUATION_GROUPS = ("EN2002", "ES2004", "IS1009", "TS3003")
PARTS = ("a", "b", "c", "d")
TARGET_SECONDS = 20.0
MAXIMUM_SECONDS = 30.0
MINIMUM_SILENCE_SECONDS = 0.45
STRONG_SILENCE_SECONDS = 2.0


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def download(url: str, destination: Path) -> Path:
    if destination.is_file() and destination.stat().st_size > 0:
        return destination
    curl = shutil.which("curl")
    if curl is None:
        raise SystemExit("curl is required to download AMI.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".partial")
    subprocess.run(
        [
            curl,
            "--fail",
            "--location",
            "--show-error",
            "--retry",
            "5",
            "--retry-all-errors",
            "--continue-at",
            "-",
            "--output",
            str(partial),
            url,
        ],
        check=True,
    )
    os.replace(partial, destination)
    return destination


def annotation_words(archive: zipfile.ZipFile, meeting: str) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    prefix = f"words/{meeting}."
    for name in sorted(
        value
        for value in archive.namelist()
        if value.startswith(prefix) and value.endswith(".words.xml")
    ):
        speaker = name.removeprefix(prefix).removesuffix(".words.xml")
        root = ET.fromstring(archive.read(name))
        for element in root:
            if element.tag != "w" or element.attrib.get("punc") == "true":
                continue
            text = " ".join("".join(element.itertext()).split())
            if not text:
                continue
            try:
                start = float(element.attrib["starttime"])
                end = float(element.attrib["endtime"])
            except (KeyError, ValueError):
                continue
            rows.append(
                {
                    "end": max(start, end),
                    "speaker": speaker,
                    "start": start,
                    "text": text,
                }
            )
    rows.sort(key=lambda row: (row["start"], row["end"], row["speaker"]))
    return rows


def utterance_chunks(words: list[dict[str, object]]) -> list[list[dict[str, object]]]:
    if not words:
        return []
    chunks: list[list[dict[str, object]]] = []
    current: list[dict[str, object]] = []
    for index, word in enumerate(words):
        if current:
            chunk_start = float(current[0]["start"])
            previous_end = float(current[-1]["end"])
            gap = float(word["start"]) - previous_end
            projected = float(word["end"]) - chunk_start
            if projected > MAXIMUM_SECONDS or (
                previous_end - chunk_start >= TARGET_SECONDS
                and gap >= MINIMUM_SILENCE_SECONDS
            ) or gap >= STRONG_SILENCE_SECONDS:
                chunks.append(current)
                current = []
        current.append(word)
        if index + 1 == len(words):
            chunks.append(current)
    return [
        chunk
        for chunk in chunks
        if len(chunk) >= 2 and float(chunk[-1]["end"]) - float(chunk[0]["start"]) >= 0.5
    ]


def extract_audio(source: Path, start: float, end: float, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file() and destination.stat().st_size > 44:
        return
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise SystemExit("ffmpeg is required to prepare AMI.")
    temporary = destination.with_suffix(".wav.partial")
    subprocess.run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            f"{start:.3f}",
            "-i",
            str(source),
            "-t",
            f"{end - start:.3f}",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            "-f",
            "wav",
            str(temporary),
        ],
        check=True,
    )
    os.replace(temporary, destination)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    arguments = parser.parse_args()
    annotations = download(
        ANNOTATIONS_URL,
        arguments.cache_root / "ami_public_manual_1.6.2.zip",
    )
    items: list[dict[str, object]] = []
    source_files: dict[str, dict[str, object]] = {}
    with zipfile.ZipFile(annotations) as archive:
        for group in EVALUATION_GROUPS:
            for part in PARTS:
                meeting = f"{group}{part}"
                words = annotation_words(archive, meeting)
                if not words:
                    raise SystemExit(f"AMI annotations are missing: {meeting}")
                audio_name = f"{meeting}.Mix-Headset.wav"
                audio = download(
                    f"{AUDIO_BASE_URL}/{meeting}/audio/{audio_name}",
                    arguments.cache_root / "audio" / audio_name,
                )
                source_files[audio_name] = {
                    "bytes": audio.stat().st_size,
                    "sha256": digest(audio),
                }
                for chunk_index, chunk in enumerate(utterance_chunks(words), 1):
                    start = max(0.0, float(chunk[0]["start"]) - 0.2)
                    end = float(chunk[-1]["end"]) + 0.2
                    identifier = f"ami-{meeting.lower()}-{chunk_index:04d}"
                    destination = arguments.output_root / "audio" / meeting / f"{identifier}.wav"
                    extract_audio(audio, start, end, destination)
                    items.append(
                        {
                            "audioPath": destination.relative_to(
                                arguments.output_root / "audio"
                            ).as_posix(),
                            "durationSeconds": round(end - start, 3),
                            "environment": "meeting-mixed-headset",
                            "id": identifier,
                            "language": "english",
                            "microphone": "ami-mix-headset",
                            "reference": {
                                "clean": " ".join(str(word["text"]) for word in chunk),
                                "criticalSpans": [],
                                "reviewed": True,
                                "verbatim": " ".join(str(word["text"]) for word in chunk),
                            },
                            "sessionID": f"ami-{meeting.lower()}",
                            "speakerID": ";".join(
                                f"ami-{meeting.lower()}-{speaker.lower()}"
                                for speaker in sorted({str(word["speaker"]) for word in chunk})
                            ),
                            "split": "blind",
                            "tags": ["public", "ami", "official-evaluation", "meeting", group],
                        }
                    )
    source_files[annotations.name] = {
        "bytes": annotations.stat().st_size,
        "sha256": digest(annotations),
    }
    items.sort(key=lambda item: str(item["id"]))
    manifest = {
        "benchmarkID": "voxol-ami-full-corpus-asr-eval-mix-headset-1.6.2",
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
        json.dumps(source_files, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (arguments.output_root / "provenance.json").write_text(
        json.dumps(
            {
                "annotation_version": "ami_public_manual_1.6.2",
                "audio_condition": "Mix-Headset",
                "evaluation_groups": list(EVALUATION_GROUPS),
                "license": "CC BY 4.0",
                "source": "https://groups.inf.ed.ac.uk/ami/corpus/",
                "split_source": "https://groups.inf.ed.ac.uk/ami/corpus/datasets.shtml",
                "training_use": False,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    print(arguments.output_root / "manifest-unfrozen.json")


if __name__ == "__main__":
    main()
