#!/usr/bin/env python3
"""Trace the exact NeMo encoder, then convert it to VoxoL's Core ML contract.

The two-process trace/convert split keeps peak memory bounded on 16 GB Macs.
The encoder wrapper follows FluidInference Mobius' direct-NeMo export approach,
adapted to VoxoL's fixed 30-second feature and projected-hidden contract.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_voxol_coreml_candidate import (
    MODEL_FILE_SHA256,
    MODEL_ID,
    MODEL_REVISION,
    NEMO_FILE_SHA256,
    copy_runtime_support,
    directory_size,
    normalized_package_version,
    require_empty_directory,
    sha256,
    validate_delta_payload,
)


NEMO_VERSION = "2.3.1"
TORCH_VERSION = "2.7.0"
COREMLTOOLS_VERSION = "9.0"
MODEL_INPUT_FRAMES = 3_000
MEL_BINS = 128
MAX_AUDIO_SAMPLES = 480_000
FEATURE_OUTPUT_FRAMES = 375
WAVEFORM_OUTPUT_FRAMES = 376
OUTPUT_FEATURES = 640
VALIDATION_INPUT_FRAMES = 1_877
TRACE_FILENAME = "encoder-traced.pt"
VALIDATION_FILENAME = "validation-inputs-and-reference.npz"
TRACE_METADATA_FILENAME = "trace-metadata.json"
DECODER_TRACE_FILENAME = "decoder-traced.pt"
JOINT_TRACE_FILENAME = "joint-traced.pt"
HEADS_VALIDATION_FILENAME = "heads-validation-inputs-and-reference.npz"
HEADS_TRACE_METADATA_FILENAME = "heads-trace-metadata.json"
MAX_TRACE_NORMALIZED_L2_ERROR = 1e-5


def validate_nemo_toolchain(
    nemo_version: str,
    torch_version: str,
    coremltools_version: str | None = None,
) -> None:
    actual = {
        "nemo": normalized_package_version(nemo_version),
        "torch": normalized_package_version(torch_version),
    }
    expected = {"nemo": NEMO_VERSION, "torch": TORCH_VERSION}
    if coremltools_version is not None:
        actual["coremltools"] = normalized_package_version(coremltools_version)
        expected["coremltools"] = COREMLTOOLS_VERSION
    mismatches = [
        f"{name}: expected {expected[name]!r}, got {actual[name]!r}"
        for name in expected
        if actual[name] != expected[name]
    ]
    if mismatches:
        raise RuntimeError("Unpinned direct-NeMo export toolchain: " + "; ".join(mismatches))


def apply_nemo_delta(
    model: object,
    payload: dict[str, Any],
    torch: object,
) -> dict[str, int | float]:
    state_delta = payload["stateDelta"]
    model_state = model.state_dict()
    missing = sorted(set(state_delta) - set(model_state))
    if missing:
        raise ValueError(f"Delta tensor is absent from the NeMo model: {missing[0]}")

    maximum_update = 0.0
    parameter_count = 0
    with torch.no_grad():
        for name, source in state_delta.items():
            destination = model_state[name]
            if tuple(source.shape) != tuple(destination.shape):
                raise ValueError(
                    f"Delta tensor shape mismatch for {name}: "
                    f"{tuple(source.shape)} != {tuple(destination.shape)}"
                )
            update = source.to(device=destination.device, dtype=destination.dtype)
            destination.add_(update)
            maximum_update = max(maximum_update, float(update.abs().max()))
            parameter_count += destination.numel()
    return {
        "tensorCount": len(state_delta),
        "parameterCount": parameter_count,
        "maximumAbsoluteUpdate": maximum_update,
    }


def normalized_l2(reference: object, candidate: object, np: object) -> float:
    reference64 = np.asarray(reference, dtype=np.float64)
    candidate64 = np.asarray(candidate, dtype=np.float64)
    return float(
        np.linalg.norm(reference64 - candidate64)
        / max(np.linalg.norm(reference64), 1e-12)
    )


def trace_encoder(arguments: argparse.Namespace) -> None:
    import nemo
    import nemo.collections.asr as nemo_asr
    import numpy as np
    import torch

    validate_nemo_toolchain(nemo.__version__, torch.__version__)
    if sha256(arguments.base_nemo) != NEMO_FILE_SHA256:
        raise ValueError("The pinned NeMo checkpoint failed SHA-256 validation.")
    if sha256(arguments.delta) != arguments.expected_delta_sha256:
        raise ValueError("The candidate delta failed SHA-256 validation.")
    payload = validate_delta_payload(
        torch.load(arguments.delta, map_location="cpu", weights_only=True)
    )
    require_empty_directory(arguments.output_root)

    model = nemo_asr.models.EncDecRNNTBPEModel.restore_from(
        str(arguments.base_nemo),
        map_location="cpu",
    ).eval()
    delta_application = apply_nemo_delta(model, payload, torch)

    class VoxoLNeMoFeatureEncoder(torch.nn.Module):
        def __init__(self, encoder: object, projector: object) -> None:
            super().__init__()
            self.encoder = encoder
            self.projector = projector

        def forward(
            self,
            input_features: torch.Tensor,
            attention_mask: torch.Tensor,
        ) -> tuple[torch.Tensor, torch.Tensor]:
            input_lengths = attention_mask.to(dtype=torch.long).sum(dim=1)
            encoded, encoded_lengths = self.encoder(
                audio_signal=input_features.transpose(1, 2),
                length=input_lengths,
            )
            projected = self.projector(encoded.transpose(1, 2))
            frame_indices = torch.arange(
                projected.shape[1],
                device=projected.device,
            ).unsqueeze(0)
            output_mask = frame_indices < encoded_lengths.unsqueeze(1)
            return projected.to(torch.float32), output_mask.to(torch.int32)

    class VoxoLNeMoWaveformEncoder(torch.nn.Module):
        def __init__(
            self,
            preprocessor: object,
            encoder: object,
            projector: object,
        ) -> None:
            super().__init__()
            self.preprocessor = preprocessor
            self.encoder = encoder
            self.projector = projector

        def forward(
            self,
            audio_signal: torch.Tensor,
            audio_length: torch.Tensor,
        ) -> tuple[torch.Tensor, torch.Tensor]:
            features, feature_lengths = self.preprocessor(
                input_signal=audio_signal,
                length=audio_length.to(dtype=torch.long),
            )
            encoded, encoded_lengths = self.encoder(
                audio_signal=features,
                length=feature_lengths,
            )
            projected = self.projector(encoded.transpose(1, 2))
            frame_indices = torch.arange(
                projected.shape[1],
                device=projected.device,
            ).unsqueeze(0)
            output_mask = frame_indices < encoded_lengths.unsqueeze(1)
            return projected.to(torch.float32), output_mask.to(torch.int32)

    torch.manual_seed(1_337)
    if arguments.input_contract == "features":
        wrapper = VoxoLNeMoFeatureEncoder(model.encoder, model.joint.enc).eval()
        trace_inputs = (
            torch.randn(
                (1, MODEL_INPUT_FRAMES, MEL_BINS),
                dtype=torch.float32,
            ),
            torch.ones((1, MODEL_INPUT_FRAMES), dtype=torch.int32),
        )
        validation_inputs = (
            torch.randn(
                (1, MODEL_INPUT_FRAMES, MEL_BINS),
                dtype=torch.float32,
            ),
            torch.cat(
                [
                    torch.ones((1, VALIDATION_INPUT_FRAMES), dtype=torch.int32),
                    torch.zeros(
                        (1, MODEL_INPUT_FRAMES - VALIDATION_INPUT_FRAMES),
                        dtype=torch.int32,
                    ),
                ],
                dim=1,
            ),
        )
        runtime_contract = "encoder-3000x128-to-375x640-v1"
        expected_output_frames = FEATURE_OUTPUT_FRAMES
        validation_payload = {
            "input_features": validation_inputs[0].numpy(),
            "attention_mask": validation_inputs[1].numpy(),
        }
    else:
        import soundfile as sf

        wrapper = VoxoLNeMoWaveformEncoder(
            model.preprocessor,
            model.encoder,
            model.joint.enc,
        ).eval()
        trace_inputs = (
            torch.randn((1, MAX_AUDIO_SAMPLES), dtype=torch.float32),
            torch.tensor([MAX_AUDIO_SAMPLES], dtype=torch.int32),
        )
        if arguments.validation_audio is None:
            validation_sample_count = MAX_AUDIO_SAMPLES // 2
            validation_audio = torch.randn(
                (1, MAX_AUDIO_SAMPLES),
                dtype=torch.float32,
            )
            validation_audio[:, validation_sample_count:] = 0
        else:
            waveform, sample_rate = sf.read(
                arguments.validation_audio,
                dtype="float32",
                always_2d=False,
            )
            if sample_rate != 16_000 or waveform.ndim != 1:
                raise ValueError("Validation audio must be mono 16 kHz.")
            validation_sample_count = int(waveform.shape[0])
            if not 0 < validation_sample_count <= MAX_AUDIO_SAMPLES:
                raise ValueError("Validation audio exceeds the fixed Core ML window.")
            padded = np.zeros((1, MAX_AUDIO_SAMPLES), dtype=np.float32)
            padded[0, :validation_sample_count] = waveform
            validation_audio = torch.from_numpy(padded)
        validation_inputs = (
            validation_audio,
            torch.tensor([validation_sample_count], dtype=torch.int32),
        )
        runtime_contract = "waveform-480000-to-376x640-v2"
        expected_output_frames = WAVEFORM_OUTPUT_FRAMES
        validation_payload = {
            "audio_signal": validation_inputs[0].numpy(),
            "audio_length": validation_inputs[1].numpy(),
        }

    with torch.inference_mode():
        reference_hidden, reference_mask = wrapper(*validation_inputs)
        traced = torch.jit.trace(
            wrapper,
            trace_inputs,
            strict=False,
            check_trace=False,
        )
        traced = torch.jit.freeze(traced.eval())
        traced_hidden, traced_mask = traced(*validation_inputs)

    if list(reference_hidden.shape) != [1, expected_output_frames, OUTPUT_FEATURES]:
        raise ValueError(f"Unexpected NeMo encoder shape: {list(reference_hidden.shape)}")
    if list(reference_mask.shape) != [1, expected_output_frames]:
        raise ValueError(f"Unexpected NeMo encoder-mask shape: {list(reference_mask.shape)}")
    if not torch.equal(reference_mask, traced_mask):
        raise ValueError("The traced encoder changed the NeMo output mask.")
    trace_error = normalized_l2(
        reference_hidden.numpy(),
        traced_hidden.numpy(),
        np,
    )
    if trace_error > MAX_TRACE_NORMALIZED_L2_ERROR:
        raise ValueError(f"The traced encoder diverged from eager NeMo: {trace_error}")

    torch.jit.save(traced, str(arguments.output_root / TRACE_FILENAME))
    np.savez_compressed(
        arguments.output_root / VALIDATION_FILENAME,
        **validation_payload,
        encoder_hidden=reference_hidden.numpy(),
        encoder_mask=reference_mask.numpy(),
    )
    metadata = {
        "schemaVersion": 1,
        "model": MODEL_ID,
        "revision": MODEL_REVISION,
        "baseNeMo": str(arguments.base_nemo.resolve()),
        "baseNeMoSHA256": NEMO_FILE_SHA256,
        "baseTransformersSHA256": MODEL_FILE_SHA256,
        "delta": str(arguments.delta.resolve()),
        "deltaSHA256": arguments.expected_delta_sha256,
        "deltaApplication": delta_application,
        "toolchain": {
            "python": sys.version,
            "nemo": nemo.__version__,
            "torch": torch.__version__,
        },
        "inputContract": arguments.input_contract,
        "runtimeContract": runtime_contract,
        "outputFrameCount": expected_output_frames,
        "traceValidationNormalizedL2Error": trace_error,
    }
    (arguments.output_root / TRACE_METADATA_FILENAME).write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(metadata, indent=2, sort_keys=True), flush=True)


def trace_runtime_heads(arguments: argparse.Namespace) -> None:
    """Trace NeMo's exact prediction and joint networks to VoxoL's contracts."""

    import nemo
    import nemo.collections.asr as nemo_asr
    import numpy as np
    import torch

    validate_nemo_toolchain(nemo.__version__, torch.__version__)
    if sha256(arguments.base_nemo) != NEMO_FILE_SHA256:
        raise ValueError("The pinned NeMo checkpoint failed SHA-256 validation.")
    if sha256(arguments.delta) != arguments.expected_delta_sha256:
        raise ValueError("The candidate delta failed SHA-256 validation.")
    payload = validate_delta_payload(
        torch.load(arguments.delta, map_location="cpu", weights_only=True)
    )
    require_empty_directory(arguments.output_root)

    model = nemo_asr.models.EncDecRNNTBPEModel.restore_from(
        str(arguments.base_nemo),
        map_location="cpu",
    ).eval()
    delta_application = apply_nemo_delta(model, payload, torch)
    model.decoder._rnnt_export = True
    model.joint.set_fuse_loss_wer(False)

    class VoxoLNeMoDecoder(torch.nn.Module):
        def __init__(self, decoder: object, projector: object) -> None:
            super().__init__()
            self.decoder = decoder
            self.projector = projector

        def forward(
            self,
            input_ids: torch.Tensor,
            hidden: torch.Tensor,
            cell: torch.Tensor,
        ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
            target_length = torch.ones_like(input_ids[:, 0], dtype=torch.long)
            decoded, _, state = self.decoder(
                targets=input_ids.to(dtype=torch.long),
                target_length=target_length,
                states=[hidden, cell],
            )
            projected = self.projector(decoded.transpose(1, 2))
            return (
                projected.to(torch.float32),
                state[0].to(torch.float32),
                state[1].to(torch.float32),
            )

    class VoxoLNeMoJoint(torch.nn.Module):
        def __init__(
            self,
            joint_network: object,
            token_output_count: int,
            duration_output_count: int,
        ) -> None:
            super().__init__()
            self.joint_network = joint_network
            self.token_output_count = token_output_count
            self.duration_output_count = duration_output_count

        def forward(
            self,
            encoder_frame: torch.Tensor,
            decoder_state: torch.Tensor,
        ) -> tuple[torch.Tensor, torch.Tensor]:
            logits = self.joint_network(encoder_frame + decoder_state)
            return (
                logits[:, : self.token_output_count].to(torch.float32),
                logits[:, -self.duration_output_count :].to(torch.float32),
            )

    decoder_layers = int(model.decoder.pred_rnn_layers)
    decoder_hidden = int(model.decoder.pred_hidden)
    token_output_count = int(model.tokenizer.vocab_size) + 1
    duration_output_count = int(model.joint.num_extra_outputs)
    if (decoder_layers, decoder_hidden) != (2, OUTPUT_FEATURES):
        raise ValueError(
            "Unexpected NeMo decoder contract: "
            f"layers={decoder_layers}, hidden={decoder_hidden}."
        )
    if (token_output_count, duration_output_count) != (8_193, 5):
        raise ValueError(
            "Unexpected NeMo joint contract: "
            f"tokens={token_output_count}, durations={duration_output_count}."
        )

    decoder = VoxoLNeMoDecoder(model.decoder, model.joint.pred).eval()
    joint = VoxoLNeMoJoint(
        model.joint.joint_net,
        token_output_count,
        duration_output_count,
    ).eval()
    input_ids = torch.tensor([[int(model.decoder.blank_idx)]], dtype=torch.int32)
    hidden = torch.zeros((decoder_layers, 1, decoder_hidden), dtype=torch.float32)
    cell = torch.zeros_like(hidden)
    torch.manual_seed(1_337)
    encoder_frame = torch.randn((1, decoder_hidden), dtype=torch.float32)

    with torch.inference_mode():
        decoder_reference = decoder(input_ids, hidden, cell)
        joint_reference = joint(encoder_frame, decoder_reference[0][:, -1, :])
        traced_decoder = torch.jit.trace(
            decoder,
            (input_ids, hidden, cell),
            strict=False,
            check_trace=False,
        )
        traced_joint = torch.jit.trace(
            joint,
            (encoder_frame, decoder_reference[0][:, -1, :]),
            strict=False,
            check_trace=False,
        )
        traced_decoder = torch.jit.freeze(traced_decoder.eval())
        traced_joint = torch.jit.freeze(traced_joint.eval())
        decoder_traced_output = traced_decoder(input_ids, hidden, cell)
        joint_traced_output = traced_joint(
            encoder_frame,
            decoder_reference[0][:, -1, :],
        )

    trace_errors = {
        "decoderHidden": normalized_l2(
            decoder_reference[0].numpy(), decoder_traced_output[0].numpy(), np
        ),
        "decoderNextHidden": normalized_l2(
            decoder_reference[1].numpy(), decoder_traced_output[1].numpy(), np
        ),
        "decoderNextCell": normalized_l2(
            decoder_reference[2].numpy(), decoder_traced_output[2].numpy(), np
        ),
        "jointTokenLogits": normalized_l2(
            joint_reference[0].numpy(), joint_traced_output[0].numpy(), np
        ),
        "jointDurationLogits": normalized_l2(
            joint_reference[1].numpy(), joint_traced_output[1].numpy(), np
        ),
    }
    if max(trace_errors.values()) > MAX_TRACE_NORMALIZED_L2_ERROR:
        raise ValueError(f"The traced runtime heads diverged from eager NeMo: {trace_errors}")

    torch.jit.save(traced_decoder, str(arguments.output_root / DECODER_TRACE_FILENAME))
    torch.jit.save(traced_joint, str(arguments.output_root / JOINT_TRACE_FILENAME))
    np.savez_compressed(
        arguments.output_root / HEADS_VALIDATION_FILENAME,
        input_ids=input_ids.numpy(),
        hidden=hidden.numpy(),
        cell=cell.numpy(),
        encoder_frame=encoder_frame.numpy(),
        decoder_hidden=decoder_reference[0].numpy(),
        next_hidden=decoder_reference[1].numpy(),
        next_cell=decoder_reference[2].numpy(),
        token_logits=joint_reference[0].numpy(),
        duration_logits=joint_reference[1].numpy(),
    )
    metadata = {
        "schemaVersion": 1,
        "model": MODEL_ID,
        "revision": MODEL_REVISION,
        "baseNeMo": str(arguments.base_nemo.resolve()),
        "baseNeMoSHA256": NEMO_FILE_SHA256,
        "delta": str(arguments.delta.resolve()),
        "deltaSHA256": arguments.expected_delta_sha256,
        "deltaApplication": delta_application,
        "toolchain": {
            "python": sys.version,
            "nemo": nemo.__version__,
            "torch": torch.__version__,
        },
        "runtimeContract": "decoder-joint-nemo-direct-v1",
        "traceValidationNormalizedL2Errors": trace_errors,
    }
    (arguments.output_root / HEADS_TRACE_METADATA_FILENAME).write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(metadata, indent=2, sort_keys=True), flush=True)


def convert_encoder(arguments: argparse.Namespace) -> None:
    import coremltools as ct
    import numpy as np
    import torch

    validate_nemo_toolchain(NEMO_VERSION, torch.__version__, ct.__version__)
    trace_metadata = json.loads(
        (arguments.trace_root / TRACE_METADATA_FILENAME).read_text(encoding="utf-8")
    )
    if trace_metadata.get("deltaSHA256") != arguments.expected_delta_sha256:
        raise ValueError("The traced encoder uses a different candidate delta.")
    require_empty_directory(arguments.output_root)
    traced = torch.jit.load(str(arguments.trace_root / TRACE_FILENAME), map_location="cpu")
    validation = np.load(arguments.trace_root / VALIDATION_FILENAME)
    input_contract = str(trace_metadata.get("inputContract", "features"))
    if input_contract == "features":
        coreml_inputs = [
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
        ]
        validation_inputs = {
            "input_features": validation["input_features"],
            "attention_mask": validation["attention_mask"],
        }
    elif input_contract == "waveform":
        coreml_inputs = [
            ct.TensorType(
                name="audio_signal",
                shape=(1, MAX_AUDIO_SAMPLES),
                dtype=np.float32,
            ),
            ct.TensorType(
                name="audio_length",
                shape=(1,),
                dtype=np.int32,
            ),
        ]
        validation_inputs = {
            "audio_signal": validation["audio_signal"],
            "audio_length": validation["audio_length"],
        }
    else:
        raise ValueError(f"Unsupported traced input contract: {input_contract}")

    model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=coreml_inputs,
        outputs=[
            ct.TensorType(name="encoder_hidden", dtype=np.float32),
            ct.TensorType(name="encoder_mask", dtype=np.int32),
        ],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    model.user_defined_metadata.update(
        {
            "voxol.base_model": MODEL_ID,
            "voxol.base_revision": MODEL_REVISION,
            "voxol.base_nemo_sha256": NEMO_FILE_SHA256,
            "voxol.delta_sha256": arguments.expected_delta_sha256,
            "voxol.runtime_contract": str(trace_metadata["runtimeContract"]),
            "voxol.export_origin": "nemo-direct-mobius-derived",
            "voxol.compute_precision_profile": "fp16",
        }
    )
    encoder_path = arguments.output_root / "encoder.mlpackage"
    model.save(str(encoder_path))
    copy_runtime_support(arguments.runtime_template_root, arguments.output_root)
    del model, traced

    runtime = ct.models.MLModel(str(encoder_path), compute_units=ct.ComputeUnit.ALL)
    prediction = runtime.predict(validation_inputs)
    reference_hidden = np.asarray(validation["encoder_hidden"], dtype=np.float32)
    reference_mask = np.asarray(validation["encoder_mask"], dtype=np.int32)
    candidate_hidden = np.asarray(prediction["encoder_hidden"], dtype=np.float32)
    candidate_mask = np.asarray(prediction["encoder_mask"], dtype=np.int32)
    if not np.array_equal(reference_mask, candidate_mask):
        raise ValueError("The Core ML encoder changed the NeMo output mask.")
    valid = np.broadcast_to(reference_mask.astype(bool)[..., None], reference_hidden.shape)
    reference_valid = reference_hidden[valid]
    candidate_valid = candidate_hidden[valid]
    if not np.isfinite(candidate_valid).all():
        raise ValueError("The direct-NeMo Core ML encoder produced non-finite values.")

    report = {
        "schemaVersion": 1,
        "variant": "nemo-direct-fp16",
        "inputContract": input_contract,
        "traceRoot": str(arguments.trace_root.resolve()),
        "runtimeTemplateRoot": str(arguments.runtime_template_root.resolve()),
        "deltaSHA256": arguments.expected_delta_sha256,
        "toolchain": {
            "python": sys.version,
            "coremltools": ct.__version__,
            "torch": torch.__version__,
        },
        "encoderBytes": directory_size(encoder_path),
        "runtimeBytes": directory_size(arguments.output_root),
        "hiddenShape": list(candidate_hidden.shape),
        "maskShape": list(candidate_mask.shape),
        "encoderMaskExact": True,
        "validFrameCount": int(reference_mask.sum()),
        "maximumAbsoluteEncoderError": float(
            np.max(np.abs(reference_valid - candidate_valid))
        ),
        "normalizedEncoderL2Error": normalized_l2(
            reference_valid,
            candidate_valid,
            np,
        ),
    }
    (arguments.output_root / "export-report.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)


def convert_runtime_heads(arguments: argparse.Namespace) -> None:
    """Convert exact NeMo decoder/joint traces and assemble a VoxoL runtime."""

    import coremltools as ct
    import numpy as np
    import torch

    validate_nemo_toolchain(NEMO_VERSION, torch.__version__, ct.__version__)
    trace_metadata = json.loads(
        (arguments.trace_root / HEADS_TRACE_METADATA_FILENAME).read_text(
            encoding="utf-8"
        )
    )
    if trace_metadata.get("deltaSHA256") != arguments.expected_delta_sha256:
        raise ValueError("The traced runtime heads use a different candidate delta.")
    require_empty_directory(arguments.output_root)
    validation = np.load(arguments.trace_root / HEADS_VALIDATION_FILENAME)
    traced_decoder = torch.jit.load(
        str(arguments.trace_root / DECODER_TRACE_FILENAME), map_location="cpu"
    )
    traced_joint = torch.jit.load(
        str(arguments.trace_root / JOINT_TRACE_FILENAME), map_location="cpu"
    )
    precision = (
        ct.precision.FLOAT32
        if arguments.compute_precision_profile == "fp32"
        else ct.precision.FLOAT16
    )

    decoder_model = ct.convert(
        traced_decoder,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, 1), dtype=np.int32),
            ct.TensorType(name="hidden", shape=(2, 1, OUTPUT_FEATURES), dtype=np.float32),
            ct.TensorType(name="cell", shape=(2, 1, OUTPUT_FEATURES), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="decoder_hidden", dtype=np.float32),
            ct.TensorType(name="next_hidden", dtype=np.float32),
            ct.TensorType(name="next_cell", dtype=np.float32),
        ],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=precision,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    joint_model = ct.convert(
        traced_joint,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(
                name="encoder_frame", shape=(1, OUTPUT_FEATURES), dtype=np.float32
            ),
            ct.TensorType(
                name="decoder_state", shape=(1, OUTPUT_FEATURES), dtype=np.float32
            ),
        ],
        outputs=[
            ct.TensorType(name="token_logits", dtype=np.float32),
            ct.TensorType(name="duration_logits", dtype=np.float32),
        ],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=precision,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    common_metadata = {
        "voxol.base_model": MODEL_ID,
        "voxol.base_revision": MODEL_REVISION,
        "voxol.base_nemo_sha256": NEMO_FILE_SHA256,
        "voxol.delta_sha256": arguments.expected_delta_sha256,
        "voxol.export_origin": "nemo-direct-mobius-derived",
        "voxol.compute_precision_profile": arguments.compute_precision_profile,
    }
    decoder_model.user_defined_metadata.update(
        {**common_metadata, "voxol.runtime_contract": "decoder-nemo-direct-v1"}
    )
    joint_model.user_defined_metadata.update(
        {**common_metadata, "voxol.runtime_contract": "joint-nemo-direct-v1"}
    )

    encoder_source = arguments.runtime_template_root / "encoder.mlpackage"
    tokenizer_source = arguments.runtime_template_root / "tokenizer.json"
    if not encoder_source.is_dir() or not tokenizer_source.is_file():
        raise FileNotFoundError("Runtime template is missing its encoder or tokenizer.")
    import shutil

    shutil.copytree(encoder_source, arguments.output_root / "encoder.mlpackage")
    shutil.copy2(tokenizer_source, arguments.output_root / "tokenizer.json")
    decoder_path = arguments.output_root / "decoder.mlpackage"
    joint_path = arguments.output_root / "joint.mlpackage"
    decoder_model.save(str(decoder_path))
    joint_model.save(str(joint_path))
    del decoder_model, joint_model, traced_decoder, traced_joint

    decoder_runtime = ct.models.MLModel(
        str(decoder_path), compute_units=ct.ComputeUnit.CPU_ONLY
    )
    decoder_output = decoder_runtime.predict(
        {
            "input_ids": validation["input_ids"],
            "hidden": validation["hidden"],
            "cell": validation["cell"],
        }
    )
    joint_runtime = ct.models.MLModel(
        str(joint_path), compute_units=ct.ComputeUnit.CPU_ONLY
    )
    joint_output = joint_runtime.predict(
        {
            "encoder_frame": validation["encoder_frame"],
            "decoder_state": np.asarray(
                decoder_output["decoder_hidden"], dtype=np.float32
            )[:, -1, :],
        }
    )
    comparisons = {
        "decoderHidden": normalized_l2(
            validation["decoder_hidden"], decoder_output["decoder_hidden"], np
        ),
        "decoderNextHidden": normalized_l2(
            validation["next_hidden"], decoder_output["next_hidden"], np
        ),
        "decoderNextCell": normalized_l2(
            validation["next_cell"], decoder_output["next_cell"], np
        ),
        "jointTokenLogits": normalized_l2(
            validation["token_logits"], joint_output["token_logits"], np
        ),
        "jointDurationLogits": normalized_l2(
            validation["duration_logits"], joint_output["duration_logits"], np
        ),
    }
    report = {
        "schemaVersion": 1,
        "variant": f"nemo-direct-heads-{arguments.compute_precision_profile}",
        "traceRoot": str(arguments.trace_root.resolve()),
        "runtimeTemplateRoot": str(arguments.runtime_template_root.resolve()),
        "deltaSHA256": arguments.expected_delta_sha256,
        "toolchain": {
            "python": sys.version,
            "coremltools": ct.__version__,
            "torch": torch.__version__,
        },
        "runtimeBytes": directory_size(arguments.output_root),
        "componentBytes": {
            "encoder": directory_size(arguments.output_root / "encoder.mlpackage"),
            "decoder": directory_size(decoder_path),
            "joint": directory_size(joint_path),
        },
        "normalizedL2Errors": comparisons,
    }
    (arguments.output_root / "heads-export-report.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subcommands = result.add_subparsers(dest="command", required=True)

    trace = subcommands.add_parser("trace")
    trace.add_argument("--base-nemo", type=Path, required=True)
    trace.add_argument("--delta", type=Path, required=True)
    trace.add_argument("--expected-delta-sha256", required=True)
    trace.add_argument("--output-root", type=Path, required=True)
    trace.add_argument(
        "--input-contract",
        choices=("features", "waveform"),
        default="features",
    )
    trace.add_argument("--validation-audio", type=Path)

    trace_heads = subcommands.add_parser("trace-heads")
    trace_heads.add_argument("--base-nemo", type=Path, required=True)
    trace_heads.add_argument("--delta", type=Path, required=True)
    trace_heads.add_argument("--expected-delta-sha256", required=True)
    trace_heads.add_argument("--output-root", type=Path, required=True)

    convert = subcommands.add_parser("convert")
    convert.add_argument("--trace-root", type=Path, required=True)
    convert.add_argument("--runtime-template-root", type=Path, required=True)
    convert.add_argument("--expected-delta-sha256", required=True)
    convert.add_argument("--output-root", type=Path, required=True)

    convert_heads = subcommands.add_parser("convert-heads")
    convert_heads.add_argument("--trace-root", type=Path, required=True)
    convert_heads.add_argument("--runtime-template-root", type=Path, required=True)
    convert_heads.add_argument("--expected-delta-sha256", required=True)
    convert_heads.add_argument("--output-root", type=Path, required=True)
    convert_heads.add_argument(
        "--compute-precision-profile",
        choices=("fp32", "fp16"),
        default="fp32",
    )
    return result


def main() -> None:
    arguments = parser().parse_args()
    if arguments.command == "trace":
        trace_encoder(arguments)
    elif arguments.command == "convert":
        convert_encoder(arguments)
    elif arguments.command == "trace-heads":
        trace_runtime_heads(arguments)
    else:
        convert_runtime_heads(arguments)


if __name__ == "__main__":
    main()
