#!/usr/bin/env python3
"""Validate and decompose a legacy VoxoL Parakeet snapshot without training."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import time
from typing import Iterable

from Tools.training.run_nemo_asr_benchmark import (
    MODEL_ID,
    MODEL_REVISION,
    apply_trainable_delta,
    load_pinned_model,
    text_of,
)
from Tools.training.run_voxol_nemo_finetune import batchnorm_state_names
from Tools.training.score_asr_predictions import (
    load_predictions,
    normalize,
    score_items,
)


SCHEMA_VERSION = "voxol-nemo-snapshot-diagnostics-v1"
ENCODER_PREFIXES = tuple(f"encoder.layers.{index}." for index in range(20, 24))
DJ_PREFIXES = ("decoder.", "joint.")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--config", type=Path, required=True)
    result.add_argument("--output-root", type=Path, required=True)
    result.add_argument("--batch-size", type=int, default=8)
    result.add_argument("--alphas", default="0,0.5,1")
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def parse_alphas(value: str) -> tuple[float, ...]:
    alphas = tuple(float(item) for item in value.split(","))
    if not alphas or any(alpha < 0 or alpha > 1 for alpha in alphas):
        raise SystemExit("--alphas must contain values between zero and one.")
    if len(set(alphas)) != len(alphas):
        raise SystemExit("--alphas contains duplicate values.")
    return alphas


def load_config(path: Path) -> dict[str, object]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != 1:
        raise SystemExit("Unsupported diagnostic configuration.")
    snapshot = Path(str(payload.get("legacySnapshot", "")))
    if not snapshot.is_file():
        raise SystemExit(f"Missing legacy snapshot: {snapshot}")
    benchmarks = payload.get("benchmarks")
    if not isinstance(benchmarks, list) or not benchmarks:
        raise SystemExit("The diagnostic configuration has no benchmarks.")
    secondary_snapshots = payload.get("secondarySnapshots", [])
    if not isinstance(secondary_snapshots, list):
        raise SystemExit("Invalid secondary snapshot configuration.")
    secondary_identifiers = set()
    for secondary in secondary_snapshots:
        if not isinstance(secondary, dict):
            raise SystemExit("Invalid secondary snapshot configuration.")
        identifier = str(secondary.get("id", ""))
        if not identifier or identifier in secondary_identifiers:
            raise SystemExit(
                f"Missing or duplicate secondary snapshot id: {identifier!r}"
            )
        secondary_identifiers.add(identifier)
        for key in ("legacySnapshot", "archivedCandidatePredictions"):
            if not Path(str(secondary.get(key, ""))).is_file():
                raise SystemExit(f"Missing {key} for {identifier}.")
    identifiers = set()
    for benchmark in benchmarks:
        if not isinstance(benchmark, dict):
            raise SystemExit("Invalid benchmark configuration.")
        identifier = str(benchmark.get("id", ""))
        if not identifier or identifier in identifiers:
            raise SystemExit(f"Missing or duplicate benchmark id: {identifier!r}")
        identifiers.add(identifier)
        if benchmark.get("role") not in ("dev", "parity"):
            raise SystemExit(f"Invalid benchmark role: {identifier}")
        for key in ("manifest", "audioRoot"):
            if not Path(str(benchmark.get(key, ""))).exists():
                raise SystemExit(f"Missing {key} for {identifier}.")
        if benchmark["role"] == "parity":
            for key in (
                "archivedBaselinePredictions",
                "archivedCandidatePredictions",
            ):
                if not Path(str(benchmark.get(key, ""))).is_file():
                    raise SystemExit(f"Missing {key} for {identifier}.")
    return payload


def load_legacy_snapshot(path: Path, torch: object) -> dict[str, object]:
    snapshot = torch.load(path, map_location="cpu", weights_only=True)
    if (
        not isinstance(snapshot, dict)
        or snapshot.get("schemaVersion") != 1
        or snapshot.get("baseModel") != MODEL_ID
        or not isinstance(snapshot.get("stateDict"), dict)
    ):
        raise SystemExit(f"Unsupported legacy VoxoL snapshot: {path}")
    return snapshot


def model_state_groups(
    model: object,
    snapshot_names: Iterable[str],
    torch: object,
) -> dict[str, frozenset[str]]:
    names = set(snapshot_names)
    batchnorm = names & set(batchnorm_state_names(model, torch))
    encoder = {
        name
        for name in names
        if name.startswith(ENCODER_PREFIXES) and name not in batchnorm
    }
    decoder_joint = {name for name in names if name.startswith(DJ_PREFIXES)}
    unknown = names - encoder - batchnorm - decoder_joint
    if unknown:
        raise RuntimeError(f"Unclassified snapshot tensor: {sorted(unknown)[0]}")
    return {
        "encoder": frozenset(encoder),
        "batchnorm": frozenset(batchnorm),
        "decoderJoint": frozenset(decoder_joint),
    }


def capture_state(
    model: object,
    names: Iterable[str],
) -> dict[str, object]:
    state = model.state_dict()
    missing = sorted(set(names) - set(state))
    if missing:
        raise RuntimeError(f"Snapshot tensor absent from base: {missing[0]}")
    return {
        name: state[name].detach().to(device="cpu").contiguous().clone()
        for name in names
    }


def reset_state(
    model: object,
    base_state: dict[str, object],
    torch: object,
) -> None:
    state = model.state_dict()
    with torch.no_grad():
        for name, source in base_state.items():
            destination = state[name]
            destination.copy_(
                source.to(device=destination.device, dtype=destination.dtype)
            )


def apply_legacy_composition(
    model: object,
    base_state: dict[str, object],
    candidate_state: dict[str, object],
    groups: dict[str, frozenset[str]],
    encoder_alpha: float,
    decoder_joint_alpha: float,
    use_candidate_batchnorm: bool,
    torch: object,
) -> list[str]:
    reset_state(model, base_state, torch)
    state = model.state_dict()
    skipped = []
    alpha_by_name = {
        **{name: encoder_alpha for name in groups["encoder"]},
        **{
            name: decoder_joint_alpha
            for name in groups["decoderJoint"]
        },
        **{
            name: 1.0 if use_candidate_batchnorm else 0.0
            for name in groups["batchnorm"]
        },
    }
    with torch.no_grad():
        for name, alpha in alpha_by_name.items():
            if alpha == 0:
                continue
            destination = state[name]
            base = base_state[name]
            candidate = candidate_state[name]
            if not destination.is_floating_point():
                skipped.append(name)
                continue
            candidate_fp32 = candidate.to(device="cpu", dtype=torch.float32)
            if not bool(torch.isfinite(candidate_fp32).all()):
                skipped.append(name)
                continue
            update = candidate_fp32 - base.to(dtype=torch.float32)
            composed = base.to(dtype=torch.float32) + alpha * update
            destination.copy_(
                composed.to(
                    device=destination.device,
                    dtype=destination.dtype,
                )
            )
    model.eval()
    return sorted(skipped)


def transcribe(
    model: object,
    benchmark: dict[str, object],
    output_path: Path,
    batch_size: int,
    identity: str,
    torch: object,
) -> dict[str, dict[str, object]]:
    manifest = json.loads(Path(str(benchmark["manifest"])).read_text(encoding="utf-8"))
    audio_root = Path(str(benchmark["audioRoot"]))
    items = list(manifest["items"])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    predictions = {}
    with output_path.open("w", encoding="utf-8") as output:
        for offset in range(0, len(items), batch_size):
            batch = items[offset : offset + batch_size]
            paths = [
                str((audio_root / str(item["audioPath"])).resolve())
                for item in batch
            ]
            missing = [path for path in paths if not Path(path).is_file()]
            if missing:
                raise RuntimeError(f"Missing benchmark audio: {missing[0]}")
            started = time.perf_counter()
            with torch.inference_mode():
                results = model.transcribe(
                    audio=paths,
                    batch_size=len(batch),
                    verbose=False,
                )
            elapsed = (time.perf_counter() - started) * 1_000 / len(batch)
            for item, result in zip(batch, results, strict=True):
                text = text_of(result)
                row = {
                    "id": item["id"],
                    "rawText": text,
                    "finalText": text,
                    "checkpoint": identity,
                    "inferenceMilliseconds": elapsed,
                }
                predictions[str(item["id"])] = row
                output.write(
                    json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
                )
                output.flush()
    return predictions


def comparison(
    actual: dict[str, dict[str, object]],
    expected_path: Path,
) -> dict[str, object]:
    expected = load_predictions(expected_path)
    identifiers = sorted(set(actual) | set(expected))
    missing = [identifier for identifier in identifiers if identifier not in actual]
    unexpected = [
        identifier for identifier in identifiers if identifier not in expected
    ]
    exact = 0
    normalized = 0
    for identifier in set(actual) & set(expected):
        actual_text = str(actual[identifier]["rawText"])
        expected_text = str(expected[identifier]["rawText"])
        exact += actual_text == expected_text
        normalized += normalize(actual_text) == normalize(expected_text)
    denominator = len(expected)
    return {
        "expectedCount": denominator,
        "actualCount": len(actual),
        "missingIDs": missing,
        "unexpectedIDs": unexpected,
        "exactMatchRate": exact / denominator if denominator else 0.0,
        "normalizedExactMatchRate": (
            normalized / denominator if denominator else 0.0
        ),
        "passed": (
            not missing
            and not unexpected
            and exact == denominator
        ),
    }


def score(
    benchmark: dict[str, object],
    predictions: dict[str, dict[str, object]],
) -> dict[str, object]:
    manifest = json.loads(Path(str(benchmark["manifest"])).read_text(encoding="utf-8"))
    return score_items(list(manifest["items"]), predictions)


def scalar(value: object) -> object:
    item = getattr(value, "item", None)
    return item() if callable(item) else value


def validation_reconciliation(
    recorded: object,
    external: float,
) -> dict[str, object]:
    value = scalar(recorded)
    if not isinstance(value, (int, float)):
        return {
            "recorded": value,
            "externalMicroWER": external,
            "passed": False,
            "reason": "missing-or-nonnumeric-recorded-validation-WER",
        }
    normalized = float(value) / 100 if float(value) > 1 else float(value)
    delta = external - normalized
    return {
        "recorded": float(value),
        "recordedNormalized": normalized,
        "externalMicroWER": external,
        "absoluteDelta": abs(delta),
        "passed": abs(delta) <= 0.005,
    }


def analyze_grid(grid: dict[str, dict[str, object]]) -> dict[str, object]:
    baseline_id = "E0-DJ0-BNbase"
    baseline = grid[baseline_id]["benchmarks"]
    baseline_general = baseline["fleurs-validation"]
    baseline_teacher = baseline["teacher-validation"]
    entries = []
    for identifier, result in sorted(grid.items()):
        benchmarks = result["benchmarks"]
        general = benchmarks["fleurs-validation"]
        teacher = benchmarks["teacher-validation"]
        language_deltas = {
            language: (
                general["byLanguage"][language]["microWER"]
                - baseline_general["byLanguage"][language]["microWER"]
            )
            for language in baseline_general["byLanguage"]
        }
        general_delta = general["microWER"] - baseline_general["microWER"]
        deletion_delta = (
            general["wordErrors"]["deletionRate"]
            - baseline_general["wordErrors"]["deletionRate"]
        )
        new_empty_outputs = (
            general["emptyOutputCount"]
            - baseline_general["emptyOutputCount"]
        )
        preserves_general = (
            general_delta <= 0.002
            and max(language_deltas.values(), default=0.0) <= 0.002
            and deletion_delta <= 0.001
            and new_empty_outputs <= 0
        )
        teacher_gain = baseline_teacher["microWER"] - teacher["microWER"]
        entries.append(
            {
                "id": identifier,
                "generalWERDelta": general_delta,
                "generalLanguageWERDeltas": language_deltas,
                "generalDeletionRateDelta": deletion_delta,
                "generalNewEmptyOutputs": new_empty_outputs,
                "teacherWERGain": teacher_gain,
                "preservesGeneralDev": preserves_general,
            }
        )
    eligible = [
        entry
        for entry in entries
        if entry["preservesGeneralDev"] and entry["teacherWERGain"] > 0
    ]
    eligible.sort(
        key=lambda entry: (
            -entry["teacherWERGain"],
            entry["generalWERDelta"],
        )
    )

    def average_effect(
        field: str,
        low: object,
        high: object,
    ) -> float | None:
        pairs = []
        for result in grid.values():
            if result[field] != low:
                continue
            counterpart = next(
                (
                    candidate
                    for candidate in grid.values()
                    if candidate[field] == high
                    and all(
                        candidate[other] == result[other]
                        for other in (
                            "encoderAlpha",
                            "decoderJointAlpha",
                            "batchNorm",
                        )
                        if other != field
                    )
                ),
                None,
            )
            if counterpart is None:
                continue
            pairs.append(
                counterpart["benchmarks"]["fleurs-validation"]["microWER"]
                - result["benchmarks"]["fleurs-validation"]["microWER"]
            )
        return sum(pairs) / len(pairs) if pairs else None

    return {
        "baseline": baseline_id,
        "compositions": entries,
        "bestGeneralPreservingComposition": (
            eligible[0]["id"] if eligible else None
        ),
        "averageFleursWEREffects": {
            "encoderAlpha0To1": average_effect("encoderAlpha", 0.0, 1.0),
            "decoderJointAlpha0To1": average_effect(
                "decoderJointAlpha",
                0.0,
                1.0,
            ),
            "candidateBatchNorm": average_effect(
                "batchNorm",
                "base",
                "candidate",
            ),
        },
        "authorizesNewTraining": False,
        "authorizationBlockers": [
            "human teacher audit is not complete",
            "the post-hoc result still requires review",
        ],
    }


def main() -> None:
    arguments = parser().parse_args()
    if arguments.batch_size < 1:
        raise SystemExit("--batch-size must be positive.")
    alphas = parse_alphas(arguments.alphas)
    configuration = load_config(arguments.config)
    output_root = arguments.output_root.resolve()
    output_root.mkdir(parents=True, exist_ok=True)

    import torch
    import nemo.collections.asr as nemo_asr

    if not torch.cuda.is_available():
        raise SystemExit("This diagnostic requires an NVIDIA CUDA GPU.")
    snapshot_path = Path(str(configuration["legacySnapshot"])).resolve()
    snapshot = load_legacy_snapshot(snapshot_path, torch)
    candidate_state = dict(snapshot["stateDict"])

    model, base_artifact_sha256 = load_pinned_model(nemo_asr, "cuda")
    model = model.cuda().eval()
    groups = model_state_groups(model, candidate_state, torch)
    base_state = capture_state(model, candidate_state)
    benchmarks = list(configuration["benchmarks"])
    parity_benchmarks = [
        benchmark for benchmark in benchmarks if benchmark["role"] == "parity"
    ]
    dev_benchmarks = [
        benchmark for benchmark in benchmarks if benchmark["role"] == "dev"
    ]

    report: dict[str, object] = {
        "schemaVersion": SCHEMA_VERSION,
        "baseModel": MODEL_ID,
        "baseRevision": MODEL_REVISION,
        "baseArtifactSHA256": base_artifact_sha256,
        "legacySnapshot": str(snapshot_path),
        "legacySnapshotSHA256": sha256(snapshot_path),
        "legacySnapshotMetadata": {
            "epoch": scalar(snapshot.get("epoch")),
            "globalStep": scalar(snapshot.get("globalStep")),
            "validationWER": scalar(snapshot.get("validationWER")),
        },
        "groups": {key: len(value) for key, value in groups.items()},
        "parity": {},
        "grid": {},
    }

    base_predictions = {}
    for benchmark in parity_benchmarks:
        identifier = str(benchmark["id"])
        predictions = transcribe(
            model,
            benchmark,
            output_root / "parity" / "base" / f"{identifier}.jsonl",
            arguments.batch_size,
            "pinned-base",
            torch,
        )
        base_predictions[identifier] = predictions
        base_path = output_root / "parity" / f"{identifier}-base.jsonl"
        with base_path.open("w", encoding="utf-8") as output:
            for row in predictions.values():
                output.write(json.dumps(row, ensure_ascii=False) + "\n")
        report["parity"].setdefault(identifier, {})["baseVsArchived"] = comparison(
            predictions,
            Path(str(benchmark["archivedBaselinePredictions"])),
        )

    trainable_parameter_names = {
        name
        for name, _ in model.named_parameters()
        if name in candidate_state
    }
    zero_delta_path = output_root / "parity" / "zero-v2.delta.pt"
    torch.save(
        {
            "schemaVersion": 2,
            "artifactType": "voxol-parameter-delta",
            "baseModel": MODEL_ID,
            "baseRevision": MODEL_REVISION,
            "baseArtifactSHA256": base_artifact_sha256,
            "epoch": 0,
            "globalStep": 0,
            "stateDelta": {
                name: torch.zeros_like(
                    base_state[name],
                    dtype=torch.float32,
                    device="cpu",
                )
                for name in sorted(trainable_parameter_names)
            },
        },
        zero_delta_path,
    )
    del model
    torch.cuda.empty_cache()
    zero_model, zero_base_digest = load_pinned_model(nemo_asr, "cuda")
    zero_model = zero_model.cuda().eval()
    for benchmark in parity_benchmarks:
        identifier = str(benchmark["id"])
        predictions = transcribe(
            zero_model,
            benchmark,
            output_root / "parity" / "reloaded-base" / f"{identifier}.jsonl",
            arguments.batch_size,
            "pinned-base-reloaded",
            torch,
        )
        report["parity"][identifier]["baseVsReloaded"] = comparison(
            predictions,
            output_root / "parity" / f"{identifier}-base.jsonl",
        )
    apply_trainable_delta(
        zero_model,
        zero_delta_path,
        torch,
        base_artifact_sha256=zero_base_digest,
    )
    for benchmark in parity_benchmarks:
        identifier = str(benchmark["id"])
        predictions = transcribe(
            zero_model,
            benchmark,
            output_root / "parity" / "zero-v2" / f"{identifier}.jsonl",
            arguments.batch_size,
            "pinned-base+zero-v2",
            torch,
        )
        report["parity"][identifier]["baseVsZeroV2"] = comparison(
            predictions,
            output_root / "parity" / f"{identifier}-base.jsonl",
        )

    candidate_groups = model_state_groups(zero_model, candidate_state, torch)
    candidate_base = capture_state(zero_model, candidate_state)
    apply_legacy_composition(
        zero_model,
        candidate_base,
        candidate_state,
        candidate_groups,
        1.0,
        1.0,
        True,
        torch,
    )
    for benchmark in parity_benchmarks:
        identifier = str(benchmark["id"])
        predictions = transcribe(
            zero_model,
            benchmark,
            output_root / "parity" / "legacy-alpha1" / f"{identifier}.jsonl",
            arguments.batch_size,
            "legacy-snapshot-alpha1",
            torch,
        )
        report["parity"][identifier]["legacyVsArchived"] = comparison(
            predictions,
            Path(str(benchmark["archivedCandidatePredictions"])),
        )

    secondary_reports = {}
    for secondary in configuration.get("secondarySnapshots", []):
        secondary_id = str(secondary["id"])
        secondary_path = Path(str(secondary["legacySnapshot"])).resolve()
        secondary_snapshot = load_legacy_snapshot(secondary_path, torch)
        secondary_state = dict(secondary_snapshot["stateDict"])
        reset_state(zero_model, candidate_base, torch)
        secondary_groups = model_state_groups(
            zero_model,
            secondary_state,
            torch,
        )
        secondary_base = capture_state(zero_model, secondary_state)
        skipped = apply_legacy_composition(
            zero_model,
            secondary_base,
            secondary_state,
            secondary_groups,
            1.0,
            1.0,
            True,
            torch,
        )
        secondary_report = {
            "legacySnapshot": str(secondary_path),
            "legacySnapshotSHA256": sha256(secondary_path),
            "legacySnapshotMetadata": {
                "epoch": scalar(secondary_snapshot.get("epoch")),
                "globalStep": scalar(secondary_snapshot.get("globalStep")),
                "validationWER": scalar(secondary_snapshot.get("validationWER")),
            },
            "groups": {
                key: len(value) for key, value in secondary_groups.items()
            },
            "skippedTensors": skipped,
            "parity": {},
            "benchmarks": {},
        }
        for benchmark in parity_benchmarks:
            benchmark_id = str(benchmark["id"])
            predictions = transcribe(
                zero_model,
                benchmark,
                output_root / "secondary" / secondary_id
                / f"{benchmark_id}.jsonl",
                arguments.batch_size,
                secondary_id,
                torch,
            )
            secondary_report["parity"][benchmark_id] = comparison(
                predictions,
                Path(str(secondary["archivedCandidatePredictions"])),
            )
        for benchmark in dev_benchmarks:
            benchmark_id = str(benchmark["id"])
            predictions = transcribe(
                zero_model,
                benchmark,
                output_root / "secondary" / secondary_id
                / f"{benchmark_id}.jsonl",
                arguments.batch_size,
                secondary_id,
                torch,
            )
            secondary_report["benchmarks"][benchmark_id] = score(
                benchmark,
                predictions,
            )
        secondary_reports[secondary_id] = secondary_report
    report["secondarySnapshots"] = secondary_reports

    parity_passed = all(
        comparison_result["passed"]
        for benchmark_result in report["parity"].values()
        for comparison_result in benchmark_result.values()
    ) and all(
        comparison_result["passed"]
        for secondary_report in secondary_reports.values()
        for comparison_result in secondary_report["parity"].values()
    )
    report["parityPassed"] = parity_passed
    atomic_json(output_root / "diagnostic-report.json", report)
    if not parity_passed:
        raise SystemExit(
            "A/A parity failed. The post-hoc grid was not executed."
        )

    for encoder_alpha in alphas:
        for decoder_joint_alpha in alphas:
            for use_candidate_batchnorm in (False, True):
                identifier = (
                    f"E{encoder_alpha:g}-DJ{decoder_joint_alpha:g}-"
                    f"BN{'candidate' if use_candidate_batchnorm else 'base'}"
                )
                skipped = apply_legacy_composition(
                    zero_model,
                    candidate_base,
                    candidate_state,
                    candidate_groups,
                    encoder_alpha,
                    decoder_joint_alpha,
                    use_candidate_batchnorm,
                    torch,
                )
                benchmark_reports = {}
                for benchmark in dev_benchmarks:
                    benchmark_id = str(benchmark["id"])
                    predictions = transcribe(
                        zero_model,
                        benchmark,
                        output_root / "grid" / identifier / f"{benchmark_id}.jsonl",
                        arguments.batch_size,
                        identifier,
                        torch,
                    )
                    benchmark_reports[benchmark_id] = score(
                        benchmark,
                        predictions,
                    )
                report["grid"][identifier] = {
                    "encoderAlpha": encoder_alpha,
                    "decoderJointAlpha": decoder_joint_alpha,
                    "batchNorm": (
                        "candidate" if use_candidate_batchnorm else "base"
                    ),
                    "skippedTensors": skipped,
                    "benchmarks": benchmark_reports,
                }
                atomic_json(output_root / "diagnostic-report.json", report)

    full_candidate = report["grid"]["E1-DJ1-BNcandidate"]["benchmarks"][
        "teacher-validation"
    ]["microWER"]
    report["validationReconciliation"] = {
        "primary": validation_reconciliation(
            report["legacySnapshotMetadata"]["validationWER"],
            full_candidate,
        ),
        **{
            secondary_id: validation_reconciliation(
                secondary_report["legacySnapshotMetadata"]["validationWER"],
                secondary_report["benchmarks"]["teacher-validation"][
                    "microWER"
                ],
            )
            for secondary_id, secondary_report in secondary_reports.items()
        },
    }
    report["analysis"] = analyze_grid(report["grid"])
    if not all(
        result["passed"]
        for result in report["validationReconciliation"].values()
    ):
        report["analysis"]["authorizationBlockers"].append(
            "recorded and externally reproduced validation WER do not reconcile"
        )
    atomic_json(output_root / "diagnostic-report.json", report)
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
