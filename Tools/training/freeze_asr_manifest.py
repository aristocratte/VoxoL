#!/usr/bin/env python3
"""Freeze a VoxoL ASR manifest using the Swift manifest digest contract."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path


def canonical_bytes(manifest: dict[str, object]) -> bytes:
    canonical = {
        "benchmarkID": manifest["benchmarkID"],
        "frozenAt": manifest["frozenAt"],
        "items": manifest["items"],
        "normalizationVersion": manifest["normalizationVersion"],
        "schemaVersion": manifest["schemaVersion"],
    }
    return json.dumps(
        canonical,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--timestamp",
        help="Explicit ISO-8601 freeze timestamp for a reproducible manifest.",
    )
    arguments = parser.parse_args()
    manifest = json.loads(arguments.input.read_text(encoding="utf-8"))
    if manifest.get("contentSHA256") or manifest.get("frozenAt"):
        raise SystemExit("Input manifest is already frozen.")
    manifest["frozenAt"] = arguments.timestamp or (
        datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    )
    manifest["contentSHA256"] = hashlib.sha256(canonical_bytes(manifest)).hexdigest()
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(arguments.output)


if __name__ == "__main__":
    main()
