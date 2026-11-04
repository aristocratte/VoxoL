#!/usr/bin/env python3
"""Run native VoxoL components against a frozen campaign, without installing the app."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import resource
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools/benchmarks"))
import dictation_campaign as campaign


def tree_hash(path: Path) -> dict:
    if not path.is_dir():
        raise ValueError("Missing model directory: " + str(path))
    files = {str(p.relative_to(path)): campaign.file_digest(p) for p in sorted(path.rglob("*"))
             if p.is_file() and not any(part.startswith(".") for part in p.relative_to(path).parts)}
    if not files:
        raise ValueError("Empty model directory")
    return {"files": files, "sha256": campaign.digest(files)}


def invoke(command: list[str], output: Path, error: Path, timeout: int) -> tuple[int, float]:
    started = time.perf_counter()
    with output.open("x") as stdout, error.open("x") as stderr:
        try:
            result = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=timeout, check=False)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = 124
    return code, (time.perf_counter() - started) * 1000


def native_manifest(items: list[dict], identifier: str) -> dict:
    return {"schemaVersion": 1, "sourceManifestSHA256": identifier,
            "items": [{"id": item["id"], "audioPath": item["audioPath"],
                       "audioSHA256": item["audio"]["sha256"]} for item in items]}


def unique_rows(rows: list[dict], ids: set[str]) -> dict[str, dict]:
    found = {}
    for row in rows:
        if row.get("id") not in ids or row["id"] in found:
            raise ValueError("Unknown/duplicate ID in native output")
        found[row["id"]] = row
    return found


def run_parakeet(args: argparse.Namespace, items: list[dict], run: dict) -> tuple[list[dict], dict]:
    manifest_path = args.output / "native-audio-inputs.json"
    campaign.write_json(manifest_path, native_manifest(items, run["manifestSHA256"]))
    predictions = args.output / "native-predictions.jsonl"
    code, elapsed = invoke([str(args.binary), "infer-parakeet", "--manifest", str(manifest_path), "--audio-root", str(args.audio_root),
                           "--model-root", str(args.model), "--compute-units", args.compute_units, "--output", str(predictions)],
                          args.output / "native.stdout", args.output / "native.stderr", args.timeout)
    source = unique_rows(campaign.read_jsonl(predictions) if predictions.is_file() else [], {i["id"] for i in items})
    rows = []
    for item in items:
        old = source.get(item["id"])
        row = campaign.identity(item, run)
        if old is None:
            row.update(status="error", errorType="NotProduced", missingInference=True)
        else:
            row.update(status="ok", transcript=old["rawText"], inferenceMilliseconds=old["inferenceMilliseconds"],
                       confidence=old.get("confidence"), audioSeconds=item["audio"]["durationSeconds"])
        rows.append(row)
    return rows, {"exitCode": code, "processMilliseconds": elapsed,
                  "coldModelLoadMilliseconds": None,
                  "limitations": ["native CLI does not separately time model construction", "first inference may include lazy initialization",
                                  "raw ASR only; no reconstructed productText shortcut used"]}


def run_processor(args: argparse.Namespace, items: list[dict], run: dict, asr: dict) -> tuple[list[dict], dict]:
    cases = []
    for item in items:
        prediction = asr.get(item["id"], {})
        if prediction.get("status") == "ok":
            cases.append({"id": item["id"], "language": "auto", "fallbackLanguage": "fr", "mode": "faithful",
                          "transcript": prediction["transcript"], "expected": item["references"]["faithful"]["text"]})
    suite = args.output / "suite.json"
    campaign.write_json(suite, {"cases": cases})
    command = [str(args.binary), "--polisher-smoke", "--model", str(args.model), "--suite", str(suite)]
    if args.engine == "processor":
        command.append("--through-processor")
    if args.adapter:
        command.extend(["--adapter", str(args.adapter)])
    else:
        command.append("--without-adapter")
    output = args.output / "processor-output.json"
    code, elapsed = invoke(command, output, args.output / "processor.stderr", args.timeout)
    try:
        payload = json.loads(output.read_text())
    except json.JSONDecodeError:
        payload = {}
    found = unique_rows(payload.get("results", []), {case["id"] for case in cases})
    rows = []
    for item in items:
        old = found.get(item["id"])
        row = campaign.identity(item, run)
        if old is None:
            row.update(status="error", errorType="NotProduced", missingInference=True)
        else:
            if old["expected"] != item["references"]["faithful"]["text"]:
                raise ValueError("The processor changed a frozen reference")
            row.update(old)
            row.update(status="ok", transcript=asr[item["id"]]["transcript"],
                       inferenceMilliseconds=old["durationMilliseconds"])
        rows.append(row)
    metadata = {"exitCode": code, "processMilliseconds": elapsed,
                "coldModelLoadMilliseconds": None, "loadAndWarmupMilliseconds": payload.get("warmupDurationMilliseconds"),
                "adapterMode": payload.get("adapterMode"), "promptVersion": payload.get("promptVersion"),
                "limitations": ["loadAndWarmup includes both loading and warmup generation", "no microphone or application text insertion in this component run"]}
    return rows, metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", choices=("observed", "parakeet", "corrector", "processor"))
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--audio-root", type=Path, required=True)
    parser.add_argument("--split", choices=("diagnostic", "public"), default="diagnostic")
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--model-revision")
    parser.add_argument("--compute-units", choices=("ane", "gpu", "cpu", "all"), default="all")
    parser.add_argument("--adapter", type=Path)
    parser.add_argument("--asr-run", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=3600)
    args = parser.parse_args()
    os.umask(0o077)
    manifest = json.loads(args.manifest.read_text())
    campaign.validate(manifest, args.audio_root)
    items = campaign.select(manifest, args.split)
    if args.timeout < 1:
        parser.error("Timeout must be positive")
    if args.engine != "observed" and (not args.binary or not args.model or not args.model_revision):
        parser.error("Native inference requires --binary, --model and --model-revision")
    run = {"engine": args.engine, "manifestSHA256": manifest["manifestSHA256"], "split": args.split,
           "runnerSHA256": campaign.file_digest(Path(__file__)),
           "contractSHA256": campaign.file_digest(Path(campaign.__file__)),
           "platform": {"system": platform.system(), "release": platform.release(), "machine": platform.machine()},
           "parameters": {"languageHint": None, "vocabulary": [], "mode": "faithful",
                          "computeUnits": args.compute_units,
                          "fallbackLanguage": "fr", "processTimeoutSeconds": args.timeout,
                          "experimentalEnvironment": {
                              key: os.environ.get(key, "0") for key in (
                                  "VOXOL_ASR_EARLY_ENCODER_CACHE", "VOXOL_ASR_SEAM_ALIGNMENT")}}}
    if args.binary:
        args.binary = args.binary.resolve(strict=True)
        run["binarySHA256"] = campaign.file_digest(args.binary)
        metal = args.binary.parent.parent / "Resources/default.metallib"
        if metal.is_file():
            run["metalLibrarySHA256"] = campaign.file_digest(metal)
    if args.model:
        args.model = args.model.resolve(strict=True)
        run["model"] = {"revision": args.model_revision, **tree_hash(args.model)}
    if args.adapter:
        args.adapter = args.adapter.resolve(strict=True)
        run["adapter"] = tree_hash(args.adapter)
    else:
        run["adapter"] = None
    asr = {}
    if args.engine in ("corrector", "processor"):
        if args.asr_run is None:
            parser.error("Correction requires the same frozen --asr-run for every candidate")
        asr_config = json.loads((args.asr_run / "run.json").read_text())
        asr_path = args.asr_run / "predictions.jsonl"
        asr = campaign.validate_results(campaign.read_jsonl(asr_path), items, asr_config)
        run["asrPredictionsSHA256"] = campaign.file_digest(asr_path)
        run["asrRunSHA256"] = campaign.digest(asr_config)
    args.output.mkdir(parents=True, exist_ok=False)
    args.output.chmod(0o700)
    campaign.write_json(args.output / "run.json", run)
    if args.engine == "observed":
        rows = []
        for item in items:
            path = campaign.safe_audio_path(args.audio_root, item["audioPath"]).parent / "meta.json"
            if campaign.file_digest(path) != item["sourceMetaSHA256"]:
                raise ValueError("Capture metadata changed since freezing")
            old = json.loads(path.read_text())
            rows.append({**campaign.identity(item, run), "status": "ok", "transcript": str(old.get("rawText") or ""),
                         "finalText": str(old.get("finalText") or "")})
        metadata = {"kind": "historical captured output; not a rerun of the current code or a new timing measurement"}
    elif args.engine == "parakeet":
        rows, metadata = run_parakeet(args, items, run)
    else:
        rows, metadata = run_processor(args, items, run, asr)
    campaign.validate(manifest, args.audio_root)
    campaign.validate_results(rows, items, run)
    with (args.output / "predictions.jsonl").open("x") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + "\n")
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    metadata["childProcessPeakRSSBytes"] = rss if sys.platform == "darwin" else rss * 1024
    metadata["rssScope"] = "maximum over native subprocesses of this invocation; not total unified-memory footprint"
    campaign.write_json(args.output / "timing.json", metadata)
    stages = ["raw"] if args.engine == "parakeet" else ["raw", "final"] if args.engine == "observed" else ["raw", "normalized", "final"]
    for stage in stages:
        report = campaign.score(items, rows, run, stage)
        campaign.write_json(args.output / (stage + "-report.json"), report)
        print(stage, json.dumps(report["summary"]))


if __name__ == "__main__":
    main()
