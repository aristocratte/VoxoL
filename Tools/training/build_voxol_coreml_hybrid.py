#!/usr/bin/env python3
"""Build a mixed FP16/INT8 Parakeet runtime from a validated FP16 export."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from export_voxol_coreml_candidate import (
    copy_runtime_support,
    directory_size,
    preserve_hybrid_fp16_weight,
    require_empty_directory,
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fp16-runtime-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()

    encoder = args.fp16_runtime_root / "encoder.mlpackage"
    if not encoder.is_dir():
        raise FileNotFoundError(f"Missing FP16 encoder: {encoder}")
    require_empty_directory(args.output_root)

    import coremltools as ct
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        get_weights_metadata,
        linear_quantize_weights,
    )

    fp16_model = ct.models.MLModel(str(encoder), skip_model_load=True)
    metadata = get_weights_metadata(fp16_model, weight_threshold=512)
    preserved = sorted(
        name for name in metadata
        if preserve_hybrid_fp16_weight(name)
    )
    if not preserved:
        raise RuntimeError("No fine-tuned FP16 weights matched the Core ML graph.")

    int8 = OpLinearQuantizerConfig(
        mode="linear_symmetric",
        dtype="int8",
        granularity="per_channel",
        weight_threshold=512,
    )
    hybrid = linear_quantize_weights(
        fp16_model,
        OptimizationConfig(
            global_config=int8,
            op_name_configs={name: None for name in preserved},
        ),
    )
    hybrid.user_defined_metadata.update(fp16_model.user_defined_metadata)
    hybrid.user_defined_metadata["voxol.quantization"] = "int8-hybrid-top4-fp16"
    hybrid.user_defined_metadata["voxol.fp16_preserved_weight_count"] = str(
        len(preserved)
    )

    hybrid.save(str(args.output_root / "encoder.mlpackage"))
    copy_runtime_support(args.fp16_runtime_root, args.output_root)
    report = {
        "schemaVersion": 1,
        "variant": "int8-hybrid-top4-fp16",
        "sourceRuntime": str(args.fp16_runtime_root.resolve()),
        "preservedWeightCount": len(preserved),
        "preservedWeights": preserved,
        "encoderBytes": directory_size(args.output_root / "encoder.mlpackage"),
        "runtimeBytes": directory_size(args.output_root),
    }
    (args.output_root / "hybrid-report.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(args.output_root)


if __name__ == "__main__":
    main()
