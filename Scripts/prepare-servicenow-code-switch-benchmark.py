#!/usr/bin/env python3
"""Prepare the pinned ServiceNow French/English code-switch benchmark."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from typing import Iterable
import wave

import pyarrow.parquet as pq


DATASET = "ServiceNow-AI/asr_codeswitched"
DATASET_REVISION = "82bf4b49499bcaa6f4cf6a67bebfab3ee2affcbb"
CONFIGURATIONS = {
    "en_fr": {
        "bytes": 103_832_669,
        "rows": 298,
        "sha256": "bc05dc0404d8209e05ea7041c8557e773bf9c59127a52c8784c8c760ec11284d",
        "locale": "fr-fr",
    },
    "en_fr_ca": {
        "bytes": 63_796_492,
        "rows": 188,
        "sha256": "1ba4b634d11621834bd4184d6455e6e4a7a9a33d8a9bad2c7853e58837966ad6",
        "locale": "fr-ca",
    },
}
REQUIRED_COLUMNS = {
    "ID",
    "audio",
    "utterance",
    "voice",
    "words",
    "word_languages",
}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def source_url(configuration: str) -> str:
    return (
        f"https://huggingface.co/datasets/{DATASET}/resolve/"
        f"{DATASET_REVISION}/{configuration}/test-00000-of-00001.parquet"
    )


def validate_source(path: Path, configuration: str) -> None:
    expected = CONFIGURATIONS[configuration]
    if path.stat().st_size != expected["bytes"]:
        raise RuntimeError(
            f"Unexpected byte count for {path}: {path.stat().st_size}; "
            f"expected {expected['bytes']}"
        )
    actual_digest = digest(path)
    if actual_digest != expected["sha256"]:
        raise RuntimeError(
            f"Checksum mismatch for {path}: {actual_digest}; "
            f"expected {expected['sha256']}"
        )
    parquet = pq.ParquetFile(path)
    if parquet.metadata.num_rows != expected["rows"]:
        raise RuntimeError(
            f"Unexpected row count for {path}: {parquet.metadata.num_rows}; "
            f"expected {expected['rows']}"
        )
    missing = REQUIRED_COLUMNS - set(parquet.schema_arrow.names)
    if missing:
        raise RuntimeError(f"Missing columns in {path}: {sorted(missing)}")


def download(configuration: str, destination: Path) -> Path:
    if destination.is_file():
        validate_source(destination, configuration)
        print(f"[dataset-cache] verified {destination}", flush=True)
        return destination

    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".partial")
    expected_bytes = int(CONFIGURATIONS[configuration]["bytes"])
    if partial.is_file() and partial.stat().st_size == expected_bytes:
        validate_source(partial, configuration)
        os.replace(partial, destination)
        return destination
    if partial.is_file() and partial.stat().st_size > expected_bytes:
        raise RuntimeError(f"Partial download is larger than expected: {partial}")

    curl = shutil.which("curl")
    if curl is None:
        raise RuntimeError("curl is required to download the benchmark source")
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
    validate_source(partial, configuration)
    os.replace(partial, destination)
    return destination


def mixing_stats(word_languages: Iterable[str]) -> tuple[float, int]:
    labels = [str(label).upper() for label in word_languages if str(label).strip()]
    if not labels:
        return 0.0, 0
    counts: dict[str, int] = {}
    for label in labels:
        counts[label] = counts.get(label, 0) + 1
    dominant = max(counts.values())
    cmi = (len(labels) - dominant) / len(labels) * 100
    switches = sum(left != right for left, right in zip(labels, labels[1:]))
    return cmi, switches


def stable_identifier(configuration: str, source_id: str) -> str:
    identity = hashlib.sha256(
        f"{DATASET_REVISION}\0{configuration}\0{source_id}".encode()
    ).hexdigest()[:16]
    return f"servicenow-{configuration.replace('_', '-')}-{identity}"


def voice_identifier(voice: str) -> str:
    identity = hashlib.sha256(voice.encode()).hexdigest()[:12]
    return f"servicenow-voice-{identity}"


def make_item(
    row: dict[str, object],
    configuration: str,
    relative_audio_path: Path,
) -> tuple[dict[str, object], dict[str, object]]:
    source_id = str(row.get("ID") or "").strip()
    transcript = str(row.get("utterance") or "").strip()
    voice = str(row.get("voice") or "unknown").strip()
    words = [str(word) for word in (row.get("words") or [])]
    languages = [str(label).upper() for label in (row.get("word_languages") or [])]
    if not source_id or not transcript:
        raise RuntimeError(f"Incomplete {configuration} record: {source_id!r}")
    if not words or len(words) != len(languages):
        raise RuntimeError(
            f"Invalid word-language alignment for {configuration}/{source_id}: "
            f"{len(words)} words, {len(languages)} labels"
        )
    identifier = stable_identifier(configuration, source_id)
    cmi, switch_count = mixing_stats(languages)
    item = {
        "audioPath": relative_audio_path.as_posix(),
        "environment": "synthetic-enterprise-support",
        "id": identifier,
        "language": "mixed",
        "microphone": "elevenlabs-multilingual-v2-tts",
        "reference": {
            "clean": transcript,
            "criticalSpans": [],
            "reviewed": True,
            "verbatim": transcript,
        },
        "sessionID": f"servicenow-{configuration}-test",
        "speakerID": voice_identifier(voice),
        "split": "blind",
        "tags": [
            "public",
            "servicenow-asr-codeswitched",
            "code-switch-fr-en",
            "official-test",
            "synthetic",
            "enterprise-support",
            str(CONFIGURATIONS[configuration]["locale"]),
        ],
    }
    metadata = {
        "codeMixingIndex": round(cmi, 6),
        "configuration": configuration,
        "datasetID": source_id,
        "expectedAnswers": [str(value) for value in (row.get("expected_answers") or [])],
        "id": identifier,
        "questions": [str(value) for value in (row.get("questions") or [])],
        "switchCount": switch_count,
        "voice": voice,
        "wordLanguages": languages,
        "words": words,
    }
    return item, metadata


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(content, encoding="utf-8")
    os.replace(temporary, path)


def is_canonical_audio(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        with wave.open(str(path), "rb") as stream:
            return (
                stream.getnchannels() == 1
                and stream.getframerate() == 16_000
                and stream.getsampwidth() == 2
                and stream.getnframes() >= 1_600
            )
    except (EOFError, wave.Error):
        return False


def write_canonical_audio(audio_bytes: bytes, destination: Path) -> None:
    if is_canonical_audio(destination):
        return
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise RuntimeError("ffmpeg is required to canonicalize benchmark audio to mono 16 kHz")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".wav.partial")
    subprocess.run(
        [
            ffmpeg,
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            "pipe:0",
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
        input=audio_bytes,
        check=True,
    )
    if not is_canonical_audio(temporary):
        raise RuntimeError(f"ffmpeg produced invalid benchmark audio: {temporary}")
    os.replace(temporary, destination)


def build_benchmark(
    sources: dict[str, Path],
    output_root: Path,
) -> tuple[Path, Path]:
    items: list[dict[str, object]] = []
    metadata: list[dict[str, object]] = []
    for configuration, source in sources.items():
        parquet = pq.ParquetFile(source, memory_map=True)
        for batch in parquet.iter_batches(
            batch_size=16,
            columns=sorted(REQUIRED_COLUMNS | {"questions", "expected_answers"}),
            use_threads=False,
        ):
            for row in batch.to_pylist():
                audio = row.get("audio")
                if not isinstance(audio, dict) or not audio.get("bytes"):
                    raise RuntimeError(
                        f"Missing audio bytes for {configuration}/{row.get('ID')}"
                    )
                source_id = str(row.get("ID") or "").strip()
                identifier = stable_identifier(configuration, source_id)
                relative = Path(configuration) / f"{identifier}.wav"
                destination = output_root / "audio" / relative
                audio_bytes = bytes(audio["bytes"])
                write_canonical_audio(audio_bytes, destination)
                item, extra = make_item(row, configuration, relative)
                extra["audioSHA256"] = hashlib.sha256(audio_bytes).hexdigest()
                extra["benchmarkAudioSHA256"] = digest(destination)
                items.append(item)
                metadata.append(extra)

    items.sort(key=lambda value: str(value["id"]))
    metadata.sort(key=lambda value: str(value["id"]))
    configurations = "-".join(configuration.replace("_", "-") for configuration in sources)
    manifest = {
        "benchmarkID": (
            f"voxol-servicenow-code-switch-{configurations}-{DATASET_REVISION[:12]}"
        ),
        "items": items,
        "normalizationVersion": "voxol-asr-normalizer-v1",
        "schemaVersion": 1,
    }
    manifest_path = output_root / "manifest-unfrozen.json"
    metadata_path = output_root / "codeswitch-metadata.jsonl"
    atomic_write(
        manifest_path,
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    )
    atomic_write(
        metadata_path,
        "".join(
            json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            for row in metadata
        ),
    )
    lock = {
        "dataset": DATASET,
        "datasetRevision": DATASET_REVISION,
        "licenseStatus": "not-declared-in-pinned-dataset-card",
        "manifestItemCount": len(items),
        "sources": {
            configuration: {
                "bytes": source.stat().st_size,
                "path": f"{configuration}/test-00000-of-00001.parquet",
                "rows": pq.ParquetFile(source).metadata.num_rows,
                "sha256": digest(source),
                "url": source_url(configuration),
            }
            for configuration, source in sources.items()
        },
    }
    atomic_write(
        output_root / "source-lock.json",
        json.dumps(lock, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    )
    return manifest_path, metadata_path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument(
        "--configurations",
        default="en_fr,en_fr_ca",
        help="Comma-separated pinned configurations",
    )
    arguments = parser.parse_args()
    configurations = [
        value.strip() for value in arguments.configurations.split(",") if value.strip()
    ]
    unknown = set(configurations) - set(CONFIGURATIONS)
    if unknown or not configurations:
        raise SystemExit(f"Unsupported configurations: {sorted(unknown)}")
    sources = {
        configuration: download(
            configuration,
            arguments.cache_root / configuration / "test-00000-of-00001.parquet",
        )
        for configuration in configurations
    }
    manifest_path, metadata_path = build_benchmark(sources, arguments.output_root)
    print(manifest_path)
    print(metadata_path)


if __name__ == "__main__":
    main()
