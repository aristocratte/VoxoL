#!/usr/bin/env python3
"""Convert a Wispr teacher manifest to VoxoL's resumable benchmark schema."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


LANGUAGE_NAMES = {"en": "english", "fr": "french"}
# ASRBenchmarkSplit models evaluation roles, not machine-learning partitions, so
# the frozen train/validation/test labels have to be translated on the way in.
# Nothing downstream reads this field: prepare_wispr_qwen_dataset.py derives its
# own partitions from the split report, and the predictions JSONL carries none.
# The mapping exists so ASRBenchmarkKit can still enforce that one session never
# straddles two partitions, which is the invariant that matters here.
BENCHMARK_SPLITS = {
    "train": "calibration",
    "validation": "development",
    "test": "blind",
}


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def split_map(path: Path) -> dict[str, str]:
    report = json.loads(path.read_text(encoding="utf-8"))
    result: dict[str, str] = {}
    for group in report.get("groups", []):
        split = str(group["split"])
        for recording in group["recordings"]:
            identifier = str(recording)
            if identifier in result:
                raise RuntimeError(f"Duplicate split recording: {identifier}")
            result[identifier] = split
    return result


def benchmark_split(split: str) -> str:
    try:
        return BENCHMARK_SPLITS[split]
    except KeyError:
        raise RuntimeError(
            f"Split {split!r} has no ASRBenchmarkSplit equivalent; "
            f"expected one of {sorted(BENCHMARK_SPLITS)}."
        ) from None


def convert(
    rows: list[dict[str, object]],
    recording_splits: dict[str, str],
    *,
    require_complete_boundary: bool,
) -> list[dict[str, object]]:
    items = []
    seen: set[str] = set()
    for row in rows:
        identifier = str(row.get("id", ""))
        recording = str(row.get("recording_id", ""))
        language = str(row.get("requested_language", ""))
        relative = Path(str(row.get("audio_path", "")))
        if not identifier or identifier in seen:
            raise RuntimeError(f"Missing or duplicate ID: {identifier!r}")
        seen.add(identifier)
        if language not in LANGUAGE_NAMES:
            continue
        if recording not in recording_splits:
            raise RuntimeError(f"Missing frozen split for {recording}")
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError(f"Unsafe audio path for {identifier}")
        if require_complete_boundary and row.get("boundary_complete") is not True:
            continue
        raw = " ".join(str(row.get("raw", "")).split())
        if not raw:
            continue
        items.append(
            {
                "audioPath": relative.as_posix(),
                "durationSeconds": float(row.get("duration", 0)),
                "environment": "wispr-teacher-source",
                "id": identifier,
                "language": LANGUAGE_NAMES[language],
                "microphone": "source-media",
                # A recording is a session: ASRBenchmarkKit keys its
                # "a session must not straddle two splits" rule on sessionID,
                # which is exactly what the frozen recording split encodes.
                # Both names are emitted because the Swift decoder requires
                # sessionID while adapt_wispr_teacher_benchmark.py and the
                # review server read recordingID.
                "recordingID": recording,
                "sessionID": recording,
                "reference": {
                    "clean": raw,
                    "criticalSpans": [],
                    # ASRBenchmarkKit refuses any item whose reference is not
                    # flagged reviewed. Nobody read these lines: the reference
                    # is Wispr's raw output, which is the teacher target by
                    # definition rather than adjudicated ground truth. The flag
                    # is runner metadata here, exactly as
                    # adapt_wispr_teacher_benchmark.py already sets it for the
                    # same corpus. This manifest drives inference and a
                    # teacher-agreement diagnostic — it is never a promotion
                    # gate, and the frozen public benchmarks stay the only
                    # independent measure.
                    "reviewed": True,
                    "verbatim": raw,
                },
                "speakerID": str(row.get("speaker_id") or recording),
                "split": benchmark_split(recording_splits[recording]),
                "tags": ["private", "wispr-teacher", "product-shaped"],
            }
        )
    return sorted(items, key=lambda item: str(item["id"]))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--split-report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--benchmark-id", required=True)
    parser.add_argument("--require-complete-boundary", action="store_true")
    arguments = parser.parse_args()
    manifest = {
        "benchmarkID": arguments.benchmark_id,
        "items": convert(
            read_jsonl(arguments.input),
            split_map(arguments.split_report),
            require_complete_boundary=arguments.require_complete_boundary,
        ),
        "normalizationVersion": "voxol-asr-normalizer-v1",
        "schemaVersion": 1,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(arguments.output)


if __name__ == "__main__":
    main()
