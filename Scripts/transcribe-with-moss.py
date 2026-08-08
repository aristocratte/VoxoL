#!/usr/bin/env python3
"""Transcribe many clips with MOSS-Transcribe-Diarize in one process.

The obvious approach — call the package's CLI per clip — reloads 1.8 GB of
weights every time. On a 100-clip run that dominated the wall clock and drove
the machine deep into swap, which made the resulting "13 s per clip" a
measurement of model loading rather than of inference.

This loads the model once and streams clips through it, releasing the Metal
cache between items and stopping early if the machine runs short of memory.
Output is appended as it goes, so an interrupted run resumes instead of
restarting.

Usage:
    ./transcribe-with-moss.py --input <sample.json> --output <moss.jsonl>

`--input` is a JSON list of objects carrying at least `id` and `audio`.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


# `[12.34]` timestamps and `[S01]` speaker tags wrap each emitted segment.
MARKUP = re.compile(r"\[(?:\d+(?:\.\d+)?|S\d+)\]")
# Below this fraction of free system memory, stop rather than push the machine
# into swap and make every other process on it miserable.
MINIMUM_FREE_FRACTION = 0.15


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--input", type=Path, required=True)
    result.add_argument("--output", type=Path, required=True)
    result.add_argument("--model", default="OpenMOSS-Team/MOSS-Transcribe-Diarize")
    result.add_argument("--device", default="auto")
    result.add_argument("--max-new-tokens", type=int, default=2048)
    result.add_argument("--limit", type=int)
    return result


def free_memory_fraction() -> float:
    """Share of system memory not currently in use, or 1.0 if unknown."""
    try:
        output = subprocess.run(
            ["memory_pressure"], capture_output=True, text=True, timeout=10
        ).stdout
        match = re.search(r"free percentage:\s*(\d+)", output)
        return int(match.group(1)) / 100 if match else 1.0
    except (OSError, subprocess.SubprocessError):
        return 1.0


def plain_text(raw: str) -> str:
    return " ".join(MARKUP.sub(" ", raw).split())


def main() -> int:
    arguments = parser().parse_args()
    items = json.loads(arguments.input.read_text(encoding="utf-8"))
    if arguments.limit:
        items = items[: arguments.limit]

    done = set()
    if arguments.output.exists():
        for line in arguments.output.read_text(encoding="utf-8").splitlines():
            if line.strip():
                done.add(json.loads(line)["id"])
    pending = [item for item in items if item["id"] not in done]
    print(f"{len(pending)} a traiter ({len(done)} deja faits)", flush=True)
    if not pending:
        return 0

    import torch
    from transformers import AutoModelForCausalLM, AutoProcessor
    from moss_transcribe_diarize.inference_utils import (
        build_transcription_messages,
        generate_transcription,
        resolve_device,
    )

    device = resolve_device(arguments.device)
    # bfloat16 on Metal still falls back to float32 for several ops; keeping the
    # model in float32 avoids a per-clip conversion and its allocation churn.
    dtype = torch.bfloat16 if device.type == "cuda" else torch.float32
    print(f"chargement du modele sur {device} ({dtype})...", flush=True)
    model = (
        AutoModelForCausalLM.from_pretrained(
            arguments.model, trust_remote_code=True, dtype="auto"
        )
        .to(dtype=dtype)
        .to(device)
        .eval()
    )
    processor = AutoProcessor.from_pretrained(arguments.model, trust_remote_code=True)
    print("modele charge", flush=True)

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    processed = 0
    with arguments.output.open("a", encoding="utf-8") as sink, tempfile.TemporaryDirectory() as raw_tmp:
        tmp = Path(raw_tmp)
        for index, item in enumerate(pending, 1):
            free = free_memory_fraction()
            if free < MINIMUM_FREE_FRACTION:
                print(
                    f"ARRET: memoire libre {free:.0%} sous le seuil de "
                    f"{MINIMUM_FREE_FRACTION:.0%}; {len(pending) - index + 1} restants",
                    flush=True,
                )
                break

            wav = tmp / "clip.wav"
            subprocess.run(
                ["ffmpeg", "-v", "error", "-y", "-i", str(item["audio"]),
                 "-ac", "1", "-ar", "16000", str(wav)],
                check=True,
            )
            elapsed_start = time.perf_counter()
            try:
                messages = build_transcription_messages(wav)
                result = generate_transcription(
                    model,
                    processor,
                    messages,
                    max_new_tokens=arguments.max_new_tokens,
                    do_sample=False,
                )
                raw = result["text"] if isinstance(result, dict) else str(result)
                text = plain_text(raw)
            except Exception as error:  # noqa: BLE001 - one bad clip must not end the run
                print(f"  [{index}] echec {item['id']}: {type(error).__name__}", flush=True)
                text = ""
            elapsed = time.perf_counter() - elapsed_start

            sink.write(
                json.dumps(
                    {"id": item["id"], "moss": text, "seconds": round(elapsed, 3)},
                    ensure_ascii=False,
                )
                + "\n"
            )
            sink.flush()
            processed += 1
            if hasattr(torch, "mps") and device.type == "mps":
                torch.mps.empty_cache()
            print(f"  [{index}/{len(pending)}] {elapsed:5.2f}s  libre {free:.0%}", flush=True)

    total = time.perf_counter() - started
    print(
        f"\n{processed} traites en {total / 60:.1f} min "
        f"({total / max(1, processed):.2f} s/clip)",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
