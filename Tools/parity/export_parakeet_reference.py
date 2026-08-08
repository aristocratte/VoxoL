#!/usr/bin/env python3
"""Export a stage-level Parakeet snapshot from the pinned Transformers model."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
import soundfile as sf
import torch
from transformers import AutoProcessor, ParakeetForTDT
from transformers.models.parakeet.generation_parakeet import ParakeetTDTDecoderCache

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "training"))
from export_voxol_coreml_candidate import (  # noqa: E402
    apply_delta,
    sha256 as file_sha256,
    validate_delta_payload,
)


MODEL_INPUT_FRAMES = 3_000


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="nvidia/parakeet-tdt-0.6b-v3")
    parser.add_argument("--revision", required=True)
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument("--delta", type=Path)
    parser.add_argument("--expected-delta-sha256")
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def prepare_output(path: Path) -> None:
    if path.exists() and any(path.iterdir()):
        raise ValueError(f"Parity output directory must be absent or empty: {path}")
    path.mkdir(parents=True, exist_ok=True)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_tensor(path: Path, name: str, values: np.ndarray) -> dict[str, object]:
    values = np.ascontiguousarray(values)
    if values.dtype == np.float32:
        suffix = "f32le"
        values = values.astype("<f4", copy=False)
        scalar_type = "float32"
    elif values.dtype == np.int32:
        suffix = "i32le"
        values = values.astype("<i4", copy=False)
        scalar_type = "int32"
    else:
        raise TypeError(f"Unsupported parity dtype: {values.dtype}")
    filename = f"{name}.{suffix}"
    payload = values.tobytes(order="C")
    (path / filename).write_bytes(payload)
    return {
        "name": name,
        "shape": list(values.shape),
        "scalarType": scalar_type,
        "byteOrder": "little-endian",
        "file": {
            "path": filename,
            "sizeBytes": len(payload),
            "sha256": sha256(payload),
        },
    }


def top_candidates(values: torch.Tensor, count: int = 3) -> list[dict[str, object]]:
    top = torch.topk(values, k=min(count, values.numel()))
    return [
        {"index": int(index), "logit": float(logit)}
        for logit, index in zip(top.values.cpu(), top.indices.cpu(), strict=True)
    ]


@torch.inference_mode()
def greedy_trace(
    model: ParakeetForTDT,
    encoder_hidden: torch.Tensor,
    encoder_mask: torch.Tensor,
) -> tuple[list[int], list[int], list[int], list[dict[str, object]]]:
    blank = model.config.blank_token_id
    duration_values = model.config.durations
    valid_frames = int(encoder_mask.sum())
    cache = ParakeetTDTDecoderCache(model.config)

    tokens: list[int] = []
    frames: list[int] = []
    durations: list[int] = []
    decisions: list[dict[str, object]] = []
    last_token = blank
    decoder_hidden: torch.Tensor | None = None
    frame = 0

    while frame < valid_frames:
        symbols = 0
        advanced = False
        while symbols < model.config.max_symbols_per_step:
            # NeMo commits predictor state only after a lexical emission. The
            # decoder call stores a candidate state in ``cache``; blank
            # decisions reuse its output without advancing the cache again.
            if decoder_hidden is None:
                input_ids = torch.tensor([[last_token]], dtype=torch.long)
                decoder_hidden = model.decoder(input_ids, cache=cache)
            logits = model.joint(
                decoder_hidden_states=decoder_hidden,
                encoder_hidden_states=encoder_hidden[:, frame : frame + 1, :],
            )[0, 0]
            token_logits = logits[: model.config.vocab_size]
            duration_logits = logits[model.config.vocab_size :]
            token_id = int(token_logits.argmax())
            duration_index = int(duration_logits.argmax())
            duration = int(duration_values[duration_index])
            emitted = token_id != blank
            decisions.append(
                {
                    "frameIndex": frame,
                    "selectedTokenID": token_id,
                    "selectedDurationIndex": duration_index,
                    "selectedDurationFrames": duration,
                    "emittedToken": emitted,
                    "tokenTopCandidates": top_candidates(token_logits),
                    "durationTopCandidates": top_candidates(duration_logits),
                }
            )

            if not emitted:
                frame += max(duration, 1)
                advanced = True
                break

            tokens.append(token_id)
            frames.append(frame)
            durations.append(duration)
            last_token = token_id
            decoder_hidden = None
            symbols += 1
            if duration > 0:
                frame += duration
                advanced = True
                break
        if not advanced:
            frame += 1

    return tokens, frames, durations, decisions


@torch.inference_mode()
def main() -> None:
    args = parse_args()
    prepare_output(args.output)
    if (args.delta is None) != (args.expected_delta_sha256 is None):
        raise ValueError("--delta and --expected-delta-sha256 must be supplied together")

    waveform, sample_rate = sf.read(args.audio, dtype="float32", always_2d=False)
    if sample_rate != 16_000 or waveform.ndim != 1:
        raise ValueError("Parity audio must be mono 16 kHz")

    processor = AutoProcessor.from_pretrained(
        args.model,
        revision=args.revision,
        cache_dir=args.cache_dir,
    )
    model = ParakeetForTDT.from_pretrained(
        args.model,
        revision=args.revision,
        cache_dir=args.cache_dir,
        dtype=torch.float32,
    ).eval()
    delta_metadata = None
    if args.delta is not None:
        if file_sha256(args.delta) != args.expected_delta_sha256:
            raise ValueError("The candidate delta SHA-256 does not match the expected digest")
        payload = validate_delta_payload(
            torch.load(args.delta, map_location="cpu", weights_only=True)
        )
        delta_metadata = {
            "path": str(args.delta.resolve()),
            "sha256": args.expected_delta_sha256,
            "application": apply_delta(model, payload, torch),
        }
    inputs = processor(
        waveform,
        sampling_rate=sample_rate,
        return_tensors="pt",
        return_attention_mask=True,
    )
    input_features = inputs.input_features.to(torch.float32)
    attention_mask = inputs.attention_mask.to(torch.int32)
    waveform_tensor = torch.from_numpy(waveform).to(torch.float32).unsqueeze(0)
    preemphasized = torch.cat(
        [
            waveform_tensor[:, :1],
            waveform_tensor[:, 1:]
            - processor.feature_extractor.preemphasis * waveform_tensor[:, :-1],
        ],
        dim=1,
    )
    window = torch.hann_window(
        processor.feature_extractor.win_length,
        periodic=False,
    )
    stft = torch.stft(
        preemphasized,
        processor.feature_extractor.n_fft,
        hop_length=processor.feature_extractor.hop_length,
        win_length=processor.feature_extractor.win_length,
        window=window,
        return_complex=True,
        pad_mode="constant",
    )
    power_spectrogram = torch.view_as_real(stft)
    power_spectrogram = torch.sqrt(power_spectrogram.pow(2).sum(-1)).pow(2)
    power_spectrogram = power_spectrogram.permute(0, 2, 1).to(torch.float32)
    unnormalized_log_mel = processor.feature_extractor._torch_extract_fbank_features(
        preemphasized
    ).to(torch.float32)
    if input_features.shape[1] > MODEL_INPUT_FRAMES:
        raise ValueError("Parity audio exceeds the fixed Core ML encoder window")

    padded_features = torch.zeros(
        (1, MODEL_INPUT_FRAMES, input_features.shape[2]),
        dtype=torch.float32,
    )
    padded_mask = torch.zeros((1, MODEL_INPUT_FRAMES), dtype=torch.int32)
    padded_features[:, : input_features.shape[1], :] = input_features
    padded_mask[:, : attention_mask.shape[1]] = attention_mask

    encoder = model.get_audio_features(
        input_features=padded_features,
        attention_mask=padded_mask,
        output_attention_mask=True,
    )
    encoder_hidden = encoder.pooler_output.to(torch.float32)
    encoder_mask = encoder.attention_mask.to(torch.int32)
    tokens, frames, durations, decisions = greedy_trace(
        model,
        encoder_hidden,
        encoder_mask,
    )
    transcript = processor.tokenizer.decode(tokens, skip_special_tokens=True)

    tensors = [
        write_tensor(
            args.output,
            "audio_samples",
            waveform.astype(np.float32),
        ),
        write_tensor(
            args.output,
            "power_spectrogram",
            power_spectrogram.cpu().numpy().astype(np.float32),
        ),
        write_tensor(
            args.output,
            "unnormalized_log_mel",
            unnormalized_log_mel.cpu().numpy().astype(np.float32),
        ),
        write_tensor(
            args.output,
            "input_features",
            input_features.cpu().numpy().astype(np.float32),
        ),
        write_tensor(
            args.output,
            "attention_mask",
            attention_mask.cpu().numpy().astype(np.int32),
        ),
        write_tensor(
            args.output,
            "encoder_hidden",
            encoder_hidden.cpu().numpy().astype(np.float32),
        ),
        write_tensor(
            args.output,
            "encoder_mask",
            encoder_mask.cpu().numpy().astype(np.int32),
        ),
    ]
    metadata = {
        "schemaVersion": 3,
        "runtime": "transformers-source",
        "computeUnits": "cpu-float32",
        "sampleRate": sample_rate,
        "sampleCount": len(waveform),
        "audioSHA256": sha256(args.audio.read_bytes()),
        "model": args.model,
        "revision": args.revision,
        "delta": delta_metadata,
        "tensors": tensors,
        "transcript": transcript,
        "tokenIDs": tokens,
        "frameIndices": frames,
        "durations": durations,
        "decisions": decisions,
    }
    (args.output / "snapshot.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(args.output)


if __name__ == "__main__":
    main()
