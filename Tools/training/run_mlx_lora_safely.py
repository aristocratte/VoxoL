#!/usr/bin/env python3
"""Run MLX LM LoRA with a hard allocator ceiling so macOS stays responsive."""

from __future__ import annotations

import argparse
import os
import sys

import mlx.core as mx


def main() -> None:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--memory-gb", type=float, required=True)
    parser.add_argument("--cache-mb", type=float, default=512)
    arguments, remaining = parser.parse_known_args()
    if arguments.memory_gb <= 0 or arguments.cache_mb <= 0:
        raise SystemExit("Memory and cache limits must be positive")

    memory_bytes = int(arguments.memory_gb * 1024**3)
    cache_bytes = int(arguments.cache_mb * 1024**2)
    mx.set_memory_limit(memory_bytes)
    mx.set_cache_limit(cache_bytes)
    os.environ["TOKENIZERS_PARALLELISM"] = "false"

    from mlx_lm import lora

    sys.argv = ["mlx_lm.lora", *remaining]
    print(
        f"MLX safety limits: allocator={arguments.memory_gb:g} GiB, "
        f"cache={arguments.cache_mb:g} MiB",
        flush=True,
    )
    lora.main()


if __name__ == "__main__":
    main()
