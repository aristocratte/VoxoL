#!/usr/bin/env python3
"""Score MOSS-Transcribe-Diarize on a frozen VoxoL benchmark.

The meeting mode needs a model that transcribes *and* separates speakers, and
MOSS-Transcribe-Diarize is the strongest Apache-2.0 candidate. Its card claims
50+ languages while its metadata declares only English and Chinese, so its
French is an open question — and French is the one language this product cannot
be mediocre in.

This runs it over a benchmark's audio, strips the timestamp and speaker markup
down to plain text, and emits the JSONL the Swift scorer consumes, so MOSS is
measured on exactly the same footing as VoxoL and Wispr.

Usage:
    ./benchmark-moss-diarize.py --manifest <frozen.json> --audio-root <dir> \\
        --count 100 --output-root <dir>
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


# `[12.34]` timestamps and `[S01]` speaker tags wrap every segment.
MARKUP = re.compile(r"\[(?:\d+(?:\.\d+)?|S\d+)\]")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--manifest", type=Path, required=True)
    result.add_argument("--audio-root", type=Path, required=True)
    result.add_argument("--count", type=int, default=100)
    result.add_argument("--model", default="OpenMOSS-Team/MOSS-Transcribe-Diarize")
    result.add_argument("--device", default="mps")
    result.add_argument("--output-root", type=Path, required=True)
    result.add_argument(
        "--python",
        default=".build/moss-venv/bin/python",
        help="Interpreter with moss_transcribe_diarize installed.",
    )
    return result


def plain_text(raw: str) -> str:
    """Strip diarization markup, leaving the words the scorer compares."""
    return " ".join(MARKUP.sub(" ", raw).split())


def speaker_count(raw: str) -> int:
    return len(set(re.findall(r"\[S(\d+)\]", raw)))


def main() -> int:
    arguments = parser().parse_args()
    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    # Deterministic stride rather than the first N, so the sample spans the
    # whole corpus instead of one alphabetical corner of it.
    items = manifest["items"]
    stride = max(1, len(items) // arguments.count)
    selected = items[::stride][: arguments.count]

    arguments.output_root.mkdir(parents=True, exist_ok=True)
    predictions = arguments.output_root / "predictions.jsonl"
    rows = []
    speakers = []
    elapsed_total = 0.0
    with tempfile.TemporaryDirectory() as staging_root:
        staging = Path(staging_root)
        for index, item in enumerate(selected, 1):
            source = arguments.audio_root / item["audioPath"]
            wav = staging / "clip.wav"
            subprocess.run(
                ["ffmpeg", "-v", "error", "-y", "-i", str(source),
                 "-ac", "1", "-ar", "16000", str(wav)],
                check=True,
            )
            out = staging / "out"
            shutil.rmtree(out, ignore_errors=True)
            started = time.perf_counter()
            completed = subprocess.run(
                [
                    arguments.python, "-m", "moss_transcribe_diarize.app.cli",
                    str(wav), "--model", arguments.model,
                    "--device", arguments.device, "--out-dir", str(out),
                ],
                capture_output=True,
                text=True,
            )
            elapsed = time.perf_counter() - started
            elapsed_total += elapsed
            transcript = out / "raw_transcript.txt"
            if completed.returncode != 0 or not transcript.is_file():
                print(f"  [{index}/{len(selected)}] ECHEC {item['id']}", flush=True)
                text = ""
            else:
                raw = transcript.read_text(encoding="utf-8")
                text = plain_text(raw)
                speakers.append(speaker_count(raw))
            rows.append(
                {
                    "id": item["id"],
                    "rawText": text,
                    "finalText": text,
                    "confidence": {
                        "blankDecisionRatio": 0.0,
                        "emittedTokenCount": len(text.split()),
                        "inferenceAttemptCount": 1,
                        "lowerDecileDurationLogitMargin": 0.0,
                        "lowerDecileTokenLogitMargin": 0.0,
                        "maximumFramesWithoutEmission": 0,
                        "meanDurationLogitMargin": 0.0,
                        "meanTokenLogitMargin": 0.0,
                        "usedFallbackSegmentation": False,
                    },
                    "inferenceMilliseconds": elapsed * 1000,
                }
            )
            print(f"  [{index}/{len(selected)}] {elapsed:5.1f}s {item['id'][-12:]}", flush=True)

    predictions.write_text(
        "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows),
        encoding="utf-8",
    )
    subset = dict(manifest)
    subset["items"] = selected
    subset.pop("contentSHA256", None)
    subset.pop("frozenAt", None)
    (arguments.output_root / "subset-manifest.json").write_text(
        json.dumps(subset, ensure_ascii=False), encoding="utf-8"
    )
    summary = {
        "clipCount": len(selected),
        "meanSecondsPerClip": elapsed_total / max(1, len(selected)),
        "meanSpeakersDetected": (sum(speakers) / len(speakers)) if speakers else None,
        "predictions": str(predictions),
        "subsetManifest": str(arguments.output_root / "subset-manifest.json"),
    }
    (arguments.output_root / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
