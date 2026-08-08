#!/usr/bin/env python3
"""Export a VoxoL Parakeet delta as runtime-compatible Core ML encoders."""

from __future__ import annotations

import argparse
import hashlib
from importlib import metadata as importlib_metadata
import json
from pathlib import Path
import shutil
import sys
import time
from typing import Any


MODEL_ID = "nvidia/parakeet-tdt-0.6b-v3"
MODEL_REVISION = "7c35754d166cca382ad1e53e68b01e7c575f3a1d"
MODEL_FILENAME = "model.safetensors"
MODEL_FILE_SHA256 = "3a2026366188c8c68598edbbff92f8d11590a08e0ae2e6775544e7b07d6a5e11"
NEMO_FILE_SHA256 = "3cbdc85877e668ca7b82d0d56770eb1fac76691f55d6b97545e8d61ca588d10d"
TRANSFORMERS_COMMIT = "38a8b55f22d593c103e8bcc616413e70a5ef03ca"
COREMLTOOLS_VERSION = "9.0"
TORCH_VERSION = "2.7.0"
MODEL_INPUT_FRAMES = 3_000
MEL_BINS = 128
OUTPUT_FRAMES = 375
OUTPUT_FEATURES = 640
EXPECTED_DELTA_TENSOR_COUNT = 96
TRAINED_ENCODER_LAYERS = frozenset(range(20, 24))


NAME_REPLACEMENTS = (
    (".self_attn.pos_bias_u", ".self_attn.bias_u"),
    (".self_attn.pos_bias_v", ".self_attn.bias_v"),
    (".self_attn.linear_q", ".self_attn.q_proj"),
    (".self_attn.linear_k", ".self_attn.k_proj"),
    (".self_attn.linear_v", ".self_attn.v_proj"),
    (".self_attn.linear_out", ".self_attn.o_proj"),
    (".self_attn.linear_pos", ".self_attn.relative_k_proj"),
)


def normalized_package_version(version: str) -> str:
    return version.split("+", 1)[0]


def installed_vcs_commit(distribution_name: str) -> str | None:
    distribution = importlib_metadata.distribution(distribution_name)
    raw = distribution.read_text("direct_url.json")
    if raw is None:
        return None
    direct_url = json.loads(raw)
    vcs_info = direct_url.get("vcs_info")
    if not isinstance(vcs_info, dict):
        return None
    commit = vcs_info.get("commit_id")
    return str(commit) if commit is not None else None


def validate_export_toolchain(
    coremltools_version: str,
    torch_version: str,
    transformers_commit: str | None,
) -> None:
    actual = {
        "coremltools": normalized_package_version(coremltools_version),
        "torch": normalized_package_version(torch_version),
        "transformersCommit": transformers_commit,
    }
    expected = {
        "coremltools": COREMLTOOLS_VERSION,
        "torch": TORCH_VERSION,
        "transformersCommit": TRANSFORMERS_COMMIT,
    }
    mismatches = [
        f"{key}: expected {expected[key]!r}, got {actual[key]!r}"
        for key in expected
        if actual[key] != expected[key]
    ]
    if mismatches:
        raise RuntimeError("Unpinned Core ML export toolchain: " + "; ".join(mismatches))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def map_nemo_name_to_transformers(name: str) -> str:
    mapped = name
    for source, destination in NAME_REPLACEMENTS:
        mapped = mapped.replace(source, destination)
    return mapped


def encoder_layer(name: str) -> int:
    parts = name.split(".")
    if len(parts) < 4 or parts[0:2] != ["encoder", "layers"]:
        raise ValueError(f"Delta tensor is outside the encoder: {name}")
    try:
        return int(parts[2])
    except ValueError as error:
        raise ValueError(f"Invalid encoder layer in delta tensor: {name}") from error


def preserve_hybrid_fp16_weight(name: str) -> bool:
    """Keep fine-tuned encoder layers and the output projector unquantized."""

    return name.startswith("self_projector_") or any(
        f"self_encoder_layers_{layer}_" in name
        for layer in TRAINED_ENCODER_LAYERS
    )


def validate_delta_payload(payload: object) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ValueError("The VoxoL delta payload must be a dictionary.")
    expected = {
        "schemaVersion": 2,
        "artifactType": "voxol-parameter-delta",
        "baseModel": MODEL_ID,
        "baseRevision": MODEL_REVISION,
        "baseArtifactSHA256": NEMO_FILE_SHA256,
        "trainedTopEncoderLayers": 4,
        "trainDecoder": False,
        "trainJoint": False,
        "batchNormFrozen": True,
    }
    for key, value in expected.items():
        if payload.get(key) != value:
            raise ValueError(
                f"Delta metadata mismatch for {key}: "
                f"expected {value!r}, got {payload.get(key)!r}."
            )
    state_delta = payload.get("stateDelta")
    if not isinstance(state_delta, dict) or len(state_delta) != EXPECTED_DELTA_TENSOR_COUNT:
        raise ValueError(
            "Expected exactly "
            f"{EXPECTED_DELTA_TENSOR_COUNT} trainable encoder tensors."
        )
    layers = {encoder_layer(str(name)) for name in state_delta}
    if layers != TRAINED_ENCODER_LAYERS:
        raise ValueError(
            f"Delta encoder layers mismatch: expected {sorted(TRAINED_ENCODER_LAYERS)}, "
            f"got {sorted(layers)}."
        )
    mapped_names = [map_nemo_name_to_transformers(str(name)) for name in state_delta]
    if len(mapped_names) != len(set(mapped_names)):
        raise ValueError("Two NeMo delta tensors map to the same Transformers tensor.")
    return payload


def apply_delta(model: object, payload: dict[str, Any], torch: object) -> dict[str, float]:
    state_delta = payload["stateDelta"]
    model_state = model.state_dict()
    mapped = {
        map_nemo_name_to_transformers(str(source_name)): update
        for source_name, update in state_delta.items()
    }
    missing = sorted(set(mapped) - set(model_state))
    if missing:
        raise ValueError(f"Mapped delta tensor is absent from Transformers: {missing[0]}")

    maximum_rounding_error = 0.0
    total_parameters = 0
    with torch.no_grad():
        for name, source in mapped.items():
            destination = model_state[name]
            if tuple(source.shape) != tuple(destination.shape):
                raise ValueError(
                    f"Delta tensor shape mismatch for {name}: "
                    f"{tuple(source.shape)} != {tuple(destination.shape)}."
                )
            update = source.to(device=destination.device, dtype=destination.dtype)
            destination.add_(update)
            half_round_trip = destination.to(torch.float16).to(torch.float32)
            maximum_rounding_error = max(
                maximum_rounding_error,
                float((destination - half_round_trip).abs().max()),
            )
            total_parameters += destination.numel()
    return {
        "mappedTensorCount": len(mapped),
        "mappedParameterCount": total_parameters,
        "maximumFP16RoundingError": maximum_rounding_error,
    }


def require_empty_directory(path: Path) -> None:
    if path.exists() and any(path.iterdir()):
        raise ValueError(f"Output directory must be absent or empty: {path}")
    path.mkdir(parents=True, exist_ok=True)


def copy_runtime_support(template_root: Path, destination: Path) -> None:
    for component in ("decoder.mlpackage", "joint.mlpackage"):
        source = template_root / component
        if not source.is_dir():
            raise FileNotFoundError(f"Missing runtime template component: {source}")
        shutil.copytree(source, destination / component)
    tokenizer = template_root / "tokenizer.json"
    if not tokenizer.is_file():
        raise FileNotFoundError(f"Missing runtime tokenizer: {tokenizer}")
    shutil.copy2(tokenizer, destination / tokenizer.name)


def directory_size(path: Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def install_coreml_safe_attention(parakeet_module: object) -> None:
    """Keep masked attention finite because Core ML cannot preserve -inf here."""

    def forward(
        self: object,
        hidden_states: object,
        position_embeddings: object,
        attention_mask: object | None = None,
        **kwargs: object,
    ) -> tuple[object, object]:
        input_shape = hidden_states.shape[:-1]
        batch_size, sequence_length = input_shape
        hidden_shape = (batch_size, sequence_length, -1, self.head_dim)

        query_states = self.q_proj(hidden_states).view(hidden_shape).transpose(1, 2)
        key_states = self.k_proj(hidden_states).view(hidden_shape).transpose(1, 2)
        value_states = self.v_proj(hidden_states).view(hidden_shape).transpose(1, 2)
        query_states_with_bias_u = query_states + self.bias_u.view(
            1,
            self.config.num_attention_heads,
            1,
            self.head_dim,
        )
        query_states_with_bias_v = query_states + self.bias_v.view(
            1,
            self.config.num_attention_heads,
            1,
            self.head_dim,
        )
        relative_key_states = self.relative_k_proj(position_embeddings)
        relative_key_states = relative_key_states.view(
            batch_size,
            -1,
            self.config.num_attention_heads,
            self.head_dim,
        )
        matrix_bd = (
            query_states_with_bias_v
            @ relative_key_states.permute(0, 2, 3, 1)
        )
        matrix_bd = self._rel_shift(matrix_bd)[..., :sequence_length]
        matrix_bd = matrix_bd * self.scaling
        if attention_mask is not None:
            matrix_bd = matrix_bd.masked_fill(
                attention_mask.logical_not(),
                -10_000.0,
            )

        attention_interface = parakeet_module.ALL_ATTENTION_FUNCTIONS.get_interface(
            self.config._attn_implementation,
            parakeet_module.eager_attention_forward,
        )
        attention_output, attention_weights = attention_interface(
            self,
            query=query_states_with_bias_u,
            key=key_states,
            value=value_states,
            attention_mask=matrix_bd,
            dropout=0.0 if not self.training else self.attention_dropout,
            scaling=self.scaling,
            **kwargs,
        )
        attention_output = attention_output.reshape(*input_shape, -1).contiguous()
        return self.o_proj(attention_output), attention_weights

    parakeet_module.ParakeetEncoderAttention.forward = forward


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--delta", type=Path, required=True)
    parser.add_argument("--expected-delta-sha256", required=True)
    parser.add_argument("--runtime-template-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument(
        "--compute-precision-profile",
        choices=("fp16", "stable-fp16"),
        default="fp16",
    )
    parser.add_argument(
        "--variants",
        choices=(
            "fp16",
            "int8-linear-per-channel",
            "int4-linear-per-channel",
        ),
        nargs="+",
        default=(
            "fp16",
            "int8-linear-per-channel",
            "int4-linear-per-channel",
        ),
    )
    arguments = parser.parse_args()

    import coremltools as ct
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )
    from huggingface_hub import hf_hub_download
    import numpy as np
    import torch
    from transformers import ParakeetForTDT
    from transformers.models.parakeet import modeling_parakeet

    transformers_commit = installed_vcs_commit("transformers")
    validate_export_toolchain(ct.__version__, torch.__version__, transformers_commit)

    if sha256(arguments.delta) != arguments.expected_delta_sha256:
        raise ValueError("The candidate delta SHA-256 does not match the expected digest.")
    payload = validate_delta_payload(
        torch.load(arguments.delta, map_location="cpu", weights_only=True)
    )
    require_empty_directory(arguments.output_root)

    model_file = Path(
        hf_hub_download(
            repo_id=MODEL_ID,
            filename=MODEL_FILENAME,
            revision=MODEL_REVISION,
            cache_dir=arguments.cache_dir,
        )
    )
    if model_file.stat().st_size != 2_508_311_120 or sha256(model_file) != MODEL_FILE_SHA256:
        raise ValueError("The pinned Transformers checkpoint failed integrity validation.")

    install_coreml_safe_attention(modeling_parakeet)
    model = ParakeetForTDT.from_pretrained(
        MODEL_ID,
        revision=MODEL_REVISION,
        cache_dir=arguments.cache_dir,
        dtype=torch.float32,
    ).eval()
    delta_application = apply_delta(model, payload, torch)

    class VoxoLEncoder(torch.nn.Module):
        def __init__(self, encoder: object, projector: object) -> None:
            super().__init__()
            self.encoder = encoder
            self.projector = projector

        def forward(
            self,
            input_features: torch.Tensor,
            attention_mask: torch.Tensor,
        ) -> tuple[torch.Tensor, torch.Tensor]:
            outputs = self.encoder(
                input_features=input_features,
                attention_mask=attention_mask,
                output_attention_mask=True,
                return_dict=True,
            )
            hidden = self.projector(outputs.last_hidden_state)
            return hidden.to(torch.float32), outputs.attention_mask.to(torch.int32)

    wrapper = VoxoLEncoder(model.encoder, model.encoder_projector).eval()
    del model
    del payload

    torch.manual_seed(1337)
    example_features = torch.randn(
        1,
        MODEL_INPUT_FRAMES,
        MEL_BINS,
        dtype=torch.float32,
    )
    example_mask = torch.zeros(1, MODEL_INPUT_FRAMES, dtype=torch.int32)
    example_mask[:, :1_877] = 1
    with torch.inference_mode():
        reference_hidden, reference_mask = wrapper(example_features, example_mask)
        traced = torch.jit.trace(
            wrapper,
            (example_features, example_mask),
            strict=False,
            check_trace=False,
        )
        traced = torch.jit.freeze(traced.eval())
    del wrapper

    started = time.perf_counter()
    if arguments.compute_precision_profile == "stable-fp16":
        compute_precision = ct.transform.FP16ComputePrecision(
            op_selector=lambda operation: operation.op_type
            not in {"softmax", "layer_norm"}
        )
    else:
        compute_precision = ct.precision.FLOAT16

    fp16_model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(
                name="input_features",
                shape=(1, MODEL_INPUT_FRAMES, MEL_BINS),
                dtype=np.float32,
            ),
            ct.TensorType(
                name="attention_mask",
                shape=(1, MODEL_INPUT_FRAMES),
                dtype=np.int32,
            ),
        ],
        outputs=[
            ct.TensorType(name="encoder_hidden", dtype=np.float32),
            ct.TensorType(name="encoder_mask", dtype=np.int32),
        ],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=compute_precision,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    conversion_seconds = time.perf_counter() - started
    del traced

    common_metadata = {
        "voxol.base_model": MODEL_ID,
        "voxol.base_revision": MODEL_REVISION,
        "voxol.base_transformers_sha256": MODEL_FILE_SHA256,
        "voxol.delta_sha256": arguments.expected_delta_sha256,
        "voxol.transformers_commit": TRANSFORMERS_COMMIT,
        "voxol.runtime_contract": "encoder-3000x128-to-375x640-v1",
        "voxol.compute_precision_profile": arguments.compute_precision_profile,
    }
    for key, value in common_metadata.items():
        fp16_model.user_defined_metadata[key] = value

    variants: dict[str, object] = {}
    if "fp16" in arguments.variants:
        variants["fp16"] = fp16_model
    quantization_configs = {
        "int8-linear-per-channel": OpLinearQuantizerConfig(
            mode="linear_symmetric",
            dtype="int8",
            granularity="per_channel",
            weight_threshold=512,
        ),
        "int4-linear-per-channel": OpLinearQuantizerConfig(
            mode="linear_symmetric",
            dtype="int4",
            granularity="per_channel",
            weight_threshold=512,
        ),
    }
    for name, config in quantization_configs.items():
        if name not in arguments.variants:
            continue
        optimized = linear_quantize_weights(
            fp16_model,
            OptimizationConfig(global_config=config),
        )
        for key, value in common_metadata.items():
            optimized.user_defined_metadata[key] = value
        optimized.user_defined_metadata["voxol.quantization"] = name
        variants[name] = optimized

    feature_input = example_features.numpy()
    mask_input = example_mask.numpy()
    reference_hidden_array = reference_hidden.numpy()
    reference_mask_array = reference_mask.numpy()
    reports: dict[str, dict[str, object]] = {}

    for name, coreml_model in variants.items():
        runtime_root = arguments.output_root / name
        runtime_root.mkdir(parents=True)
        encoder_path = runtime_root / "encoder.mlpackage"
        coreml_model.save(str(encoder_path))
        copy_runtime_support(arguments.runtime_template_root, runtime_root)

        measured = ct.models.MLModel(
            str(encoder_path),
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )
        output = measured.predict(
            {
                "input_features": feature_input,
                "attention_mask": mask_input,
            }
        )
        candidate_hidden = np.asarray(output["encoder_hidden"], dtype=np.float32)
        candidate_mask = np.asarray(output["encoder_mask"], dtype=np.int32)
        valid_elements = np.broadcast_to(
            reference_mask_array.astype(bool)[..., None],
            reference_hidden_array.shape,
        )
        reference_valid = reference_hidden_array[valid_elements]
        candidate_valid = candidate_hidden[valid_elements]
        if not np.isfinite(reference_valid).all():
            raise ValueError("The PyTorch encoder produced non-finite valid values.")
        if not np.isfinite(candidate_valid).all():
            raise ValueError(f"Core ML {name} produced non-finite valid values.")
        reports[name] = {
            "encoderBytes": directory_size(encoder_path),
            "runtimeBytes": directory_size(runtime_root),
            "hiddenShape": list(candidate_hidden.shape),
            "maskShape": list(candidate_mask.shape),
            "nonFiniteEncoderValueCount": int(
                candidate_hidden.size - np.isfinite(candidate_hidden).sum()
            ),
            "maximumAbsoluteEncoderError": float(
                np.max(np.abs(reference_valid - candidate_valid))
            ),
            "normalizedEncoderL2Error": float(
                np.linalg.norm(reference_valid - candidate_valid)
                / max(np.linalg.norm(reference_valid), 1e-12)
            ),
            "encoderMaskExact": bool(np.array_equal(reference_mask_array, candidate_mask)),
        }
        if reports[name]["hiddenShape"] != [1, OUTPUT_FRAMES, OUTPUT_FEATURES]:
            raise ValueError(f"Unexpected Core ML encoder shape for {name}.")
        if reports[name]["maskShape"] != [1, OUTPUT_FRAMES]:
            raise ValueError(f"Unexpected Core ML encoder-mask shape for {name}.")

    metadata = {
        "schemaVersion": 1,
        "model": MODEL_ID,
        "revision": MODEL_REVISION,
        "transformersCommit": TRANSFORMERS_COMMIT,
        "toolchain": {
            "python": sys.version,
            "coremltools": ct.__version__,
            "torch": torch.__version__,
            "transformersCommit": transformers_commit,
        },
        "baseTransformersSHA256": MODEL_FILE_SHA256,
        "baseNeMoSHA256": NEMO_FILE_SHA256,
        "delta": str(arguments.delta),
        "deltaSHA256": arguments.expected_delta_sha256,
        "deltaApplication": delta_application,
        "conversionSeconds": conversion_seconds,
        "computePrecisionProfile": arguments.compute_precision_profile,
        "variants": reports,
    }
    (arguments.output_root / "export-report.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(metadata, indent=2, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
