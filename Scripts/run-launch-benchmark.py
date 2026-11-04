#!/usr/bin/env python3
"""Reproduce the launch cache experiment locally; never uploads recordings."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
from datetime import datetime, timezone


RUNTIME_SUPPORT_COMPONENTS = (
    "decoder.mlpackage",
    "joint.mlpackage",
    "tokenizer.json",
    "language-penalty.json",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_sha256(path: Path) -> str:
    if path.is_file():
        return sha256(path)
    digest = hashlib.sha256()
    for child in sorted(p for p in path.rglob("*") if p.is_file()):
        relative = child.relative_to(path).as_posix().encode()
        digest.update(relative)
        digest.update(b"\0")
        with child.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        digest.update(b"\0")
    return digest.hexdigest()


def verify_registry_model_files(model_root: Path, model: dict) -> list[dict]:
    checked_files = []
    for entry in model["artifact"]["files"]:
        path = model_root / entry["path"]
        if not path.is_file():
            raise FileNotFoundError(f"Missing registered model file: {path}")
        actual = sha256(path)
        if actual != entry["sha256"]:
            raise ValueError(f"Model bytes differ from the registry: {entry['path']}")
        checked_files.append({"path": entry["path"], "sha256": actual})
    return checked_files


def verify_encoder_candidate_model(reference_root: Path, candidate_root: Path) -> dict:
    reference_encoder = reference_root / "encoder.mlpackage"
    candidate_encoder = candidate_root / "encoder.mlpackage"
    if not reference_encoder.is_dir():
        raise FileNotFoundError(f"Missing reference encoder: {reference_encoder}")
    if not candidate_encoder.is_dir():
        raise FileNotFoundError(f"Missing candidate encoder: {candidate_encoder}")

    support = []
    for component in RUNTIME_SUPPORT_COMPONENTS:
        reference = reference_root / component
        candidate = candidate_root / component
        if not reference.exists():
            raise FileNotFoundError(f"Missing reference runtime support: {reference}")
        if not candidate.exists():
            raise FileNotFoundError(f"Missing candidate runtime support: {candidate}")
        reference_hash = tree_sha256(reference)
        candidate_hash = tree_sha256(candidate)
        if candidate_hash != reference_hash:
            raise ValueError(
                f"Candidate runtime support differs from reference: {component}"
            )
        support.append({"path": component, "sha256": reference_hash})

    reference_encoder_hash = tree_sha256(reference_encoder)
    candidate_encoder_hash = tree_sha256(candidate_encoder)
    if candidate_encoder_hash == reference_encoder_hash:
        raise ValueError("Candidate encoder is byte-identical to the reference encoder")

    quantization_report = candidate_root / "quantization-report.json"
    return {
        "referenceEncoderSHA256": reference_encoder_hash,
        "candidateEncoderSHA256": candidate_encoder_hash,
        "runtimeSupport": support,
        "candidateQuantizationReportSHA256": (
            sha256(quantization_report) if quantization_report.is_file() else None
        ),
    }


def verify_encoder_window_runtime(blocks: list[dict]) -> dict:
    capacities: dict[str, set[int]] = {"baseline": set(), "candidate": set()}
    for block in blocks:
        variant = block.get("variant")
        value = block.get("maximumWaveformSampleCount")
        if variant in capacities and isinstance(value, int) and value > 0:
            capacities[variant].add(value)
    if any(len(values) != 1 for values in capacities.values()):
        raise RuntimeError(
            "encoder-window-root requires one stable positive waveform capacity "
            "for both baseline and candidate; rebuild the smoke CLI if this field is missing"
        )
    baseline = next(iter(capacities["baseline"]))
    candidate = next(iter(capacities["candidate"]))
    if candidate >= baseline:
        raise RuntimeError(
            "encoder-window-root candidate must expose a shorter waveform capacity "
            f"than the baseline ({candidate} >= {baseline})"
        )
    return {
        "referenceMaximumWaveformSampleCount": baseline,
        "candidateMaximumWaveformSampleCount": candidate,
        "reductionSamples": baseline - candidate,
        "reductionPercent": ((baseline - candidate) / baseline) * 100,
    }


def command_output(*arguments: str) -> str:
    result = subprocess.run(arguments, capture_output=True, text=True, check=False)
    return result.stdout.strip() or result.stderr.strip()


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) - 1) * q
    low, high = math.floor(index), math.ceil(index)
    return ordered[low] + (ordered[high] - ordered[low]) * (index - low)


def summarize(rows: list[dict]) -> list[dict]:
    groups: dict[tuple, list[dict]] = {}
    for row in rows:
        duration = row.get("audioSeconds")
        scenario = "unknown" if duration is None else (
            "short-under-20s" if duration < 20 else "medium-20-60s" if duration <= 60 else "long-over-60s"
        )
        groups.setdefault((row["variant"], row["cached"], scenario), []).append(row)
    summaries = []
    for (variant, cached, scenario), items in sorted(groups.items()):
        good = [r for r in items if r.get("status") == "ok"]
        values = [r["wallMilliseconds"] for r in good]
        summaries.append({
            "variant": variant, "cached": cached, "scenario": scenario,
            "attempts": len(items), "failures": len(items) - len(good),
            "uniqueAudioSources": len({r["id"] for r in items}),
            "p50Milliseconds": percentile(values, 0.5),
            "p95Milliseconds": percentile(values, 0.95),
            "minimumMilliseconds": min(values) if values else None,
            "maximumMilliseconds": max(values) if values else None,
            "standardDeviationMilliseconds": statistics.stdev(values) if len(values) > 1 else None,
            "medianMelMilliseconds": percentile([r["melMilliseconds"] for r in good], 0.5),
            "medianEncoderMilliseconds": percentile([r["encoderMilliseconds"] for r in good], 0.5),
            "medianDecoderMilliseconds": percentile([r["decoderMilliseconds"] for r in good], 0.5),
            "thermalStates": sorted({r.get("thermalState") for r in good}),
        })
    return summaries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--model-root", type=Path)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument(
        "--variant-order",
        choices=("abba", "baab"),
        default="abba",
        help="Order baseline/candidate blocks as ABBA or BAAB to expose time-order drift.",
    )
    parser.add_argument(
        "--preview",
        action="store_true",
        help="Benchmark the lightweight live-preview transcription path.",
    )
    parser.add_argument(
        "--experiment",
        choices=(
            "early-encoder-cache",
            "decoder-gpu-fast",
            "decoder-joint-fusion",
            "decoder-output-backings",
            "decoder-output-backings-auto",
            "decoder-direct-output-backings",
            "decoder-shared-state-backing",
            "biased-argmax-vdsp",
            "nonpositive-bias-fastpath",
            "contextual-bias-direct",
            "encoder-window-root",
        ),
        default="early-encoder-cache",
        help="Select the baseline/candidate runtime difference under test.",
    )
    parser.add_argument(
        "--fused-decoder-joint-model",
        type=Path,
        help="External fused decoder+joint .mlpackage/.mlmodelc for decoder-joint-fusion.",
    )
    parser.add_argument(
        "--vocabulary",
        type=Path,
        help="One contextual-bias term per line; required for contextual-bias-direct.",
    )
    parser.add_argument(
        "--reference-model-root",
        type=Path,
        help="Reference ASR runtime root for encoder-window-root; defaults to --model-root/current runtime.",
    )
    parser.add_argument(
        "--candidate-model-root",
        type=Path,
        help="Candidate ASR runtime root for encoder-window-root.",
    )
    args = parser.parse_args()
    if args.experiment == "decoder-joint-fusion" and args.fused_decoder_joint_model is None:
        parser.error("--fused-decoder-joint-model is required for decoder-joint-fusion")
    if args.experiment == "contextual-bias-direct" and args.vocabulary is None:
        parser.error("--vocabulary is required for contextual-bias-direct")
    if args.experiment == "encoder-window-root" and args.candidate_model_root is None:
        parser.error("--candidate-model-root is required for encoder-window-root")
    if args.experiment != "encoder-window-root" and (
        args.reference_model_root is not None or args.candidate_model_root is not None
    ):
        parser.error(
            "--reference-model-root/--candidate-model-root are only valid for encoder-window-root"
        )
    if args.reference_model_root is not None and args.model_root is not None:
        parser.error("Use either --model-root or --reference-model-root, not both")
    root = Path(__file__).resolve().parent.parent
    if sys.platform != "darwin":
        parser.error("Native Core ML measurements require macOS; Linux results are not interchangeable.")
    os.umask(0o077)
    output = args.output.resolve()
    binary = args.binary or root / ".build/release/voxol-asr-smoke"
    registry = json.loads((root / "Models/manifests/runtime-models.json").read_text())
    model = next(m for m in registry["models"] if m["role"] == "asr")
    installed_model_root = (
        Path.home() / "Library/Application Support/VoxoL/Models/asr" / model["revision"]
    )
    reference_model_root = (
        args.reference_model_root or args.model_root or installed_model_root
    ).expanduser().resolve()
    candidate_model_root = (
        args.candidate_model_root.expanduser().resolve()
        if args.candidate_model_root is not None
        else None
    )
    model_roots = {
        "baseline": reference_model_root,
        "candidate": candidate_model_root or reference_model_root,
    }
    manifest = json.loads(args.manifest.read_text())
    vocabulary_path = args.vocabulary.expanduser().resolve() if args.vocabulary else None
    contextual_vocabulary = None
    if vocabulary_path is not None:
        if not vocabulary_path.is_file():
            parser.error(f"Vocabulary file does not exist: {vocabulary_path}")
        vocabulary_terms = [
            line.strip()
            for line in vocabulary_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        if not vocabulary_terms:
            parser.error("Vocabulary file must contain at least one non-empty term")
        contextual_vocabulary = {
            "path": str(vocabulary_path),
            "sha256": sha256(vocabulary_path),
            "terms": len(vocabulary_terms),
        }
    language_penalty = None
    if args.experiment in (
        "biased-argmax-vdsp",
        "nonpositive-bias-fastpath",
        "contextual-bias-direct",
    ):
        penalty_path_text = os.environ.get("VOXOL_LANGUAGE_PENALTY_JSON")
        penalty_amount_text = os.environ.get("VOXOL_LANGUAGE_PENALTY_AMOUNT")
        if not penalty_path_text or not penalty_amount_text:
            parser.error(
                f"{args.experiment} requires VOXOL_LANGUAGE_PENALTY_JSON and "
                "VOXOL_LANGUAGE_PENALTY_AMOUNT"
            )
        penalty_path = Path(penalty_path_text).expanduser().resolve()
        try:
            penalty_amount = float(penalty_amount_text)
        except ValueError:
            parser.error("VOXOL_LANGUAGE_PENALTY_AMOUNT must be a positive number")
        if penalty_amount <= 0:
            parser.error("VOXOL_LANGUAGE_PENALTY_AMOUNT must be a positive number")
        if not penalty_path.is_file():
            parser.error(f"Language penalty file does not exist: {penalty_path}")
        language_penalty = {
            "path": str(penalty_path),
            "sha256": sha256(penalty_path),
            "amount": penalty_amount,
        }
    fused_model = (
        args.fused_decoder_joint_model.expanduser().resolve()
        if args.fused_decoder_joint_model is not None
        else None
    )
    if fused_model is not None and not fused_model.exists():
        parser.error(f"Fused decoder+joint model does not exist: {fused_model}")
    expected = 4 * len(manifest["samples"]) * manifest["repetitions"] * 2
    checked_files = verify_registry_model_files(reference_model_root, model)
    encoder_model_comparison = None
    if args.experiment == "encoder-window-root":
        assert candidate_model_root is not None
        encoder_model_comparison = verify_encoder_candidate_model(
            reference_model_root, candidate_model_root
        )
    for sample in manifest["samples"]:
        if sha256(Path(sample["path"])) != sample["sha256"]:
            raise ValueError(f"Audio bytes changed: {sample['id']}")
    output.mkdir(parents=True, exist_ok=False)
    if not args.skip_build:
        with (output / "build.log").open("w") as log:
            subprocess.run(["swift", "build", "-c", "release", "--product", "voxol-asr-smoke"],
                           cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
    expected_scope = "warm-file-asr-preview" if args.preview else "warm-file-asr-only"
    if args.experiment == "early-encoder-cache":
        candidate_configuration = {"earlyEncoderCache": True}
    elif args.experiment == "decoder-gpu-fast":
        candidate_configuration = {"decoderComputeUnits": "gpu", "decoderFastPrediction": True}
    elif args.experiment == "decoder-output-backings":
        candidate_configuration = {"decoderOutputBackings": True}
    elif args.experiment == "decoder-direct-output-backings":
        candidate_configuration = {
            "decoderOutputBackings": True,
            "directOutputBackings": True,
        }
    elif args.experiment == "decoder-shared-state-backing":
        candidate_configuration = {
            "decoderOutputBackings": True,
            "directOutputBackings": True,
            "sharedDecoderStateBacking": True,
        }
    elif args.experiment == "biased-argmax-vdsp":
        candidate_configuration = {"biasedArgmax": "vDSP"}
    elif args.experiment == "nonpositive-bias-fastpath":
        candidate_configuration = {"nonPositiveBiasFastPath": True}
    elif args.experiment == "contextual-bias-direct":
        candidate_configuration = {"directContextualBias": True}
    elif args.experiment == "decoder-output-backings-auto":
        candidate_configuration = {"decoderOutputBackings": "auto-single-chunk"}
    elif args.experiment == "encoder-window-root":
        candidate_configuration = {
            "modelRoot": str(candidate_model_root),
            "encoderSHA256": encoder_model_comparison["candidateEncoderSHA256"],
        }
    else:
        candidate_configuration = {
            "fusedDecoderJointModel": str(fused_model),
            "fusedDecoderJointSHA256": tree_sha256(fused_model),
        }
    run = {
        "schemaVersion": "voxol-launch-cache-v1", "createdAt": datetime.now(timezone.utc).isoformat(),
        "scope": expected_scope, "hardware": command_output("sysctl", "-n", "machdep.cpu.brand_string"),
        "ramBytes": int(command_output("sysctl", "-n", "hw.memsize")),
        "platform": platform.platform(), "python": platform.python_version(),
        "binarySHA256": sha256(binary), "runnerSHA256": sha256(Path(__file__)),
        "manifestSHA256": sha256(args.manifest), "modelRevision": model["revision"],
        "modelFiles": checked_files, "registrySHA256": sha256(root / "Models/manifests/runtime-models.json"),
        "referenceModelRoot": str(reference_model_root),
        "candidateModelRoot": str(candidate_model_root) if candidate_model_root else None,
        "encoderModelComparison": encoder_model_comparison,
        "encoderWindowRuntimeValidation": None,
        "computeUnits": "all",
        "variantOrder": (
            ["baseline", "candidate", "candidate", "baseline"]
            if args.variant_order == "abba"
            else ["candidate", "baseline", "baseline", "candidate"]
        ),
        "experiment": args.experiment,
        "languagePenalty": language_penalty,
        "contextualVocabulary": contextual_vocabulary,
        "candidateConfiguration": candidate_configuration,
        "parityPolicy": "text" if args.preview else "full-decoder-evidence",
        "expectedObservations": expected, "uniqueAudioSources": len(manifest["samples"]),
        "limitations": [
            "File replay, not physical capture or inter-application insertion.",
            "Model preparation and priming excluded from warm inference observations.",
            "Repeated clips are not independent recordings; speaker independence is unknown.",
            "No energy claim; timing from successes is accompanied by all failures and missing observations.",
        ],
        "blocks": [],
    }
    (output / "run.json").write_text(json.dumps(run, indent=2) + "\n")
    rows: list[dict] = []
    for index, variant in enumerate(run["variantOrder"]):
        label = f"{index + 1}-{variant}"
        env = os.environ.copy()
        for key in (
            "VOXOL_ASR_EARLY_ENCODER_CACHE",
            "VOXOL_ASR_DECODER_COMPUTE_UNITS",
            "VOXOL_ASR_DECODER_FAST_PREDICTION",
            "VOXOL_ASR_DECODER_JOINT_FUSED_MODEL",
            "VOXOL_ASR_DECODER_OUTPUT_BACKINGS",
            "VOXOL_ASR_DECODER_OUTPUT_BACKINGS_TRACE",
            "VOXOL_ASR_DIRECT_OUTPUT_BACKINGS",
            "VOXOL_ASR_SHARED_DECODER_STATE_BACKING",
            "VOXOL_ASR_ACCELERATED_BIASED_ARGMAX",
            "VOXOL_ASR_NONPOSITIVE_BIAS_FASTPATH",
            "VOXOL_ASR_DIRECT_CONTEXTUAL_BIAS",
            "VOXOL_ASR_CACHE_BENCHMARK_VOCABULARY",
        ):
            env.pop(key, None)
        if args.experiment == "early-encoder-cache":
            env["VOXOL_ASR_EARLY_ENCODER_CACHE"] = "1" if variant == "candidate" else "0"
        elif args.experiment == "decoder-gpu-fast":
            env["VOXOL_ASR_EARLY_ENCODER_CACHE"] = "0"
            if variant == "candidate":
                env["VOXOL_ASR_DECODER_COMPUTE_UNITS"] = "gpu"
                env["VOXOL_ASR_DECODER_FAST_PREDICTION"] = "1"
        elif args.experiment == "decoder-joint-fusion":
            env["VOXOL_ASR_EARLY_ENCODER_CACHE"] = "0"
            if variant == "candidate":
                env["VOXOL_ASR_DECODER_JOINT_FUSED_MODEL"] = str(fused_model)
        elif args.experiment == "decoder-output-backings":
            env["VOXOL_ASR_EARLY_ENCODER_CACHE"] = "0"
            env["VOXOL_ASR_DECODER_OUTPUT_BACKINGS"] = (
                "1" if variant == "candidate" else "0"
            )
        elif args.experiment == "decoder-direct-output-backings":
            env["VOXOL_ASR_EARLY_ENCODER_CACHE"] = "0"
            env["VOXOL_ASR_DECODER_OUTPUT_BACKINGS"] = "1"
            env["VOXOL_ASR_DIRECT_OUTPUT_BACKINGS"] = (
                "1" if variant == "candidate" else "0"
            )
        elif args.experiment == "decoder-shared-state-backing":
            env["VOXOL_ASR_EARLY_ENCODER_CACHE"] = "0"
            env["VOXOL_ASR_DECODER_OUTPUT_BACKINGS"] = "1"
            env["VOXOL_ASR_DIRECT_OUTPUT_BACKINGS"] = "1"
            env["VOXOL_ASR_SHARED_DECODER_STATE_BACKING"] = (
                "1" if variant == "candidate" else "0"
            )
        elif args.experiment == "biased-argmax-vdsp":
            env["VOXOL_ASR_EARLY_ENCODER_CACHE"] = "0"
            env["VOXOL_ASR_ACCELERATED_BIASED_ARGMAX"] = (
                "1" if variant == "candidate" else "0"
            )
        elif args.experiment == "nonpositive-bias-fastpath":
            env["VOXOL_ASR_EARLY_ENCODER_CACHE"] = "0"
            env["VOXOL_ASR_NONPOSITIVE_BIAS_FASTPATH"] = (
                "1" if variant == "candidate" else "0"
            )
        elif args.experiment == "contextual-bias-direct":
            env["VOXOL_ASR_EARLY_ENCODER_CACHE"] = "0"
            env["VOXOL_ASR_DIRECT_CONTEXTUAL_BIAS"] = (
                "1" if variant == "candidate" else "0"
            )
        elif args.experiment == "encoder-window-root":
            pass
        else:
            env["VOXOL_ASR_EARLY_ENCODER_CACHE"] = "0"
            if variant == "baseline":
                env["VOXOL_ASR_DECODER_OUTPUT_BACKINGS"] = "0"
        if vocabulary_path is not None:
            env["VOXOL_ASR_CACHE_BENCHMARK_VOCABULARY"] = str(vocabulary_path)
        env["VOXOL_ASR_CACHE_BENCHMARK_PREVIEW"] = "1" if args.preview else "0"
        before = {
            "power": command_output("pmset", "-g", "batt"),
            "memory": command_output("memory_pressure", "-Q"),
            "loadAverage": list(os.getloadavg()),
        }
        block_model_root = model_roots[variant]
        command = ["/usr/bin/time", "-l", str(binary), "--cache-benchmark", "--model-root",
                   str(block_model_root), "--manifest", str(args.manifest.resolve())]
        print(f"Running {label}", flush=True)
        with (output / f"{label}.jsonl").open("w") as stdout, (output / f"{label}.stderr").open("w") as stderr:
            try:
                result = subprocess.run(command, cwd=root, env=env, stdout=stdout, stderr=stderr,
                                        check=False, timeout=1800)
                returncode = result.returncode
            except subprocess.TimeoutExpired:
                returncode = 124
        records = [
            json.loads(line)
            for line in (output / f"{label}.jsonl").read_text().splitlines()
            if line.strip()
        ]
        load_records = [record for record in records if record.get("type") == "load"]
        if args.experiment == "encoder-window-root" and len(load_records) != 1:
            raise RuntimeError(
                f"Expected exactly one model-load record in {label}, got {len(load_records)}"
            )
        load_record = load_records[0] if len(load_records) == 1 else None
        block = {
            "variant": variant, "index": index, "exitCode": returncode, "before": before,
            "modelRoot": str(block_model_root),
            "encoderSHA256": tree_sha256(block_model_root / "encoder.mlpackage"),
            "maximumWaveformSampleCount": (
                load_record.get("maximumWaveformSampleCount") if load_record else None
            ),
            "environment": {
                key: env.get(key)
                for key in (
                    "VOXOL_ASR_EARLY_ENCODER_CACHE",
                    "VOXOL_ASR_DECODER_COMPUTE_UNITS",
                    "VOXOL_ASR_DECODER_FAST_PREDICTION",
                    "VOXOL_ASR_DECODER_JOINT_FUSED_MODEL",
                    "VOXOL_ASR_DECODER_OUTPUT_BACKINGS",
                    "VOXOL_ASR_DIRECT_OUTPUT_BACKINGS",
                    "VOXOL_ASR_SHARED_DECODER_STATE_BACKING",
                    "VOXOL_ASR_ACCELERATED_BIASED_ARGMAX",
                    "VOXOL_ASR_NONPOSITIVE_BIAS_FASTPATH",
                    "VOXOL_ASR_DIRECT_CONTEXTUAL_BIAS",
                    "VOXOL_ASR_CACHE_BENCHMARK_VOCABULARY",
                    "VOXOL_ASR_CACHE_BENCHMARK_PREVIEW",
                    "VOXOL_LANGUAGE_PENALTY_JSON",
                    "VOXOL_LANGUAGE_PENALTY_AMOUNT",
                )
            },
            "predictionSHA256": sha256(output / f"{label}.jsonl"),
        }
        run["blocks"].append(block)
        if args.experiment == "encoder-window-root" and {
            item["variant"] for item in run["blocks"]
        } == {"baseline", "candidate"}:
            run["encoderWindowRuntimeValidation"] = verify_encoder_window_runtime(
                run["blocks"]
            )
        (output / "run.json").write_text(json.dumps(run, indent=2) + "\n")
        block_rows = [
            record | {"variant": variant, "block": index}
            for record in records
            if record.get("type") == "observation"
        ]
        observed_scopes = {row.get("scope") for row in block_rows}
        if observed_scopes and observed_scopes != {expected_scope}:
            raise RuntimeError(
                f"Benchmark mode mismatch: expected {expected_scope}, observed {sorted(observed_scopes)}. "
                "Rebuild the selected binary before using --skip-build."
            )
        rows.extend(block_rows)
        print(f"Finished {label}, exit {returncode}", flush=True)
    hashes: dict[str, set[str]] = {}
    evidence_hashes: dict[str, set[str]] = {}
    for row in rows:
        if row.get("textSHA256"):
            hashes.setdefault(row["id"], set()).add(row["textSHA256"])
        if row.get("evidenceSHA256"):
            evidence_hashes.setdefault(row["id"], set()).add(row["evidenceSHA256"])
    mismatches = [key for key, values in hashes.items() if len(values) != 1]
    evidence_mismatches = [
        key for key, values in evidence_hashes.items() if len(values) != 1
    ]
    summary = {
        "schemaVersion": "voxol-launch-cache-summary-v1", "expectedObservations": expected,
        "observed": len(rows), "missing": max(0, expected - len(rows)),
        "failedObservations": sum(r.get("status") != "ok" for r in rows),
        "crossVariantMismatchSources": mismatches,
        "crossVariantEvidenceMismatchSources": evidence_mismatches,
        "parityPolicy": run["parityPolicy"], "groups": summarize(rows),
        "promotionAutomatic": False,
    }
    (output / "observations.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return int(bool(
        summary["missing"] or summary["failedObservations"] or mismatches
        or (evidence_mismatches and not args.preview)
        or any(b["exitCode"] for b in run["blocks"])
    ))


if __name__ == "__main__":
    raise SystemExit(main())
