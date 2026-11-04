#!/usr/bin/env python3
"""Run an MLX ASR challenger on a resumable local JSONL corpus."""

from __future__ import annotations

import argparse
from importlib.metadata import PackageNotFoundError, version
import json
import os
import platform
import resource
import subprocess
import sys
import time
from pathlib import Path

import dictation_campaign as campaign


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
    parser.add_argument("--campaign", action="store_true", help="Use the frozen, content-bound campaign contract")
    parser.add_argument("--revision", help="Exact converted model revision (required with --campaign)")
    parser.add_argument("--model-id", help="Public provider ID, separate from the local model path")
    parser.add_argument("--split", choices=("diagnostic", "public"), default="diagnostic")
    parser.add_argument("--max-tokens", type=int, default=2048, help="Qwen campaign decoding ceiling")
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
    if args.campaign:
        run_campaign(args)
        return
    if args.resume:
        raise ValueError("ID-only legacy resume is unsafe. Use a frozen --campaign and a new output directory.")
    if args.output.exists():
        raise FileExistsError("Refusing to overwrite existing predictions")
    import mlx.core as mx
    from mlx_audio.stt.utils import load_model
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

    load_started = time.perf_counter()
    model = load_model(args.model)
    load_milliseconds = (time.perf_counter() - load_started) * 1_000

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x", encoding="utf-8") as output:
        for index, item in enumerate(items, 1):
            item_id = str(item["id"])
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
                    "realtimeSpeedup": (
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


def campaign_options(model_id: str, max_tokens: int) -> dict:
    options = {"language": None, "verbose": False, "temperature": 0.0}
    if "qwen3-asr" in model_id.lower():
        options.update(min_chunk_duration=0.1, max_tokens=max_tokens)
    return options


def run_campaign(args: argparse.Namespace) -> None:
    if args.language_mode != "auto" or args.limit is not None or args.max_duration is not None or args.id:
        raise ValueError("Campaign candidates must use the entire frozen split without reference-language hints")
    if not args.revision or len(args.revision) != 40 or any(c not in "0123456789abcdef" for c in args.revision):
        raise ValueError("--revision must be the exact 40-character model commit")
    if args.max_tokens < 1 or args.output.name != "predictions.jsonl":
        raise ValueError("Use a positive token ceiling and RUN_DIRECTORY/predictions.jsonl")
    model_root = Path(args.model).resolve(strict=True)
    if not model_root.is_dir():
        raise ValueError("Campaigns load a pinned local snapshot, not a moving Hub model")
    manifest = json.loads(args.manifest.read_text())
    campaign.validate(manifest, args.audio_root)
    items = campaign.select(manifest, args.split)
    model_files = {str(p.relative_to(model_root)): campaign.file_digest(p) for p in sorted(model_root.rglob("*"))
                   if p.is_file() and not any(part.startswith(".") for part in p.relative_to(model_root).parts)}
    if not any(p.endswith(".safetensors") for p in model_files):
        raise ValueError("The local model snapshot has no weights")
    packages = {}
    for name in ("mlx-audio", "mlx", "mlx-metal", "transformers", "tokenizers", "huggingface-hub", "numpy", "scipy"):
        try:
            packages[name] = version(name)
        except PackageNotFoundError:
            packages[name] = None
    model_id = args.model_id or model_root.name
    options = campaign_options(model_id, args.max_tokens)
    run = {"engine": "mlx-audio", "modelID": model_id, "revision": args.revision,
           "modelFiles": model_files, "modelSHA256": campaign.digest(model_files),
           "manifestSHA256": manifest["manifestSHA256"], "split": args.split,
           "parameters": options, "seed": 1729, "dependencies": packages,
           "mlxCacheLimitBytes": 64 * 1024 * 1024,
           "runnerSHA256": campaign.file_digest(Path(__file__)),
           "contractSHA256": campaign.file_digest(Path(campaign.__file__)),
           "pythonVersion": platform.python_version(), "platform": platform.platform(),
           "hardware": {
               "chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
               "ramBytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
           } if sys.platform == "darwin" else {"chip": None, "ramBytes": None}}
    os.umask(0o077)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.parent.chmod(0o700)
    run_path = args.output.parent / "run.json"
    if run_path.exists():
        if not args.resume or json.loads(run_path.read_text()) != run:
            raise ValueError("Existing run differs or --resume was not supplied; use a new run directory")
    else:
        if args.output.exists():
            raise ValueError("Predictions without matching provenance cannot be resumed")
        campaign.write_json(run_path, run)
    previous = campaign.read_jsonl(args.output) if args.output.exists() else []
    completed = campaign.validate_results(previous, items, run)
    pending = [item for item in items if item["id"] not in completed]
    if not pending:
        print("All results already present, including recorded failures; no inference repeated.")
        return
    # Downloads happen separately. Only audio paths, never references or their
    # language annotations, cross the generate() boundary.
    import mlx.core as mx
    from mlx_audio.stt.utils import load_model
    mx.set_cache_limit(run["mlxCacheLimitBytes"])
    started = time.perf_counter()
    model = None
    load_error = None
    try:
        model = load_model(str(model_root))
        mx.eval(model.parameters())
        mx.synchronize()
    except Exception as error:
        load_error = error
    load_ms = (time.perf_counter() - started) * 1000
    timings = []
    with args.output.open("a" if args.resume else "x", encoding="utf-8") as output:
        for index, item in enumerate(pending):
            row = campaign.identity(item, run)
            started = time.perf_counter()
            try:
                if load_error is not None:
                    raise load_error
                mx.random.seed(1729)
                mx.reset_peak_memory()
                audio_path = campaign.safe_audio_path(args.audio_root, item["audioPath"])
                if campaign.file_digest(audio_path) != item["audio"]["sha256"]:
                    raise ValueError("Audio changed after campaign validation")
                result = model.generate(str(audio_path), **options)
                mx.synchronize()
                elapsed = (time.perf_counter() - started) * 1000
                row.update(status="ok", transcript=result.text, detectedLanguage=getattr(result, "language", None),
                           generationTokens=getattr(result, "generation_tokens", None),
                           inferenceMilliseconds=elapsed, phase="first-inference" if index == 0 else "warm",
                           realtimeFactor=elapsed / (item["audio"]["durationSeconds"] * 1000),
                           mlxPeakMemoryBytes=int(mx.get_peak_memory()),
                           processPeakRSSBytes=int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss) * (1 if sys.platform == "darwin" else 1024))
                if "max_tokens" in options and getattr(result, "generation_tokens", 0) >= options["max_tokens"]:
                    row.update(failure="generationTokenLimit", truncated=True)
            except Exception as error:
                row.update(status="error", errorType=type(error).__name__, error=str(error),
                           inferenceMilliseconds=(time.perf_counter() - started) * 1000)
            output.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + "\n")
            output.flush()
            timings.append(row["inferenceMilliseconds"])
            print(f"[{index + 1}/{len(pending)}] {row['status']} {row['inferenceMilliseconds']:.1f} ms", flush=True)
    campaign.validate(manifest, args.audio_root)
    all_rows = campaign.read_jsonl(args.output)
    report = campaign.score(items, all_rows, run)
    campaign.write_json(args.output.parent / "raw-report.json", report, exclusive=False)
    attempt = len(list(args.output.parent.glob("timing-*.json"))) + 1
    campaign.write_json(args.output.parent / f"timing-{attempt}.json", {
        "runSHA256": campaign.digest(run), "modelLoadMilliseconds": load_ms, "attempted": len(pending),
        "firstInferenceMilliseconds": timings[0], "warmInferenceP50Milliseconds": campaign.percentile(timings[1:], .5),
        "warmInferenceP95Milliseconds": campaign.percentile(timings[1:], .95), "loadedSuccessfully": load_error is None,
        "limitations": ["process-cold, not a reboot or cold filesystem-cache measurement", "process RSS is cumulative; MLX allocator peak is separate",
                        "external Python runtime; not proof of Core ML or MLX Swift integration"]})
    print(json.dumps(report["summary"]))


if __name__ == "__main__":
    main()
