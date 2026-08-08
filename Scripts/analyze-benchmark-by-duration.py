#!/usr/bin/env python3
"""Break the head-to-head down by clip length.

VoxoL wins the corpora made of short utterances and loses the ones made of long
read passages. Two explanations fit that: the model is genuinely worse at read
speech, or it degrades as a clip gets longer — and only the second one is
fixable without retraining, by changing how the decoder windows its input.

This separates them by scoring both systems in duration bands across every
benchmark. If the gap tracks duration inside a single corpus, it is a decoding
problem; if it tracks corpus regardless of duration, it is the model.

Duration comes from the WAV byte count: every benchmark clip was written as
16 kHz mono 16-bit PCM by the same converter, so the size is exact and no
subprocess is needed for nine thousand files.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

BYTES_PER_SECOND = 16_000 * 2
WAV_HEADER_BYTES = 44
BANDS = [(0, 5), (5, 10), (10, 15), (15, 20), (20, 25), (25, 31)]


def duration_of(path: Path) -> float:
    return max(0.0, path.stat().st_size - WAV_HEADER_BYTES) / BYTES_PER_SECOND


def errors(counts: dict) -> int:
    return counts["substitutions"] + counts["deletions"] + counts["insertions"]


def collect(root: Path, systems: tuple[str, ...]) -> list[dict]:
    rows = []
    for directory in sorted((root / "benchmarks").iterdir()):
        if directory.name.startswith("."):
            continue
        manifest = directory / "manifest-numeric-frozen.json"
        if not manifest.is_file():
            continue
        per_system = {}
        for system in systems:
            items = directory / f"{system}-numeric-items.jsonl"
            if not items.exists():
                break
            per_system[system] = {
                json.loads(line)["id"]: json.loads(line)["finalWordErrors"]
                for line in items.read_text(encoding="utf-8").splitlines()
                if line.strip()
            }
        if len(per_system) != len(systems):
            continue

        corpus, _, language = directory.name.rpartition("-")
        for item in json.loads(manifest.read_text())["items"]:
            audio = directory / "audio" / item["audioPath"]
            if not audio.exists():
                continue
            row = {
                "corpus": corpus,
                "language": language,
                "seconds": duration_of(audio),
            }
            for system in systems:
                counts = per_system[system].get(item["id"])
                if counts is None:
                    row = None
                    break
                row[f"{system}_errors"] = errors(counts)
                row[f"{system}_words"] = counts["referenceUnitCount"]
            if row:
                rows.append(row)
    return rows


def band_of(seconds: float) -> str | None:
    for low, high in BANDS:
        if low <= seconds < high:
            return f"{low}-{high}s"
    return None


def table(rows: list[dict], systems: tuple[str, ...], group: str | None = None) -> None:
    keys = sorted({row[group] for row in rows}) if group else [None]
    for key in keys:
        subset = [row for row in rows if group is None or row[group] == key]
        print(f"\n### {key or 'toutes les langues et corpus'}")
        header = "  ".join(f"{system:>9s}" for system in systems)
        print(f"  {'bande':>9s} {'clips':>6s}  {header}   ecart")
        for low, high in BANDS:
            band = [row for row in subset if low <= row["seconds"] < high]
            if len(band) < 25:
                continue
            rates = []
            for system in systems:
                words = sum(row[f"{system}_words"] for row in band)
                errs = sum(row[f"{system}_errors"] for row in band)
                rates.append(100 * errs / words if words else float("nan"))
            cells = "  ".join(f"{rate:8.2f}%" for rate in rates)
            gap = rates[0] - rates[1] if len(rates) > 1 else 0.0
            print(f"  {low:3d}-{high:<5d} {len(band):6d}  {cells}   {gap:+6.2f}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--system", action="append", default=None)
    parser.add_argument("--by", choices=("corpus", "language"), default=None)
    arguments = parser.parse_args()
    systems = tuple(arguments.system or ("voxol", "wispr"))

    rows = collect(arguments.root, systems)
    if not rows:
        raise SystemExit("No comparable per-item scores found.")
    print(f"{len(rows)} clips comparables")
    table(rows, systems)
    if arguments.by:
        table(rows, systems, arguments.by)
    return 0


if __name__ == "__main__":
    sys.exit(main())
