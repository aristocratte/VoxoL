#!/usr/bin/env python3
"""Measure how the recogniser degrades on this person's real dictations.

The frozen multilingual suites live on an external drive and speak with other
people's voices. This builds a benchmark from what is already on the machine:
the personal-capture sessions, each a real dictation through the real
microphone with a human-corrected reference. Small, but it answers the
question the public suites cannot — how does *this* voice on *this* hardware
survive noise?

The pipeline reuses the existing tools end to end: the cell is written in the
frozen-manifest schema, degraded copies are produced by
`prepare-noise-benchmark.py` (babble at controlled SNR, deterministic), and
scoring goes through `voxol-asr-benchmark` like every other cell. Only
sessions with a corrected reference are included: the manifest validator
requires reviewed references, and a correction is exactly that review.

The number to watch is the degradation curve, not the absolute score: ten
clips of one speaker carry no cross-speaker statistics, and the babble is the
speaker's own voice — the hardest masker there is.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

APPLICATION_SUPPORT = Path.home() / "Library/Application Support/VoxoL"


def run(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(
            f"[FAIL] {' '.join(str(part) for part in command[:3])}…\n"
            f"{result.stderr.strip()[:400]}"
        )
    return result.stdout


def build_cell(sessions_root: Path, cell_root: Path) -> int:
    audio_root = cell_root / "audio"
    audio_root.mkdir(parents=True, exist_ok=True)
    items = []
    for meta_path in sorted(sessions_root.glob("*/meta.json")):
        session = meta_path.parent
        corrected = session / "corrected.txt"
        wav = session / "audio.wav"
        if not corrected.is_file() or not wav.is_file():
            continue
        reference = corrected.read_text(encoding="utf-8").strip()
        if not reference:
            continue
        item_id = session.name
        shutil.copyfile(wav, audio_root / f"{item_id}.wav")
        items.append(
            {
                "id": item_id,
                "audioPath": f"{item_id}.wav",
                "speakerID": "owner",
                "sessionID": item_id,
                "split": "development",
                "language": "french",
                "microphone": "macbook-builtin",
                "environment": "desk",
                "tags": ["personal", "corrected"],
                "reference": {
                    "verbatim": reference,
                    "clean": reference,
                    "criticalSpans": [],
                    "reviewed": True,
                },
            }
        )
    if not items:
        raise SystemExit(
            "Aucune session corrigée avec audio. Dictez, corrigez les "
            "corrected.txt, puis relancez."
        )
    manifest = {
        "schemaVersion": 1,
        "benchmarkID": "voxol-perso-mac-fr",
        "normalizationVersion": "voxol-asr-normalizer-v1",
        "items": items,
    }
    unfrozen = cell_root / "manifest-unfrozen.json"
    unfrozen.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return len(items)


def score_cell(cli: Path, cell: Path, model_root: Path, results_root: Path, name: str):
    predictions = results_root / f"{name}-predictions.jsonl"
    scores = results_root / f"{name}-scores.json"
    if predictions.exists():
        predictions.unlink()
    run(
        [
            str(cli),
            "run-parakeet",
            "--manifest",
            str(cell / "manifest-frozen.json"),
            "--audio-root",
            str(cell / "audio"),
            "--model-root",
            str(model_root),
            "--output",
            str(predictions),
        ]
    )
    run(
        [
            str(cli),
            "score",
            "--manifest",
            str(cell / "manifest-frozen.json"),
            "--predictions",
            str(predictions),
            "--output",
            str(scores),
        ]
    )
    return json.loads(scores.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sessions-root",
        type=Path,
        default=APPLICATION_SUPPORT / "PersonalBenchmark/sessions",
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=APPLICATION_SUPPORT / "Benchmarks/Personal",
    )
    parser.add_argument(
        "--model-root",
        type=Path,
        default=APPLICATION_SUPPORT / "Models/asr/7c35754d166cca382ad1e53e68b01e7c575f3a1d",
    )
    parser.add_argument("--cli", type=Path, default=Path(".build/release/voxol-asr-benchmark"))
    parser.add_argument("--snr", action="append", type=int, default=None)
    arguments = parser.parse_args()
    ratios = arguments.snr or [20, 10, 5]

    cell_name = "perso-mac-fr"
    source_root = arguments.output_root / "clean"
    noise_root = arguments.output_root / "noise"
    cell = source_root / "benchmarks" / cell_name

    count = build_cell(arguments.sessions_root, cell)
    print(f"[cell] {count} clips corrigés")
    run(
        [
            str(arguments.cli),
            "freeze",
            "--manifest",
            str(cell / "manifest-unfrozen.json"),
            "--audio-root",
            str(cell / "audio"),
            "--output",
            str(cell / "manifest-frozen.json"),
        ]
    )

    script_directory = Path(__file__).resolve().parent
    run(
        [
            sys.executable,
            str(script_directory / "prepare-noise-benchmark.py"),
            "--source-root",
            str(source_root),
            "--output-root",
            str(noise_root),
            "--cell",
            cell_name,
            "--cli",
            str(arguments.cli),
            *[part for ratio in ratios for part in ("--snr", str(ratio))],
        ]
    )

    results_root = arguments.output_root / "results"
    results_root.mkdir(parents=True, exist_ok=True)
    rows = [("propre", score_cell(arguments.cli, cell, arguments.model_root, results_root, "clean"))]
    for ratio in ratios:
        degraded = noise_root / "benchmarks" / f"{cell_name}-babble{ratio}db"
        rows.append(
            (
                f"babble {ratio} dB",
                score_cell(
                    arguments.cli,
                    degraded,
                    arguments.model_root,
                    results_root,
                    f"babble{ratio}db",
                ),
            )
        )

    print("\ncondition        WER macro    Δ propre   exact")
    baseline = None
    for label, payload in rows:
        aggregate = payload.get("finalClean", {})
        wer = aggregate.get("macroWER")
        exact = aggregate.get("exactMatchRate")
        if baseline is None and wer is not None:
            baseline = wer
        delta = (
            f"+{(wer - baseline) * 100:5.1f} pts"
            if wer is not None and baseline is not None and wer != baseline
            else "        —"
        )
        wer_text = f"{wer * 100:5.1f} %" if wer is not None else "  n/a"
        exact_text = f"{exact * 100:4.0f} %" if exact is not None else " n/a"
        print(f"{label:<15s} {wer_text}    {delta}   {exact_text}")
    print(f"\nDétails : {results_root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
