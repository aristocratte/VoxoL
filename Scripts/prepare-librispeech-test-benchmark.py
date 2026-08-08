#!/usr/bin/env python3
"""Prepare the official LibriSpeech test-clean and test-other ASR splits."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile


BASE_URL = "https://openslr.trmal.net/resources/12"
SPLITS = {
    "test-clean": {
        "md5": "32fa31d27d2e1cad72775fee3f4849a9",
        "environment": "clean-read-speech",
    },
    "test-other": {
        "md5": "fb5a50374b501bb3bac4815ee91d3135",
        "environment": "challenging-read-speech",
    },
}


def digest(path: Path, algorithm: str) -> str:
    hasher = hashlib.new(algorithm)
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def download(split: str, destination: Path) -> Path:
    expected_md5 = str(SPLITS[split]["md5"])
    if destination.is_file() and digest(destination, "md5") == expected_md5:
        print(f"[dataset-cache] Verified {destination}", flush=True)
        return destination
    destination.unlink(missing_ok=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".partial")
    curl = shutil.which("curl")
    if curl is None:
        raise SystemExit("curl is required to download LibriSpeech.")
    for attempt in range(1, 3):
        print(
            f"[dataset-cache] Downloading {destination.name} "
            f"(attempt {attempt}/2, resume enabled)",
            flush=True,
        )
        try:
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
                    f"{BASE_URL}/{split}.tar.gz",
                ],
                check=True,
            )
        except subprocess.CalledProcessError as error:
            raise SystemExit(
                f"LibriSpeech download failed; partial kept at {partial}"
            ) from error
        if digest(partial, "md5") == expected_md5:
            os.replace(partial, destination)
            print(f"[dataset-cache] Ready: {destination}", flush=True)
            return destination
        partial.unlink(missing_ok=True)
    raise SystemExit(f"LibriSpeech checksum mismatch: {destination.name}")


def transcript_rows(archive: tarfile.TarFile) -> dict[str, str]:
    rows: dict[str, str] = {}
    for member in archive.getmembers():
        if not member.isfile() or not member.name.endswith(".trans.txt"):
            continue
        source = archive.extractfile(member)
        if source is None:
            raise SystemExit(f"Could not read {member.name}")
        for raw_line in source.read().decode("utf-8").splitlines():
            identifier, separator, text = raw_line.partition(" ")
            if not separator or not text.strip():
                raise SystemExit(f"Invalid LibriSpeech transcript in {member.name}")
            if identifier in rows:
                raise SystemExit(f"Duplicate LibriSpeech utterance: {identifier}")
            rows[identifier] = text.strip()
    return rows


def extract_split(archive_path: Path, split: str, output_root: Path) -> list[dict[str, object]]:
    audio_root = output_root / "audio" / f"librispeech-{split}"
    items: list[dict[str, object]] = []
    extracted: set[str] = set()
    with tarfile.open(archive_path, mode="r:gz") as archive:
        transcripts = transcript_rows(archive)
        for member in archive.getmembers():
            if not member.isfile() or not member.name.endswith(".flac"):
                continue
            identifier = Path(member.name).stem
            text = transcripts.get(identifier)
            if text is None:
                raise SystemExit(f"Missing LibriSpeech transcript: {identifier}")
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit(f"Could not read {member.name}")
            destination = audio_root / f"{identifier}.flac"
            if not destination.is_file() or destination.stat().st_size != member.size:
                destination.parent.mkdir(parents=True, exist_ok=True)
                temporary = destination.with_suffix(".flac.partial")
                with temporary.open("wb") as output:
                    shutil.copyfileobj(source, output)
                if temporary.stat().st_size != member.size:
                    temporary.unlink(missing_ok=True)
                    raise SystemExit(f"Incomplete LibriSpeech audio: {identifier}")
                os.replace(temporary, destination)
            speaker, chapter, *_ = identifier.split("-")
            relative_path = destination.relative_to(output_root / "audio")
            items.append(
                {
                    "id": f"librispeech-{split}-{identifier}",
                    "audioPath": relative_path.as_posix(),
                    "speakerID": f"librispeech-{speaker}",
                    "sessionID": f"librispeech-{speaker}-{chapter}",
                    "split": "blind",
                    "language": "english",
                    "microphone": "librispeech-source",
                    "environment": SPLITS[split]["environment"],
                    "tags": ["public", "librispeech", "official-test", split, "read-speech"],
                    "reference": {
                        "verbatim": text,
                        "clean": text,
                        "criticalSpans": [],
                        "reviewed": True,
                    },
                }
            )
            extracted.add(identifier)
    missing = transcripts.keys() - extracted
    if missing:
        raise SystemExit(f"LibriSpeech {split} is missing {len(missing)} audio files.")
    return items


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--split", action="append", choices=sorted(SPLITS))
    arguments = parser.parse_args()
    splits = arguments.split or sorted(SPLITS)
    items: list[dict[str, object]] = []
    source_digests: dict[str, dict[str, object]] = {}
    for split in splits:
        archive = download(split, arguments.cache_root / f"{split}.tar.gz")
        source_digests[archive.name] = {
            "bytes": archive.stat().st_size,
            "md5": digest(archive, "md5"),
            "sha256": digest(archive, "sha256"),
        }
        items.extend(extract_split(archive, split, arguments.output_root))
    items.sort(key=lambda item: str(item["id"]))
    manifest = {
        "schemaVersion": 1,
        "benchmarkID": f"voxol-librispeech-{'-'.join(splits)}-openslr12",
        "normalizationVersion": "voxol-asr-normalizer-v1",
        "items": items,
    }
    arguments.output_root.mkdir(parents=True, exist_ok=True)
    manifest_path = arguments.output_root / "manifest-unfrozen.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (arguments.output_root / "source-checksums.json").write_text(
        json.dumps(source_digests, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(manifest_path)


if __name__ == "__main__":
    main()
