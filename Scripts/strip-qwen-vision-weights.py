#!/usr/bin/env python3
"""Build a text-only Qwen 3.5 MLX artifact without changing language weights."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

from safetensors import safe_open
from safetensors.torch import load_file, save_file


VISION_PREFIXES = ("vision_tower", "model.visual")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    source = arguments.source.resolve()
    destination = arguments.destination.resolve()
    source_weights = source / "model.safetensors"
    source_index = source / "model.safetensors.index.json"

    if not source_weights.is_file() or not source_index.is_file():
        raise SystemExit("Source must contain model.safetensors and its index.")
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"Destination is not empty: {destination}")

    destination.mkdir(parents=True, exist_ok=True)
    for path in source.iterdir():
        if path.name not in {"model.safetensors", "model.safetensors.index.json"}:
            shutil.copy2(path, destination / path.name)

    with safe_open(source_weights, framework="pt", device="cpu") as handle:
        metadata = handle.metadata()
    weights = load_file(source_weights, device="cpu")
    text_weights = {
        key: tensor
        for key, tensor in weights.items()
        if not key.startswith(VISION_PREFIXES)
    }
    removed_keys = sorted(set(weights) - set(text_weights))
    if not removed_keys:
        raise SystemExit("No vision weights were found; refusing to create an identical copy.")

    destination_weights = destination / source_weights.name
    save_file(text_weights, destination_weights, metadata=metadata)

    index = json.loads(source_index.read_text())
    index["weight_map"] = {
        key: source_weights.name
        for key in sorted(text_weights)
    }
    index.setdefault("metadata", {})["total_size"] = sum(
        tensor.numel() * tensor.element_size()
        for tensor in text_weights.values()
    )
    (destination / source_index.name).write_text(
        json.dumps(index, indent=2, sort_keys=True) + "\n"
    )

    print(
        json.dumps(
            {
                "source_keys": len(weights),
                "text_keys": len(text_weights),
                "removed_vision_keys": len(removed_keys),
                "source_bytes": source_weights.stat().st_size,
                "destination_bytes": destination_weights.stat().st_size,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
