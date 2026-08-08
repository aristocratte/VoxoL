#!/usr/bin/env python3
"""Prepare pinned test-split samples from four public multilingual ASR corpora.

One published number on a single corpus is an anecdote: FLEURS is studio-read
prose, Common Voice is a phone held at arm's length, MLS is an audiobook, and
VoxPopuli is a politician talking over a room. A system can win one and lose
another, so the suite runs all four across the same eight languages and reports
each separately rather than averaging away the difference.

Every corpus keeps its own human reference exactly as published. The only
processing applied to audio is a resample to the 16 kHz mono PCM the runtime
consumes, so a difference in score is a difference in recognition rather than a
difference in preprocessing.

Sampling is a hash of (corpus, language, clip id) rather than a random draw:
rerunning this script on another machine, or after the upstream file order
changes, selects the same clips. The chosen subset is then frozen with
`voxol-asr-benchmark freeze`, which hashes the audio content itself.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

# Sixteen kilohertz mono is what the encoder consumes; anything else would be
# resampled inside the runtime, and doing it here keeps every corpus identical
# going in.
TARGET_SAMPLE_RATE = 16_000

# Clips outside this window are dropped before sampling. Under a second is
# usually a single word with no context, and the corpora that segment by
# sentence occasionally emit a minutes-long outlier that says more about the
# segmenter than about the recogniser.
MINIMUM_DURATION_SECONDS = 1.0
MAXIMUM_DURATION_SECONDS = 30.0

LANGUAGES = {
    "en": {"name": "english", "fleurs": "en_us", "mls": None, "voxpopuli": "en"},
    "fr": {"name": "french", "fleurs": "fr_fr", "mls": "french", "voxpopuli": "fr"},
    "de": {"name": "german", "fleurs": "de_de", "mls": "german", "voxpopuli": "de"},
    "es": {"name": "spanish", "fleurs": "es_419", "mls": "spanish", "voxpopuli": "es"},
    "it": {"name": "italian", "fleurs": "it_it", "mls": "italian", "voxpopuli": "it"},
    "pt": {
        "name": "portuguese",
        "fleurs": "pt_br",
        "mls": "portuguese",
        "voxpopuli": None,
    },
    "nl": {"name": "dutch", "fleurs": "nl_nl", "mls": "dutch", "voxpopuli": "nl"},
    "pl": {"name": "polish", "fleurs": "pl_pl", "mls": "polish", "voxpopuli": "pl"},
}

# Pinned upstream revisions. A benchmark that tracks `main` silently changes
# meaning when the dataset owner edits a transcript.
FLEURS_REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
COMMON_VOICE_REPOSITORY = "fsicoli/common_voice_21_0"
COMMON_VOICE_REVISION = "main"

CORPUS_METADATA = {
    "fleurs": {
        "citation": "FLEURS (Conneau et al., 2022)",
        "speech": "read-speech",
        "tags": ["fleurs", "read-speech", "studio"],
    },
    "commonvoice": {
        "citation": "Common Voice Corpus 21.0 (Mozilla, 2025)",
        "speech": "crowdsourced",
        "tags": ["common-voice", "crowdsourced", "consumer-microphone"],
    },
    "mls": {
        "citation": "Multilingual LibriSpeech (Pratap et al., 2020)",
        "speech": "read-audiobook",
        "tags": ["mls", "audiobook", "read-speech"],
    },
    "voxpopuli": {
        "citation": "VoxPopuli (Wang et al., 2021)",
        "speech": "spontaneous",
        "tags": ["voxpopuli", "spontaneous", "parliament"],
    },
    "librispeech": {
        "citation": "LibriSpeech test-clean (Panayotov et al., 2015)",
        "speech": "read-audiobook",
        "tags": ["librispeech", "audiobook", "read-speech", "test-clean"],
    },
}

# Multilingual LibriSpeech has no English config; LibriSpeech test-clean is the
# audiobook set English is actually published against, so it fills that slot and
# every language ends up measured on the same four kinds of speech.
LIBRISPEECH_BENCHMARK = Path(
    "/Volumes/0_Oueillez/VoxoL-Benchmarks-v2/benchmarks/librispeech-test"
)


def authorization_headers() -> list[str]:
    """Curl arguments carrying the Hugging Face token when one is exported."""
    token = os.environ.get("HF_TOKEN", "").strip()
    return ["--header", f"Authorization: Bearer {token}"] if token else []


def digest_of(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def download_pinned(url: str, destination: Path, lock: dict[str, str]) -> Path:
    """Fetch `url` once, then verify every later run against the first digest.

    The upstream corpora publish no checksums for these files, so the first
    download establishes the pin and it is recorded in a lockfile beside the
    cache. A silent upstream edit afterwards fails loudly instead of quietly
    changing what the published numbers refer to.
    """
    expected = lock.get(url)
    if destination.exists():
        actual = digest_of(destination)
        if expected is None:
            lock[url] = actual
            return destination
        if actual == expected:
            return destination
        raise SystemExit(
            f"Cached file no longer matches its pin: {destination}\n"
            f"  expected {expected}\n  actual   {actual}"
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".partial")
    print(f"[fetch] {destination.name}", flush=True)
    subprocess.run(
        [
            "curl",
            "--fail",
            "--location",
            "--show-error",
            "--silent",
            "--retry",
            "5",
            "--retry-delay",
            "2",
            "--retry-all-errors",
            "--connect-timeout",
            "30",
            "--continue-at",
            "-",
            *authorization_headers(),
            "--output",
            str(partial),
            url,
        ],
        check=True,
    )
    actual = digest_of(partial)
    if expected is not None and actual != expected:
        partial.unlink(missing_ok=True)
        raise SystemExit(f"Download does not match its pin: {url}")
    os.replace(partial, destination)
    lock[url] = actual
    return destination


def selection_key(corpus: str, language: str, identifier: str) -> str:
    """Stable per-clip sort key, independent of upstream ordering."""
    return hashlib.sha256(f"{corpus}\0{language}\0{identifier}".encode()).hexdigest()


def sample(candidates: list[dict], corpus: str, language: str, count: int) -> list[dict]:
    ordered = sorted(candidates, key=lambda c: selection_key(corpus, language, c["id"]))
    return ordered[:count]


def probe_duration(path: Path) -> float | None:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "csv=p=0",
            str(path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        return float(result.stdout.strip())
    except ValueError:
        return None


def write_wav(source: Path | bytes, destination: Path) -> float | None:
    """Transcode to 16 kHz mono PCM and return the resulting duration."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    # The partial name has to keep the .wav extension: ffmpeg picks its output
    # muxer from the extension and refuses to write to an unknown one.
    temporary = destination.with_name(destination.name + ".partial.wav")
    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        "pipe:0" if isinstance(source, bytes) else str(source),
        "-ac",
        "1",
        "-ar",
        str(TARGET_SAMPLE_RATE),
        "-acodec",
        "pcm_s16le",
        str(temporary),
    ]
    result = subprocess.run(
        command,
        input=source if isinstance(source, bytes) else None,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0 or not temporary.exists():
        temporary.unlink(missing_ok=True)
        return None
    duration = probe_duration(temporary)
    if duration is None:
        temporary.unlink(missing_ok=True)
        return None
    os.replace(temporary, destination)
    return duration


def manifest_item(
    corpus: str,
    language: str,
    identifier: str,
    relative_path: str,
    reference: str,
    speaker: str,
    verbatim: str | None = None,
    extra_tags: list[str] | None = None,
) -> dict:
    metadata = CORPUS_METADATA[corpus]
    # VoxPopuli leaves raw_text empty on segments it never had a human confirm,
    # and an empty verbatim reference would score as a total miss.
    if not (verbatim or "").strip():
        verbatim = None
    return {
        "id": identifier,
        "audioPath": relative_path,
        "speakerID": speaker,
        "sessionID": f"{corpus}-{language}-test",
        "split": "blind",
        "language": LANGUAGES[language]["name"],
        "microphone": f"{corpus}-source",
        "environment": "source-unknown",
        "tags": ["public", "official-test", *metadata["tags"], *(extra_tags or [])],
        "reference": {
            "verbatim": verbatim if verbatim is not None else reference,
            "clean": reference,
            "criticalSpans": [],
            "reviewed": True,
        },
    }


# --------------------------------------------------------------------------
# FLEURS
# --------------------------------------------------------------------------


def prepare_fleurs(language: str, count: int, cache: Path, output: Path, lock: dict):
    locale = LANGUAGES[language]["fleurs"]
    base = f"https://huggingface.co/datasets/google/fleurs/resolve/{FLEURS_REVISION}/data/{locale}"
    tsv = download_pinned(
        f"{base}/test.tsv", cache / "fleurs" / f"{locale}-test.tsv", lock
    )
    archive = download_pinned(
        f"{base}/audio/test.tar.gz", cache / "fleurs" / f"{locale}-test.tar.gz", lock
    )

    rows: dict[str, dict] = {}
    with tsv.open(encoding="utf-8", newline="") as stream:
        for columns in csv.reader(stream, delimiter="\t", quoting=csv.QUOTE_NONE):
            if len(columns) != 7:
                continue
            # FLEURS columns are id, filename, raw_transcription,
            # transcription, character split, sample count, gender. Column 3 is
            # the normalised transcript FLEURS results are published against;
            # column 2 keeps the casing and punctuation. They were mapped the
            # other way round here. Measured effect on the scores: none, since
            # the two differ only in casing and punctuation and the scorer
            # removes both. The names now match their contents anyway, because
            # the next reader of this file will assume they do.
            rows[columns[1]] = {
                "id": columns[1],
                "clean": columns[3].strip(),
                "verbatim": columns[2].strip(),
                "gender": columns[6].lower(),
            }

    wanted = {row["id"]: row for row in sample(list(rows.values()), "fleurs", language, count)}
    items = []
    directory = f"fleurs-{language}-test"
    with tarfile.open(archive, mode="r:gz") as tar:
        for member in tar:
            name = Path(member.name).name
            row = wanted.get(name)
            if row is None or not member.isfile():
                continue
            handle = tar.extractfile(member)
            if handle is None:
                continue
            identity = hashlib.sha256(f"fleurs\0{locale}\0{name}".encode()).hexdigest()[:12]
            identifier = f"fleurs-{language}-{identity}"
            relative = f"{directory}/{identifier}.wav"
            duration = write_wav(handle.read(), output / "audio" / relative)
            if duration is None or not (
                MINIMUM_DURATION_SECONDS <= duration <= MAXIMUM_DURATION_SECONDS
            ):
                (output / "audio" / relative).unlink(missing_ok=True)
                continue
            items.append(
                manifest_item(
                    "fleurs",
                    language,
                    identifier,
                    relative,
                    row["clean"],
                    f"fleurs-{language}-speaker-unknown",
                    verbatim=row["verbatim"],
                    extra_tags=[row["gender"]] if row["gender"] else None,
                )
            )
    return items


# --------------------------------------------------------------------------
# Common Voice
# --------------------------------------------------------------------------


def prepare_common_voice(language: str, count: int, cache: Path, output: Path, lock: dict):
    base = (
        f"https://huggingface.co/datasets/{COMMON_VOICE_REPOSITORY}"
        f"/resolve/{COMMON_VOICE_REVISION}"
    )
    tsv = download_pinned(
        f"{base}/transcript/{language}/test.tsv",
        cache / "commonvoice" / f"{language}-test.tsv",
        lock,
    )
    archive = download_pinned(
        f"{base}/audio/{language}/test/{language}_test_0.tar",
        cache / "commonvoice" / f"{language}-test.tar",
        lock,
    )

    rows: dict[str, dict] = {}
    with tsv.open(encoding="utf-8", newline="") as stream:
        for row in csv.DictReader(stream, delimiter="\t", quoting=csv.QUOTE_NONE):
            sentence = (row.get("sentence") or "").strip()
            path = (row.get("path") or "").strip()
            if not sentence or not path:
                continue
            rows[path] = {
                "id": path,
                "sentence": sentence,
                "speaker": (row.get("client_id") or "unknown")[:16],
            }

    wanted = {
        row["id"]: row
        for row in sample(list(rows.values()), "commonvoice", language, count)
    }
    items = []
    directory = f"commonvoice-{language}-test"
    with tarfile.open(archive, mode="r|") as tar:
        for member in tar:
            name = Path(member.name).name
            row = wanted.get(name)
            if row is None or not member.isfile():
                continue
            handle = tar.extractfile(member)
            if handle is None:
                continue
            identity = hashlib.sha256(f"commonvoice\0{language}\0{name}".encode()).hexdigest()[:12]
            identifier = f"commonvoice-{language}-{identity}"
            relative = f"{directory}/{identifier}.wav"
            duration = write_wav(handle.read(), output / "audio" / relative)
            if duration is None or not (
                MINIMUM_DURATION_SECONDS <= duration <= MAXIMUM_DURATION_SECONDS
            ):
                (output / "audio" / relative).unlink(missing_ok=True)
                continue
            items.append(
                manifest_item(
                    "commonvoice",
                    language,
                    identifier,
                    relative,
                    row["sentence"],
                    f"commonvoice-{language}-{row['speaker']}",
                )
            )
    return items


# --------------------------------------------------------------------------
# Parquet-backed corpora (MLS, VoxPopuli)
# --------------------------------------------------------------------------


def parquet_test_url(dataset: str, config: str) -> tuple[str, int]:
    import requests

    headers = {}
    token = os.environ.get("HF_TOKEN", "").strip()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    response = requests.get(
        f"https://datasets-server.huggingface.co/parquet?dataset={dataset}",
        headers=headers,
        timeout=180,
    )
    response.raise_for_status()
    files = [
        entry
        for entry in response.json()["parquet_files"]
        if entry["config"] == config and entry["split"] == "test"
    ]
    if len(files) != 1:
        raise SystemExit(
            f"Expected exactly one test parquet for {dataset}/{config}, got {len(files)}"
        )
    return files[0]["url"], files[0]["size"]


def prepare_from_parquet(
    corpus: str,
    dataset: str,
    config: str,
    language: str,
    count: int,
    cache: Path,
    output: Path,
    lock: dict,
    text_column: str,
    identifier_column: str,
    speaker_column: str,
    duration_column: str | None,
    verbatim_column: str | None = None,
):
    import pyarrow.parquet as pq

    url, _ = parquet_test_url(dataset, config)
    local = download_pinned(url, cache / corpus / f"{config}-test.parquet", lock)
    handle = pq.ParquetFile(local)

    # Pass one reads only the small text columns, so the multi-hundred-megabyte
    # audio column never enters memory while the sample is being chosen.
    metadata_columns = [identifier_column, text_column, speaker_column]
    if duration_column:
        metadata_columns.append(duration_column)
    if verbatim_column:
        metadata_columns.append(verbatim_column)
    metadata_columns = list(dict.fromkeys(metadata_columns))

    candidates: list[dict] = []
    for batch in handle.iter_batches(batch_size=512, columns=metadata_columns):
        table = batch.to_pydict()
        for index in range(len(table[identifier_column])):
            text = (table[text_column][index] or "").strip()
            if not text:
                continue
            duration = table[duration_column][index] if duration_column else None
            if duration is not None and not (
                MINIMUM_DURATION_SECONDS <= float(duration) <= MAXIMUM_DURATION_SECONDS
            ):
                continue
            candidates.append(
                {
                    "id": str(table[identifier_column][index]),
                    "text": text,
                    "verbatim": (table[verbatim_column][index] or "").strip()
                    if verbatim_column
                    else None,
                    "speaker": str(table[speaker_column][index]),
                }
            )

    wanted = {row["id"]: row for row in sample(candidates, corpus, language, count)}
    items = []
    directory = f"{corpus}-{language}-test"

    # Pass two pulls the audio one row group at a time so peak memory stays at a
    # single group rather than the whole file.
    for group in range(handle.num_row_groups):
        table = handle.read_row_group(group, columns=[identifier_column, "audio"])
        payload = table.to_pydict()
        for index in range(len(payload[identifier_column])):
            key = str(payload[identifier_column][index])
            row = wanted.get(key)
            if row is None:
                continue
            audio = payload["audio"][index]
            raw = audio["bytes"] if isinstance(audio, dict) else audio
            if not raw:
                continue
            identity = hashlib.sha256(f"{corpus}\0{config}\0{key}".encode()).hexdigest()[:12]
            identifier = f"{corpus}-{language}-{identity}"
            relative = f"{directory}/{identifier}.wav"
            duration = write_wav(raw, output / "audio" / relative)
            if duration is None or not (
                MINIMUM_DURATION_SECONDS <= duration <= MAXIMUM_DURATION_SECONDS
            ):
                (output / "audio" / relative).unlink(missing_ok=True)
                continue
            items.append(
                manifest_item(
                    corpus,
                    language,
                    identifier,
                    relative,
                    row["text"],
                    f"{corpus}-{language}-{row['speaker']}",
                    verbatim=row["verbatim"],
                )
            )
        del table, payload
    return items


def prepare_mls(language: str, count: int, cache: Path, output: Path, lock: dict):
    return prepare_from_parquet(
        "mls",
        "facebook/multilingual_librispeech",
        LANGUAGES[language]["mls"],
        language,
        count,
        cache,
        output,
        lock,
        text_column="transcript",
        identifier_column="id",
        speaker_column="speaker_id",
        duration_column="audio_duration",
    )


def prepare_voxpopuli(language: str, count: int, cache: Path, output: Path, lock: dict):
    return prepare_from_parquet(
        "voxpopuli",
        "facebook/voxpopuli",
        LANGUAGES[language]["voxpopuli"],
        language,
        count,
        cache,
        output,
        lock,
        # VoxPopuli's normalised text is the field its own baselines are scored
        # against; raw_text keeps the casing and punctuation for reference.
        text_column="normalized_text",
        identifier_column="audio_id",
        speaker_column="speaker_id",
        duration_column=None,
        verbatim_column="raw_text",
    )


def prepare_librispeech(language: str, count: int, cache: Path, output: Path, lock: dict):
    """Sample the already-pinned local LibriSpeech test-clean benchmark.

    It was downloaded and frozen for the English-only suite, so re-fetching it
    from OpenSLR would move eleven gigabytes to reproduce bytes that are already
    verified on disk.
    """
    del cache, lock
    source = LIBRISPEECH_BENCHMARK
    manifest = json.loads((source / "manifest-frozen.json").read_text())
    candidates = [
        {
            "id": item["id"],
            "text": item["reference"]["clean"],
            "audio": source / "audio" / item["audioPath"],
            "speaker": item["id"].split("-")[3] if item["id"].count("-") >= 4 else "unknown",
        }
        for item in manifest["items"]
        if "test-clean" in item["tags"]
    ]
    items = []
    directory = f"librispeech-{language}-test"
    for row in sample(candidates, "librispeech", language, count):
        identity = hashlib.sha256(f"librispeech\0{row['id']}".encode()).hexdigest()[:12]
        identifier = f"librispeech-{language}-{identity}"
        relative = f"{directory}/{identifier}.wav"
        duration = write_wav(row["audio"], output / "audio" / relative)
        if duration is None or not (
            MINIMUM_DURATION_SECONDS <= duration <= MAXIMUM_DURATION_SECONDS
        ):
            (output / "audio" / relative).unlink(missing_ok=True)
            continue
        items.append(
            manifest_item(
                "librispeech",
                language,
                identifier,
                relative,
                row["text"],
                f"librispeech-{language}-{row['speaker']}",
            )
        )
    return items


PREPARERS = {
    "fleurs": (prepare_fleurs, "fleurs"),
    "commonvoice": (prepare_common_voice, None),
    "mls": (prepare_mls, "mls"),
    "voxpopuli": (prepare_voxpopuli, "voxpopuli"),
    "librispeech": (prepare_librispeech, None),
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True, choices=sorted(PREPARERS))
    parser.add_argument("--language", required=True, choices=sorted(LANGUAGES))
    parser.add_argument("--samples", type=int, default=300)
    parser.add_argument("--cache-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    arguments = parser.parse_args()

    preparer, requirement = PREPARERS[arguments.corpus]
    if requirement and LANGUAGES[arguments.language][requirement] is None:
        raise SystemExit(
            f"{arguments.corpus} does not publish {arguments.language}; skipping."
        )

    lock_path = arguments.cache_root / "download-pins.json"
    lock = json.loads(lock_path.read_text()) if lock_path.exists() else {}

    items = preparer(
        arguments.language,
        arguments.samples,
        arguments.cache_root,
        arguments.output_root,
        lock,
    )
    if not items:
        raise SystemExit(f"No usable clips for {arguments.corpus}/{arguments.language}")

    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")

    items.sort(key=lambda item: item["id"])
    manifest = {
        "schemaVersion": 1,
        "benchmarkID": f"voxol-{arguments.corpus}-{arguments.language}-test",
        "normalizationVersion": "voxol-asr-normalizer-v1",
        "items": items,
    }
    arguments.output_root.mkdir(parents=True, exist_ok=True)
    destination = arguments.output_root / "manifest-unfrozen.json"
    destination.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"[ready] {arguments.corpus}/{arguments.language}: {len(items)} clips -> {destination}")


if __name__ == "__main__":
    main()
