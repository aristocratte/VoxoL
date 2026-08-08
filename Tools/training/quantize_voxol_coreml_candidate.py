#!/usr/bin/env python3
"""Quantize a validated VoxoL FP16 Core ML runtime in a separate process."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from export_voxol_coreml_candidate import (
    COREMLTOOLS_VERSION,
    copy_runtime_support,
    directory_size,
    normalized_package_version,
    require_empty_directory,
)


VARIANT = "int8-linear-per-channel"
SUPPORTED_RUNTIME_CONTRACTS = frozenset(
    {
        "encoder-3000x128-to-375x640-v1",
        "waveform-479840-to-375x640-v1",
        "waveform-480000-to-376x640-v2",
    }
)


def validate_source_metadata(
    metadata: dict[str, str],
    expected_delta_sha256: str,
) -> None:
    actual = metadata.get("voxol.delta_sha256")
    if actual != expected_delta_sha256:
        raise ValueError(
            "FP16 source delta mismatch: "
            f"expected {expected_delta_sha256}, got {actual}."
        )
    runtime_contract = metadata.get("voxol.runtime_contract")
    if runtime_contract not in SUPPORTED_RUNTIME_CONTRACTS:
        raise ValueError("FP16 source has an incompatible VoxoL runtime contract.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fp16-runtime-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--expected-delta-sha256", required=True)
    args = parser.parse_args()

    encoder = args.fp16_runtime_root / "encoder.mlpackage"
    if not encoder.is_dir():
        raise FileNotFoundError(f"Missing FP16 encoder: {encoder}")
    require_empty_directory(args.output_root)

    import coremltools as ct
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )

    if normalized_package_version(ct.__version__) != COREMLTOOLS_VERSION:
        raise RuntimeError(
            f"Expected coremltools {COREMLTOOLS_VERSION}, got {ct.__version__}."
        )
    fp16 = ct.models.MLModel(str(encoder), skip_model_load=True)
    validate_source_metadata(
        dict(fp16.user_defined_metadata),
        args.expected_delta_sha256,
    )
    quantized = linear_quantize_weights(
        fp16,
        OptimizationConfig(
            global_config=OpLinearQuantizerConfig(
                mode="linear_symmetric",
                dtype="int8",
                granularity="per_channel",
                weight_threshold=512,
            )
        ),
    )
    quantized.user_defined_metadata.update(fp16.user_defined_metadata)
    quantized.user_defined_metadata["voxol.quantization"] = VARIANT
    quantized.save(str(args.output_root / "encoder.mlpackage"))
    copy_runtime_support(args.fp16_runtime_root, args.output_root)

    report = {
        "schemaVersion": 1,
        "variant": VARIANT,
        "sourceRuntime": str(args.fp16_runtime_root.resolve()),
        "deltaSHA256": args.expected_delta_sha256,
        "coremltools": ct.__version__,
        "encoderBytes": directory_size(args.output_root / "encoder.mlpackage"),
        "runtimeBytes": directory_size(args.output_root),
    }
    report_path = args.output_root / "quantization-report.json"
    report_path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
