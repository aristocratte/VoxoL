#!/usr/bin/env python3
"""Prepare pinned FLEURS French/English NeMo manifests for Parakeet fine-tuning."""

from __future__ import annotations

import argparse
import csv
import json
import os
from pathlib import Path
import shutil
import tarfile

import resumable_dataset_download


DATASET_REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
SAMPLE_RATE = 16_000
CONFIGURATIONS = {
    "en_us": {
        "train_archive_sha256": (
            "5f4491948c2bd29ac00f4b8afae2378f0a1dcdde4041b5cd284a80dff01fa9f5"
        ),
        "train_archive_bytes": 1_380_572_241,
        "train_tsv_sha256": (
            "3ccfc83672cc03a835143e325abb38b4163e3a21725bc1a7d1165bc309b95852"
        ),
        "dev_archive_sha256": (
            "2658fda72f199e12676ecac9415094667a4e14e149b146e568ea00b2a2f0954c"
        ),
        "dev_tsv_sha256": (
            "9d57ee7e91e9d4c92edb39f6bbea668ef8dc2a3ff96eb510d5580b2ad05d17ec"
        ),
    },
    "fr_fr": {
        "train_archive_sha256": (
            "39b5bad1f61d3ae4ef64c2eb16f9524ffb21d8568965dd71b09702befdbd7f95"
        ),
        "train_archive_bytes": 1_730_529_959,
        "train_tsv_sha256": (
            "3df668c3b9b4101cc3e3d8f3024b311ccfd2e9a8c8f910b3efedc27fd4219a0f"
        ),
        "dev_archive_sha256": (
            "f2f065dec3b02212e27151c51162d2213df55d0a8efc6b88e36992673ddf66e6"
        ),
        "dev_tsv_sha256": (
            "3e0b792358c1cb4a426fe1c18fc1571d5406b390d738a2ed1bfd3c8b9d28de44"
        ),
    },
}


digest = resumable_dataset_download.digest


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


def load_rows(source: Path) -> list[dict[str, object]]:
    rows = []
    with source.open(encoding="utf-8", newline="") as stream:
        for line_number, columns in enumerate(
            csv.reader(stream, delimiter="\t", quoting=csv.QUOTE_NONE),
            1,
        ):
            if len(columns) != 7:
                raise SystemExit(f"Unexpected FLEURS row: {source}:{line_number}")
            try:
                sample_count = int(columns[5])
            except ValueError as error:
                raise SystemExit(
                    f"Invalid FLEURS sample count: {source}:{line_number}"
                ) from error
            text = " ".join(columns[2].strip().split())
            if not text or sample_count < 1:
                raise SystemExit(f"Invalid FLEURS item: {source}:{line_number}")
            rows.append(
                {
                    "sentence_id": columns[0],
                    "audio_name": columns[1],
                    "text": text,
                    "sample_count": sample_count,
                }
            )
    return rows


def extract_audio(
    archive_path: Path,
    rows: list[dict[str, object]],
    locale: str,
    split: str,
    output_root: Path,
) -> None:
    rows_by_name = {str(row["audio_name"]): row for row in rows}
    extracted = set()
    destination_root = output_root / "audio" / locale / split
    destination_root.mkdir(parents=True, exist_ok=True)

    with tarfile.open(archive_path, mode="r:gz") as archive:
        for member in archive:
            audio_name = Path(member.name).name
            if audio_name not in rows_by_name or not member.isfile():
                continue
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit(f"Could not read FLEURS audio: {audio_name}")
            destination = destination_root / audio_name
            if not destination.exists() or destination.stat().st_size != member.size:
                temporary = destination.with_suffix(".wav.partial")
                with temporary.open("wb") as output:
                    shutil.copyfileobj(source, output)
                if temporary.stat().st_size != member.size:
                    temporary.unlink(missing_ok=True)
                    raise SystemExit(f"Incomplete FLEURS audio: {audio_name}")
                os.replace(temporary, destination)
            extracted.add(audio_name)

    missing = rows_by_name.keys() - extracted
    if missing:
        raise SystemExit(
            f"FLEURS {locale}/{split} archive is missing {len(missing)} files."
        )


def nemo_record(
    row: dict[str, object],
    locale: str,
    split: str,
    output_root: Path,
) -> dict[str, object]:
    audio_path = (
        output_root / "audio" / locale / split / str(row["audio_name"])
    ).resolve()
    return {
        "audio_filepath": str(audio_path),
        "duration": round(int(row["sample_count"]) / SAMPLE_RATE, 6),
        "text": str(row["text"]),
    }


def interleave(records: dict[str, list[dict[str, object]]]) -> list[dict[str, object]]:
    combined = []
    for index in range(max(map(len, records.values()))):
        for locale in sorted(records):
            if index < len(records[locale]):
                combined.append(records[locale][index])
    return combined


def write_jsonl(path: Path, records: list[dict[str, object]]) -> None:
    temporary = path.with_suffix(path.suffix + ".partial")
    with temporary.open("w", encoding="utf-8") as stream:
        for record in records:
            stream.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
    os.replace(temporary, path)


def plan(
    cache_root: Path,
    output_root: Path,
    splits: tuple[str, ...] = ("train", "dev"),
) -> dict[str, object]:
    return {
        "dataset": "google/fleurs",
        "revision": DATASET_REVISION,
        "locales": sorted(CONFIGURATIONS),
        "requestedSplits": list(splits),
        "trainingSplits": ["train"] if "train" in splits else [],
        "validationSplits": ["dev"] if "dev" in splits else [],
        "forbiddenEvaluationSplits": ["test", "MediaSpeech"],
        "downloadBytesKnownMinimum": sum(
            int(configuration["train_archive_bytes"])
            for configuration in CONFIGURATIONS.values()
        ) if "train" in splits else 0,
        "cacheRoot": str(cache_root.resolve()),
        "outputRoot": str(output_root.resolve()),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument(
        "--print-plan",
        action="store_true",
        help="Print the pinned inputs without downloading them.",
    )
    parser.add_argument(
        "--split",
        action="append",
        choices=("train", "dev"),
        help="Split to prepare. The default prepares train and dev.",
    )
    arguments = parser.parse_args()
    splits = tuple(dict.fromkeys(arguments.split or ("train", "dev")))

    if arguments.print_plan:
        print(
            json.dumps(
                plan(arguments.cache_root, arguments.output_root, splits),
                indent=2,
            )
        )
        return

    records_by_split: dict[str, dict[str, list[dict[str, object]]]] = {
        split: {} for split in splits
    }
    provenance: dict[str, object] = plan(
        arguments.cache_root,
        arguments.output_root,
        splits,
    )
    provenance["sources"] = {}
    provenance["counts"] = {}
    provenance["durationHours"] = {}

    for locale, configuration in sorted(CONFIGURATIONS.items()):
        provenance["sources"][locale] = {}
        provenance["counts"][locale] = {}
        provenance["durationHours"][locale] = {}
        for split in splits:
            tsv = download(
                locale,
                f"{split}.tsv",
                str(configuration[f"{split}_tsv_sha256"]),
                arguments.cache_root / f"{locale}-{split}.tsv",
            )
            archive = download(
                locale,
                f"audio/{split}.tar.gz",
                str(configuration[f"{split}_archive_sha256"]),
                arguments.cache_root / f"{locale}-{split}.tar.gz",
                int(configuration["train_archive_bytes"]) if split == "train" else None,
            )
            rows = load_rows(tsv)
            extract_audio(
                archive,
                rows,
                locale,
                split,
                arguments.output_root,
            )
            records = [
                nemo_record(row, locale, split, arguments.output_root) for row in rows
            ]
            records_by_split[split][locale] = records
            provenance["sources"][locale][split] = {
                "archiveSHA256": digest(archive),
                "tsvSHA256": digest(tsv),
            }
            provenance["counts"][locale][split] = len(records)
            provenance["durationHours"][locale][split] = round(
                sum(float(record["duration"]) for record in records) / 3600,
                4,
            )

    arguments.output_root.mkdir(parents=True, exist_ok=True)
    if "train" in records_by_split:
        write_jsonl(
            arguments.output_root / "train.jsonl",
            interleave(records_by_split["train"]),
        )
    if "dev" in records_by_split:
        write_jsonl(
            arguments.output_root / "validation.jsonl",
            interleave(records_by_split["dev"]),
        )
    provenance_path = arguments.output_root / "provenance.json"
    provenance_path.write_text(
        json.dumps(provenance, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(provenance_path)


if __name__ == "__main__":
    main()
