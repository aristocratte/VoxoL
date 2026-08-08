#!/usr/bin/env python3
"""Verified, resumable downloads with automatic generated-cache recovery."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            hasher.update(chunk)
    return hasher.hexdigest()


def validation_error(
    path: Path,
    expected_sha256: str,
    expected_bytes: int | None,
) -> str | None:
    if not path.is_file():
        return "file is missing"
    actual_bytes = path.stat().st_size
    if expected_bytes is not None and actual_bytes != expected_bytes:
        return f"size is {actual_bytes} bytes; expected {expected_bytes}"
    actual_sha256 = digest(path)
    if actual_sha256 != expected_sha256:
        return f"SHA-256 is {actual_sha256}; expected {expected_sha256}"
    return None


def remove_invalid_generated_file(path: Path, reason: str) -> None:
    print(
        f"[dataset-cache] Removing invalid generated file {path}: {reason}",
        file=sys.stderr,
        flush=True,
    )
    path.unlink(missing_ok=True)


def download_verified(
    url: str,
    expected_sha256: str,
    destination: Path,
    expected_bytes: int | None = None,
) -> Path:
    if destination.exists():
        reason = validation_error(destination, expected_sha256, expected_bytes)
        if reason is None:
            print(f"[dataset-cache] Verified {destination}", flush=True)
            return destination
        remove_invalid_generated_file(destination, reason)

    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".partial")
    curl = shutil.which("curl")
    if curl is None:
        raise SystemExit("curl is required to download the datasets.")

    for attempt in range(1, 3):
        if (
            partial.exists()
            and expected_bytes is not None
            and partial.stat().st_size > expected_bytes
        ):
            remove_invalid_generated_file(
                partial,
                f"size exceeds the expected {expected_bytes} bytes",
            )
        print(
            f"[dataset-cache] Downloading {destination.name} "
            f"(attempt {attempt}/2, resume enabled)",
            flush=True,
        )
        try:
            subprocess.run(
                [
                    curl,
                    "--fail",
                    "--location",
                    "--show-error",
                    "--retry",
                    "5",
                    "--retry-delay",
                    "2",
                    "--retry-all-errors",
                    "--connect-timeout",
                    "30",
                    "--continue-at",
                    "-",
                    "--output",
                    str(partial),
                    url,
                ],
                check=True,
            )
        except subprocess.CalledProcessError as error:
            raise SystemExit(
                f"Dataset download failed (curl exit {error.returncode}): {url}\n"
                f"The partial file was kept for resume: {partial}\n"
                "Check the Colab network and free Drive space, then rerun this cell."
            ) from error

        reason = validation_error(partial, expected_sha256, expected_bytes)
        if reason is None:
            os.replace(partial, destination)
            print(f"[dataset-cache] Ready: {destination}", flush=True)
            return destination
        remove_invalid_generated_file(partial, reason)
        if attempt == 1:
            print(
                "[dataset-cache] Retrying once from byte zero.",
                file=sys.stderr,
                flush=True,
            )

    raise SystemExit(
        f"Dataset verification failed twice: {url}\n"
        "The invalid partial file was removed. Rerun the cell or inspect Drive health."
    )
