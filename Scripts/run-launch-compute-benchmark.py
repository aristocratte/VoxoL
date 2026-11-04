#!/usr/bin/env python3
"""Compare Core ML compute policies on a frozen, public, audio-only cohort.

No weights are changed and no reference is passed to inference. This is an ASR
component experiment, not an end-to-end dictation or battery benchmark.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools/benchmarks"))
import dictation_campaign as c


def command_value(command: list[str]) -> str | None:
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL, timeout=10).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def environment() -> dict:
    return {
        "utc": datetime.now(timezone.utc).isoformat(),
        "os": command_value(["sw_vers", "-productVersion"]),
        "chip": command_value(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "memoryBytes": command_value(["sysctl", "-n", "hw.memsize"]),
        "power": command_value(["pmset", "-g", "batt"]),
        "thermal": command_value(["pmset", "-g", "therm"]),
        "load": command_value(["sysctl", "-n", "vm.loadavg"]),
    }


def verify_weights(model_root: Path) -> dict:
    registry = json.loads((ROOT / "Models/manifests/runtime-models.json").read_text())
    spec = next(m for m in registry["models"] if m["role"] == "asr")
    verified = {}
    for item in spec["artifact"]["files"]:
        path = model_root / item["path"]
        actual = c.file_digest(path)
        if actual != item["sha256"]:
            raise ValueError("Installed ASR artifact does not match registry: " + item["path"])
        verified[item["path"]] = actual
    return {"sourceRevision": spec["revision"], "provider": spec["artifact"]["provider"],
            "files": verified, "treeSHA256": c.digest(verified)}


def stats(values: list[float]) -> dict:
    if any(isinstance(v, bool) or not math.isfinite(v) or v < 0 for v in values):
        raise ValueError("Invalid timing sample")
    return {"count": len(values), "p50": statistics.median(values) if values else None,
            "p95": c.percentile(values, .95), "minimum": min(values) if values else None,
            "maximum": max(values) if values else None}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=ROOT / ".build/precision-fleurs-v1/manifest.json")
    parser.add_argument("--audio-root", type=Path, default=ROOT / ".build/precision-fleurs-source/audio")
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/debug/voxol-asr-benchmark")
    parser.add_argument("--model", type=Path, default=Path.home() / "Library/Application Support/VoxoL/Models/asr/7c35754d166cca382ad1e53e68b01e7c575f3a1d")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if not 2 <= args.rounds <= 12:
        parser.error("Use 2..12 rounds; one round cannot support an order-controlled comparison")
    manifest = json.loads(args.manifest.read_text())
    c.validate(manifest, args.audio_root)
    items = c.select(manifest, "public")
    if any(i["references"]["verbatim"]["provenance"]["kind"] != "public" for i in items):
        raise ValueError("This launch experiment accepts public references only")
    binary = args.binary.resolve(strict=True)
    weights = verify_weights(args.model)
    args.output.mkdir(parents=True, exist_ok=False)
    orders = [("all", "gpu", "ane"), ("gpu", "ane", "all"), ("ane", "all", "gpu")]
    frozen = {
        "schemaVersion": "voxol-compute-experiment-v1", "environment": environment(),
        "manifestSHA256": manifest["manifestSHA256"], "binarySHA256": c.file_digest(binary),
        "runnerSHA256": c.file_digest(Path(__file__)), "contractSHA256": c.file_digest(Path(c.__file__)),
        "weights": weights, "rounds": args.rounds, "orders": [orders[r % 3] for r in range(args.rounds)],
        "hypothesis": "A different compute policy may reduce current M4 ASR inference latency without changing text.",
        "successCriteria": {"minimumP50Reduction": .10, "maximumP95Regression": .05,
                            "requiredExactTranscriptParity": True, "allowedFailures": 0},
        "scope": "ASR component, file import, same 40-source public regression cohort; no microphone, correction or insertion",
        "cachePolicy": "fresh process per variant; existing Core ML compilation caches preserved; first item reported separately",
        "statistics": "p50 arithmetic median; p95 nearest rank; repetitions are timings, not additional independent audio sources",
        "limitations": ["Mac is not exclusively reserved", "no energy measurement", "no per-model cold-load timer", "no automatic promotion"],
    }
    c.write_json(args.output / "experiment.json", frozen)
    native = {"schemaVersion": 1, "sourceManifestSHA256": manifest["manifestSHA256"],
              "items": [{"id": i["id"], "audioPath": i["audioPath"], "audioSHA256": i["audio"]["sha256"]} for i in items]}
    c.write_json(args.output / "audio-inputs.json", native)
    reference = {i["id"]: i for i in items}
    results = []
    for round_index, order in enumerate(frozen["orders"]):
        for units in order:
            name = f"round-{round_index + 1}-{units}"
            path = args.output / name
            path.mkdir()
            before = environment()
            output = path / "predictions.jsonl"
            command = [str(binary), "infer-parakeet", "--manifest", str(args.output / "audio-inputs.json"),
                       "--audio-root", str(args.audio_root), "--model-root", str(args.model),
                       "--compute-units", units, "--output", str(output)]
            start = time.perf_counter()
            with (path / "stdout.log").open("x") as stdout, (path / "stderr.log").open("x") as stderr:
                try:
                    process = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=300, check=False)
                    exit_code = process.returncode
                except subprocess.TimeoutExpired:
                    exit_code = 124
            rows = c.read_jsonl(output) if output.is_file() else []
            found = {}
            for row in rows:
                if row["id"] in found or row["id"] not in reference:
                    raise ValueError("Unknown or duplicate prediction")
                found[row["id"]] = row
            scored = []
            for identifier, item in reference.items():
                row = found.get(identifier)
                actual = row["rawText"] if row else ""
                scored.append({"id": identifier, "missing": row is None,
                               "textSHA256": hashlib.sha256(actual.encode()).hexdigest(),
                               **c.edit_counts(c.words(item["references"]["verbatim"]["text"]), c.words(actual))})
            samples = [r["inferenceMilliseconds"] for r in rows]
            record = {"variant": units, "round": round_index + 1, "exitCode": exit_code,
                      "processMilliseconds": (time.perf_counter() - start) * 1000,
                      "environmentBefore": before, "environmentAfter": environment(),
                      "latencyMilliseconds": stats(samples), "firstInferenceMilliseconds": samples[0] if samples else None,
                      "subsequentInferenceMilliseconds": stats(samples[1:]),
                      "missing": len(items) - len(found), "rows": scored,
                      "predictionsSHA256": c.file_digest(output) if output.is_file() else None}
            c.write_json(path / "result.json", record)
            results.append(record)
            print(name, json.dumps({k: record[k] for k in ["exitCode", "latencyMilliseconds", "missing"]}), flush=True)
    baseline = next(r for r in results if r["variant"] == "all")
    hashes = {r["id"]: r["textSHA256"] for r in baseline["rows"]}
    variants = {}
    for units in ("all", "gpu", "ane"):
        runs = [r for r in results if r["variant"] == units]
        variants[units] = {"rounds": len(runs), "sources": len(items),
                           "timingObservations": sum(r["latencyMilliseconds"]["count"] for r in runs),
                           "medianOfRunP50": statistics.median(r["latencyMilliseconds"]["p50"] for r in runs if r["latencyMilliseconds"]["p50"] is not None) if any(r["latencyMilliseconds"]["p50"] is not None for r in runs) else None,
                           "medianOfRunP95": statistics.median(r["latencyMilliseconds"]["p95"] for r in runs if r["latencyMilliseconds"]["p95"] is not None) if any(r["latencyMilliseconds"]["p95"] is not None for r in runs) else None,
                           "exactTranscriptDifferences": sum(row["textSHA256"] != hashes[row["id"]] for r in runs for row in r["rows"]),
                           "missing": sum(r["missing"] for r in runs), "failedRuns": sum(r["exitCode"] != 0 for r in runs),
                           "errorsPerRun": [sum(row["errors"] for row in r["rows"]) for r in runs],
                           "referenceWordsPerRun": sum(row["referenceWords"] for row in baseline["rows"])}
    if verify_weights(args.model) != weights or c.file_digest(binary) != frozen["binarySHA256"]:
        raise ValueError("Weights or executable changed during experiment")
    c.validate(manifest, args.audio_root)
    c.write_json(args.output / "summary.json", {"experimentSHA256": c.file_digest(args.output / "experiment.json"),
                 "variants": variants, "promotionAllowed": False,
                 "remaining": "Compare product insertion, long dictations, thermals and independent quality before changing production"})
    print(json.dumps(variants, indent=2))


if __name__ == "__main__":
    main()
