#!/usr/bin/env python3
"""Degrade frozen benchmark cells with babble noise at controlled SNR.

Dictation happens over a coffee machine, a colleague's call, an open-plan
office — not in the silence every public test set was recorded in. This takes
cells VoxoL already scores on and remixes each clip against babble at a chosen
signal-to-noise ratio, producing new frozen benchmarks whose references are
unchanged. The interesting number is each system's *degradation curve*, not its
absolute score: a system that loses two points at 10 dB is usable in a café,
one that loses ten is not.

The babble is built from other clips of the same cell — overlapping speakers
from the same corpus — rather than from a downloaded noise corpus. That keeps
the suite self-contained and reproducible from the frozen audio alone, and
speech-shaped noise is the hard case for a recogniser anyway: white noise
masks, other voices *compete*.

Determinism: which clips babble a given target, and where each babble track
starts, derive from a hash of the clip id. Rerunning produces byte-identical
audio, so the derived benchmarks freeze with stable content hashes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import wave

import numpy

BABBLE_VOICES = 6


def read_wav(path: Path) -> numpy.ndarray:
    with wave.open(str(path), "rb") as handle:
        assert handle.getnchannels() == 1 and handle.getsampwidth() == 2
        raw = handle.readframes(handle.getnframes())
    return numpy.frombuffer(raw, dtype=numpy.int16).astype(numpy.float64)


def write_wav(path: Path, samples: numpy.ndarray, rate: int = 16_000) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    clipped = numpy.clip(samples, -32768, 32767).astype(numpy.int16)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(clipped.tobytes())


def rms(samples: numpy.ndarray) -> float:
    return float(numpy.sqrt(numpy.mean(numpy.square(samples)))) or 1.0


def babble_for(
    identifier: str,
    length: int,
    pool: list[tuple[str, Path]],
) -> numpy.ndarray:
    """Deterministic babble: which voices, and where each starts."""
    digest = hashlib.sha256(identifier.encode()).digest()
    seed = int.from_bytes(digest[:8], "big")
    generator = numpy.random.default_rng(seed)
    others = [entry for entry in pool if entry[0] != identifier]
    # Smoke runs shrink the pool below the voice count; babble with fewer
    # voices is still babble, and crashing a 5-clip rehearsal helps nobody.
    voices = min(BABBLE_VOICES, len(others))
    picks = generator.choice(len(others), size=voices, replace=False)
    mix = numpy.zeros(length)
    for pick in picks:
        voice = read_wav(others[int(pick)][1])
        if len(voice) < length:
            repeats = length // len(voice) + 1
            voice = numpy.tile(voice, repeats)
        start = int(generator.integers(0, len(voice) - length + 1))
        mix += voice[start : start + length]
    return mix / max(voices, 1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path("/Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual"),
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path("/Volumes/0_Oueillez/VoxoL-Benchmarks-Noise"),
    )
    parser.add_argument(
        "--cell",
        action="append",
        default=None,
        help="Source cells to degrade. Defaults to the three real-speech "
        "cells the site graph is built on.",
    )
    parser.add_argument(
        "--snr",
        action="append",
        type=int,
        default=None,
        help="Signal-to-noise ratios in dB. Default 20, 10, 5.",
    )
    parser.add_argument(
        "--cli",
        type=Path,
        default=Path(".build/release/voxol-asr-benchmark"),
    )
    parser.add_argument("--limit", type=int, help="Clips per cell, for smoke runs.")
    arguments = parser.parse_args()

    cells = arguments.cell or ["commonvoice-fr", "voxpopuli-fr", "librispeech-en"]
    ratios = arguments.snr or [20, 10, 5]

    for cell in cells:
        source = arguments.source_root / "benchmarks" / cell
        manifest = json.loads((source / "manifest-frozen.json").read_text())
        items = manifest["items"]
        if arguments.limit:
            items = items[: arguments.limit]
        pool = [
            (item["id"], source / "audio" / item["audioPath"]) for item in items
        ]

        for ratio in ratios:
            name = f"{cell}-babble{ratio}db"
            destination = arguments.output_root / "benchmarks" / name
            if (destination / "manifest-frozen.json").exists():
                print(f"[skip] {name}")
                continue

            derived = []
            for item in items:
                clean = read_wav(source / "audio" / item["audioPath"])
                noise = babble_for(item["id"], len(clean), pool)
                scale = rms(clean) / (rms(noise) * (10 ** (ratio / 20)))
                mixed = clean + noise * scale
                peak = numpy.max(numpy.abs(mixed))
                if peak > 32767:
                    mixed *= 32767 / peak
                entry = json.loads(json.dumps(item))
                entry["id"] = f"{item['id']}-babble{ratio}db"
                entry["audioPath"] = f"{name}/{entry['id']}.wav"
                entry["tags"] = [*item.get("tags", []), "babble", f"snr-{ratio}db"]
                write_wav(destination / "audio" / entry["audioPath"], mixed)
                derived.append(entry)

            payload = {
                "schemaVersion": manifest["schemaVersion"],
                "benchmarkID": f"voxol-{name}",
                "normalizationVersion": manifest["normalizationVersion"],
                "items": derived,
            }
            unfrozen = destination / "manifest-unfrozen.json"
            unfrozen.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
                + "\n",
                encoding="utf-8",
            )
            frozen = destination / "manifest-frozen.json"
            result = subprocess.run(
                [
                    str(arguments.cli),
                    "freeze",
                    "--manifest",
                    str(unfrozen),
                    "--audio-root",
                    str(destination / "audio"),
                    "--output",
                    str(frozen),
                ],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                shutil.rmtree(destination, ignore_errors=True)
                print(f"[FAIL] freeze {name}: {result.stderr.strip()[:120]}")
                continue
            print(f"[done] {name}: {len(derived)} clips")
    return 0


if __name__ == "__main__":
    sys.exit(main())
