#!/usr/bin/env python3
"""Publish the Core ML ASR runtime and rewrite the manifest that pins it.

`Models/manifests/runtime-models.json` pins the shipped ASR artifact to a
provider repository, a commit revision and a SHA-256 per file. The app verifies
every download against those hashes, so a new runtime cannot ship until it lives
at an immutable revision and the manifest records it.

This does both halves in one pass: upload, read back the commit the upload
created, then rewrite the manifest entry against the files as published.

Usage:
    HF_TOKEN=hf_... ./publish-asr-runtime.py \\
        --runtime-root <nemo-direct-waveform-int8> \\
        --repo-id <user>/<name>

Add `--dry-run` to see what would be uploaded and how the manifest would change
without touching the network.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys


# `.compiled` is a derived Core ML cache the app rebuilds locally; publishing it
# would double the download for no benefit.
EXCLUDED_DIRECTORIES = {".compiled"}
REQUIRED_ENTRIES = (
    "encoder.mlpackage",
    "decoder.mlpackage",
    "joint.mlpackage",
    "tokenizer.json",
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--runtime-root", type=Path, required=True)
    result.add_argument("--repo-id", required=True)
    result.add_argument(
        "--manifest",
        type=Path,
        default=Path("Models/manifests/runtime-models.json"),
    )
    result.add_argument("--readme", type=Path)
    result.add_argument("--private", action="store_true")
    result.add_argument("--dry-run", action="store_true")
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def publishable_files(root: Path) -> list[Path]:
    files = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if EXCLUDED_DIRECTORIES & set(relative.parts):
            continue
        if relative.name == ".DS_Store":
            continue
        files.append(path)
    return files


def verify_runtime(root: Path) -> None:
    missing = [name for name in REQUIRED_ENTRIES if not (root / name).exists()]
    if missing:
        raise SystemExit(f"Runtime is incomplete, missing: {missing}")


def manifest_files(
    root: Path,
    paths: list[Path],
    repo_id: str,
    revision: str,
) -> list[dict[str, object]]:
    entries = []
    for path in paths:
        relative = path.relative_to(root).as_posix()
        if relative == "README.md":
            continue
        entries.append(
            {
                "path": relative,
                "sha256": sha256(path),
                "download_url": (
                    f"https://huggingface.co/{repo_id}/resolve/"
                    f"{revision}/{relative}?download=true"
                ),
                "size_bytes": path.stat().st_size,
            }
        )
    return entries


def rewrite_manifest(
    manifest_path: Path,
    repo_id: str,
    revision: str,
    entries: list[dict[str, object]],
) -> dict[str, object]:
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    models = payload.get("models") or []
    asr = next((model for model in models if model.get("role") == "asr"), None)
    if asr is None:
        raise SystemExit("The manifest has no model with role 'asr'.")
    artifact = asr.setdefault("artifact", {})
    artifact["provider"] = {
        "repository": repo_id,
        "revision": revision,
        "source_url": f"https://huggingface.co/{repo_id}",
    }
    artifact["files"] = entries
    return payload


def main() -> int:
    arguments = parser().parse_args()
    root = arguments.runtime_root.resolve()
    verify_runtime(root)
    paths = publishable_files(root)
    total = sum(path.stat().st_size for path in paths)
    print(f"Runtime: {root}")
    print(f"Files:   {len(paths)}  ({total / 1e6:.1f} MB)")
    for path in paths:
        print(f"  {path.relative_to(root).as_posix()}")

    if arguments.dry_run:
        entries = manifest_files(root, paths, arguments.repo_id, "DRY-RUN")
        print(f"\nManifest would list {len(entries)} files under {arguments.repo_id}.")
        return 0

    token = os.environ.get("HF_TOKEN")
    if not token:
        raise SystemExit("Set HF_TOKEN to a token with repo.write.")

    from huggingface_hub import HfApi

    api = HfApi(token=token)
    api.create_repo(
        repo_id=arguments.repo_id,
        repo_type="model",
        private=arguments.private,
        exist_ok=True,
    )
    if arguments.readme is not None and arguments.readme.is_file():
        api.upload_file(
            path_or_fileobj=str(arguments.readme),
            path_in_repo="README.md",
            repo_id=arguments.repo_id,
            repo_type="model",
        )
    commit = api.upload_folder(
        folder_path=str(root),
        repo_id=arguments.repo_id,
        repo_type="model",
        ignore_patterns=[f"{name}/*" for name in EXCLUDED_DIRECTORIES] + [".DS_Store"],
        commit_message="Publish VoxoL Core ML ASR runtime",
    )
    # Pin the exact commit the upload produced rather than a branch name: a
    # branch moves, and the app verifies hashes against what it downloads.
    revision = getattr(commit, "oid", None) or api.model_info(arguments.repo_id).sha
    print(f"\nPublished at revision {revision}")

    entries = manifest_files(root, paths, arguments.repo_id, revision)
    payload = rewrite_manifest(arguments.manifest, arguments.repo_id, revision, entries)
    arguments.manifest.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"Manifest rewritten: {arguments.manifest} ({len(entries)} files)")
    print("\nRun ./Scripts/verify.sh before shipping.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
