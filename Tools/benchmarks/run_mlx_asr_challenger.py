#!/usr/bin/env python3
"""Run an MLX ASR challenger on a resumable local JSONL corpus."""

from __future__ import annotations

import argparse
import json
import resource
import time
from pathlib import Path

import mlx.core as mx
from mlx_audio.stt.utils import load_model


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--audio-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--language-mode",
        choices=("auto", "reference"),
        default="auto",
    )
    parser.add_argument("--limit", type=int)
    parser.add_argument("--max-duration", type=float)
    parser.add_argument("--id", action="append")
    parser.add_argument("--resume", action="store_true")
    return parser.parse_args()


def read_jsonl(path: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if line.strip():
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError as error:
                    raise ValueError(f"{path}:{line_number}: {error}") from error
    return records


def language_prompt(
    model_id: str,
    language: str | None,
    mode: str,
) -> str | None:
    if mode == "auto" or not language:
        return None
    normalized = language.lower().split("-", maxsplit=1)[0]
    if "qwen3-asr" in model_id.lower():
        return {"fr": "French", "en": "English"}.get(normalized)
    if "nemotron" in model_id.lower():
        return {"fr": "fr-FR", "en": "en-US"}.get(normalized)
    return normalized


def main() -> None:
    args = parse_args()
    items = read_jsonl(args.manifest)
    if args.id:
        requested_ids = set(args.id)
        items = [item for item in items if str(item["id"]) in requested_ids]
    if args.max_duration is not None:
        items = [
            item
            for item in items
            if float(item.get("audioDurationSeconds", 0)) <= args.max_duration
        ]
    if args.limit is not None:
        items = items[: args.limit]

    completed: set[str] = set()
    if args.resume and args.output.exists():
        completed = {
            str(item["id"])
            for item in read_jsonl(args.output)
            if item.get("status") == "ok"
        }

    load_started = time.perf_counter()
    model = load_model(args.model)
    load_milliseconds = (time.perf_counter() - load_started) * 1_000

    args.output.parent.mkdir(parents=True, exist_ok=True)
    mode = "a" if args.resume else "w"
    with args.output.open(mode, encoding="utf-8") as output:
        for index, item in enumerate(items, 1):
            item_id = str(item["id"])
            if item_id in completed:
                continue
            audio_path = args.audio_root / str(item["audioPath"])
            prompt = language_prompt(
                args.model,
                item.get("language"),
                args.language_mode,
            )
            mx.reset_peak_memory()
            started = time.perf_counter()
            try:
                generation_options: dict[str, object] = {
                    "language": prompt,
                    "verbose": False,
                }
                if "qwen3-asr" in args.model.lower():
                    generation_options["min_chunk_duration"] = 0.1
                result = model.generate(
                    str(audio_path),
                    **generation_options,
                )
                elapsed = (time.perf_counter() - started) * 1_000
                row = {
                    "schemaVersion": 1,
                    "status": "ok",
                    "id": item_id,
                    "model": args.model,
                    "languageMode": args.language_mode,
                    "languagePrompt": prompt,
                    "language": item.get("language"),
                    "audioPath": item["audioPath"],
                    "audioDurationSeconds": item.get("audioDurationSeconds"),
                    "referenceRawText": item.get("referenceRawText"),
                    "referenceFinalText": item.get("referenceFinalText"),
                    "transcript": result.text.strip(),
                    "detectedLanguage": getattr(result, "language", None),
                    "inferenceMilliseconds": round(elapsed, 3),
                    "realtimeFactor": (
                        float(item["audioDurationSeconds"]) * 1_000 / elapsed
                        if item.get("audioDurationSeconds") and elapsed
                        else None
                    ),
                    "modelLoadMilliseconds": round(load_milliseconds, 3)
                    if index == 1
                    else None,
                    "mlxPeakMemoryBytes": int(mx.get_peak_memory()),
                    "processPeakRSSBytes": int(
                        resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
                    ),
                }
            except Exception as error:
                elapsed = (time.perf_counter() - started) * 1_000
                row = {
                    "schemaVersion": 1,
                    "status": "error",
                    "id": item_id,
                    "model": args.model,
                    "languageMode": args.language_mode,
                    "languagePrompt": prompt,
                    "language": item.get("language"),
                    "audioPath": item["audioPath"],
                    "audioDurationSeconds": item.get("audioDurationSeconds"),
                    "referenceRawText": item.get("referenceRawText"),
                    "inferenceMilliseconds": round(elapsed, 3),
                    "errorType": type(error).__name__,
                    "error": str(error),
                }
            output.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
            output.flush()
            print(
                f"[{index}/{len(items)}] {item_id} "
                f"{row['status']} {row['inferenceMilliseconds']:.1f} ms",
                flush=True,
            )


if __name__ == "__main__":
    main()
