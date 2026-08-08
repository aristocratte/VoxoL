#!/usr/bin/env python3
"""Prepare the complete pinned FLEURS French and English test splits."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile

import resumable_dataset_download


DATASET_REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
CONFIGURATIONS = {
    "en_us": {
        "language": "english",
        "archive_sha256": (
            "d9c2e37b41aacd41bc283554a0a82b5476b36887049774ecb2819dcaaa55a356"
        ),
        "archive_bytes": 289_851_356,
        "tsv_sha256": (
            "74c046239374deeb60fa63f258f907388093a32bcaa3140965f70ef05c79f7ca"
        ),
    },
    "fr_fr": {
        "language": "french",
        "archive_sha256": (
            "d23690e102f373554d1b544cd2ff1e76e4fedeb04953c0b72751a1b7c518cfdd"
        ),
        "archive_bytes": 349_036_055,
        "tsv_sha256": (
            "5d06d338b242e00786fcf12c4c92008b9f399d5a5c872c91dca90572e7869c0d"
        ),
    },
}


def source_url(locale: str, relative_path: str) -> str:
    return (
        "https://huggingface.co/datasets/google/fleurs/resolve/"
        f"{DATASET_REVISION}/data/{locale}/{relative_path}"
    )


def download(
    locale: str,
    relative_path: str,
    expected_sha256: str,
    destination: Path,
    expected_bytes: int | None = None,
) -> Path:
    return resumable_dataset_download.download_verified(
        source_url(locale, relative_path),
        expected_sha256,
        destination,
        expected_bytes,
    )


def load_rows(source: Path) -> list[dict[str, str]]:
    rows = []
    with source.open(encoding="utf-8", newline="") as stream:
        for line_number, columns in enumerate(
            csv.reader(stream, delimiter="\t", quoting=csv.QUOTE_NONE),
            1,
        ):
            if len(columns) != 7:
                raise SystemExit(f"Unexpected FLEURS row: {source}:{line_number}")
            # Column 2 is raw_transcription and column 3 is transcription,
            # the normalised form FLEURS results are published against. They
            # were mapped the other way round. The scorer normalises away the
            # difference, so no measured score changes; the fields now hold
            # what their names say.
            rows.append(
                {
                    "sentence_id": columns[0],
                    "audio_name": columns[1],
                    "clean": columns[3].strip(),
                    "verbatim": columns[2].strip(),
                    "gender": columns[6].lower(),
                }
            )
    return rows


def extract_items(
    archive_path: Path,
    rows: list[dict[str, str]],
    locale: str,
    output_root: Path,
) -> list[dict[str, object]]:
    configuration = CONFIGURATIONS[locale]
    rows_by_name = {row["audio_name"]: row for row in rows}
    extracted = set()
    audio_root = output_root / "audio"
    items = []

    with tarfile.open(archive_path, mode="r:gz") as archive:
        for member in archive:
            audio_name = Path(member.name).name
            row = rows_by_name.get(audio_name)
            if row is None or not member.isfile():
                continue
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit(f"Could not read FLEURS audio: {audio_name}")
            identity = hashlib.sha256(
                f"{locale}\0{row['sentence_id']}\0{audio_name}".encode()
            ).hexdigest()[:12]
            identifier = f"fleurs-{locale}-test-{identity}"
            relative_audio_path = Path(f"fleurs-{locale}-test") / f"{identifier}.wav"
            destination = audio_root / relative_audio_path
            if not destination.exists() or destination.stat().st_size != member.size:
                destination.parent.mkdir(parents=True, exist_ok=True)
                temporary = destination.with_suffix(".wav.partial")
                with temporary.open("wb") as output:
                    shutil.copyfileobj(source, output)
                if temporary.stat().st_size != member.size:
                    temporary.unlink(missing_ok=True)
                    raise SystemExit(f"Incomplete FLEURS audio: {audio_name}")
                os.replace(temporary, destination)
            extracted.add(audio_name)
            items.append(
                {
                    "id": identifier,
                    "audioPath": relative_audio_path.as_posix(),
                    "speakerID": f"fleurs-{locale}-test-speaker-unknown",
                    "sessionID": f"fleurs-{locale}-test",
                    "split": "blind",
                    "language": configuration["language"],
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

    missing = rows_by_name.keys() - extracted
    if missing:
        raise SystemExit(f"FLEURS {locale} archive is missing {len(missing)} files.")
    return items


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument(
        "--locale",
        action="append",
        choices=sorted(CONFIGURATIONS),
        help="Locale to prepare. The default prepares both pinned locales.",
    )
    arguments = parser.parse_args()
    locales = arguments.locale or sorted(CONFIGURATIONS)
    items = []

    for locale in locales:
        configuration = CONFIGURATIONS[locale]
        tsv = download(
            locale,
            "test.tsv",
            str(configuration["tsv_sha256"]),
            arguments.cache_root / f"{locale}-test.tsv",
        )
        archive = download(
            locale,
            "audio/test.tar.gz",
            str(configuration["archive_sha256"]),
            arguments.cache_root / f"{locale}-test.tar.gz",
            int(configuration["archive_bytes"]),
        )
        items.extend(
            extract_items(
                archive,
                load_rows(tsv),
                locale,
                arguments.output_root,
            )
        )

    items.sort(key=lambda item: str(item["id"]))
    manifest = {
        "schemaVersion": 1,
        "benchmarkID": (
            "voxol-fleurs-test-" f"{'-'.join(locales)}-{DATASET_REVISION[:12]}"
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
