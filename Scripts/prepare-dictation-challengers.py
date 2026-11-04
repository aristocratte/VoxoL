#!/usr/bin/env python3
"""Download only public, pinned experimental ASR weights; never upload recordings."""
from __future__ import annotations

import argparse
from importlib.metadata import version
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools/benchmarks"))
import dictation_campaign as campaign

MODELS = {
    "qwen3-asr-0.6b-8bit": "mlx-community/Qwen3-ASR-0.6B-8bit",
    "qwen3-asr-1.7b-8bit": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "whisper-turbo-fp16": "mlx-community/whisper-large-v3-turbo-asr-fp16",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=sorted(MODELS), action="append")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/precision-asr-models")
    args = parser.parse_args()
    from huggingface_hub import HfApi, snapshot_download
    api = HfApi(token=False)
    args.output.mkdir(parents=True, exist_ok=True)
    for name in args.model or ["qwen3-asr-0.6b-8bit", "whisper-turbo-fp16"]:
        repo = MODELS[name]
        lock_path = args.output / (name + ".lock.json")
        if lock_path.exists():
            import json
            lock = json.loads(lock_path.read_text())
            revision = lock["revision"]
        else:
            revision = api.model_info(repo).sha
            lock = {"repo": repo, "revision": revision, "purpose": "external local benchmark only",
                    "mlxAudioVersion": version("mlx-audio"), "privateDataTransferred": False,
                    "upstreamBaseRevision": "not recorded by the converter; converted revision pinned exactly"}
            campaign.write_json(lock_path, lock)
        print("Downloading pinned public model:", repo, revision, flush=True)
        destination = args.output / name
        snapshot_download(repo, revision=revision, local_dir=destination, token=False, max_workers=2,
                          allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model", "*.jinja", "*.npz",
                                          "*.tiktoken", "README.md", "LICENSE*"])
        files = {str(p.relative_to(destination)): campaign.file_digest(p) for p in sorted(destination.rglob("*"))
                 if p.is_file() and not any(v.startswith(".") for v in p.relative_to(destination).parts)}
        if not any(p.endswith(".safetensors") for p in files):
            raise ValueError("No weights downloaded")
        campaign.write_json(args.output / (name + ".files.json"), {"files": files, "sha256": campaign.digest(files)}, exclusive=False)
        print("Ready:", destination, flush=True)


if __name__ == "__main__":
    main()
