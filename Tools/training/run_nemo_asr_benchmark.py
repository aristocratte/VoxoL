#!/usr/bin/env python3
"""Run a NeMo checkpoint or a VoxoL trainable delta on a frozen benchmark."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import time


MODEL_ID = "nvidia/parakeet-tdt-0.6b-v3"
MODEL_REVISION = "7c35754d166cca382ad1e53e68b01e7c575f3a1d"
MODEL_FILENAME = "parakeet-tdt-0.6b-v3.nemo"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_jsonl(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    source = path.read_text(encoding="utf-8")
    lines = source.splitlines()
    rows = []
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            is_trailing_partial = line_number == len(lines) and not source.endswith(
                "\n"
            )
            if not is_trailing_partial:
                raise
            recovered = "\n".join(lines[:-1])
            path.write_text(
                recovered + ("\n" if recovered else ""),
                encoding="utf-8",
            )
            print(
                f"Removed an incomplete trailing prediction from {path}.",
                flush=True,
            )
    return rows


def text_of(result: object) -> str:
    if isinstance(result, str):
        return result.strip()
    text = getattr(result, "text", None)
    if isinstance(text, str):
        return text.strip()
    raise TypeError(f"Unsupported NeMo transcription result: {type(result).__name__}")


def apply_trainable_delta(
    model: object,
    delta_path: Path,
    torch: object,
    *,
    base_artifact_sha256: str | None = None,
) -> dict[str, object]:
    payload = torch.load(delta_path, map_location="cpu", weights_only=True)
    if not isinstance(payload, dict) or payload.get("schemaVersion") not in (1, 2):
        raise SystemExit("Unsupported VoxoL trainable delta.")
    if payload.get("baseModel") != MODEL_ID:
        raise SystemExit(
            f"Delta base model mismatch: expected {MODEL_ID}, "
            f"got {payload.get('baseModel')}."
        )
    schema_version = int(payload["schemaVersion"])
    state_key = "stateDict" if schema_version == 1 else "stateDelta"
    state_dict = payload.get(state_key)
    if not isinstance(state_dict, dict) or not state_dict:
        raise SystemExit("The VoxoL trainable delta contains no tensors.")
    if schema_version == 2:
        if payload.get("artifactType") != "voxol-parameter-delta":
            raise SystemExit("Unsupported VoxoL parameter-delta type.")
        if payload.get("baseRevision") != MODEL_REVISION:
            raise SystemExit("The VoxoL delta uses a different base revision.")
        expected_base_digest = str(payload.get("baseArtifactSHA256", ""))
        if (
            base_artifact_sha256 is None
            or expected_base_digest != base_artifact_sha256
        ):
            raise SystemExit("The VoxoL delta uses a different base artifact.")
    model_state = model.state_dict()
    unexpected = sorted(set(state_dict) - set(model_state))
    if unexpected:
        raise SystemExit(f"Delta contains an unknown tensor: {unexpected[0]}")
    with torch.no_grad():
        for name, source in state_dict.items():
            destination = model_state[name]
            if tuple(source.shape) != tuple(destination.shape):
                raise SystemExit(f"Delta tensor shape mismatch: {name}")
            update = source.to(
                device=destination.device,
                dtype=destination.dtype,
            )
            if schema_version == 1:
                destination.copy_(update)
            else:
                destination.add_(update)
    return payload


def load_pinned_model(
    nemo_asr: object,
    map_location: str,
) -> tuple[object, str]:
    from huggingface_hub import hf_hub_download

    artifact = Path(
        hf_hub_download(
            repo_id=MODEL_ID,
            filename=MODEL_FILENAME,
            revision=MODEL_REVISION,
        )
    )
    model = nemo_asr.models.ASRModel.restore_from(
        restore_path=str(artifact),
        map_location=map_location,
    )
    return model, sha256(artifact)


def main() -> None:
    parser = argparse.ArgumentParser()
    model_group = parser.add_mutually_exclusive_group(required=True)
    model_group.add_argument("--model", type=Path)
    model_group.add_argument("--delta", type=Path)
    model_group.add_argument("--pretrained-name")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--audio-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--resume", action="store_true")
    arguments = parser.parse_args()
    if arguments.batch_size < 1:
        raise SystemExit("--batch-size must be positive.")

    import torch
    import nemo.collections.asr as nemo_asr

    if not torch.cuda.is_available():
        raise SystemExit("This evaluator requires an NVIDIA CUDA GPU.")
    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    if not manifest.get("contentSHA256") or not manifest.get("frozenAt"):
        raise SystemExit("The VoxoL benchmark manifest must be frozen.")
    items = list(manifest["items"])
    existing = read_jsonl(arguments.output) if arguments.resume else []
    completed = {str(row["id"]) for row in existing}
    pending = [item for item in items if str(item["id"]) not in completed]

    if arguments.delta is not None:
        model, base_digest = load_pinned_model(
            nemo_asr,
            "cuda",
        )
        delta_metadata = apply_trainable_delta(
            model,
            arguments.delta,
            torch,
            base_artifact_sha256=base_digest,
        )
        model_identity = (
            f"{MODEL_ID}+{arguments.delta}" f"@epoch-{delta_metadata['epoch']}"
        )
    elif arguments.model is not None:
        model = nemo_asr.models.ASRModel.restore_from(
            restore_path=str(arguments.model),
            map_location="cuda",
        )
        model_identity = str(arguments.model)
    else:
        if str(arguments.pretrained_name) == MODEL_ID:
            model, base_digest = load_pinned_model(nemo_asr, "cuda")
            model_identity = f"{MODEL_ID}@{MODEL_REVISION}:{base_digest[:12]}"
        else:
            model = nemo_asr.models.ASRModel.from_pretrained(
                model_name=str(arguments.pretrained_name),
                map_location="cuda",
            )
            model_identity = str(arguments.pretrained_name)
    model = model.cuda().eval()
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    mode = "a" if arguments.resume else "w"
    with arguments.output.open(mode, encoding="utf-8") as output:
        for offset in range(0, len(pending), arguments.batch_size):
            batch = pending[offset : offset + arguments.batch_size]
            paths = [
                str((arguments.audio_root / str(item["audioPath"])).resolve())
                for item in batch
            ]
            missing = [path for path in paths if not Path(path).is_file()]
            if missing:
                raise SystemExit(f"Missing benchmark audio: {missing[0]}")
            started = time.perf_counter()
            with torch.inference_mode():
                results = model.transcribe(
                    audio=paths,
                    batch_size=len(batch),
                    verbose=False,
                )
            elapsed = time.perf_counter() - started
            for item, result in zip(batch, results, strict=True):
                transcript = text_of(result)
                row = {
                    "id": item["id"],
                    "rawText": transcript,
                    "finalText": transcript,
                    "checkpoint": model_identity,
                    "inferenceMilliseconds": elapsed * 1_000 / len(batch),
                }
                output.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
                output.flush()
            completed_count = min(offset + len(batch), len(pending))
            print(
                f"[{completed_count}/{len(pending)}] "
                f"{elapsed * 1_000 / len(batch):.1f} ms/item",
                flush=True,
            )


if __name__ == "__main__":
    main()
