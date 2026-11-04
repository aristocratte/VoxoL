#!/usr/bin/env python3
"""Turn captured dictations into a scored personal benchmark, in one command.

Every public corpus in the suite measures someone else's voice reading someone
else's text. The only number that predicts this product's quality for its owner
is the owner's own dictation scored against the text they actually wanted —
including the numbers, the punctuation and the technical vocabulary the public
scorers normalise away or never contain.

The app's "Personal benchmark capture" setting stores each dictation as a
session directory with audio, metadata and four review references. The
faithful reference is used for the clean benchmark; legacy `corrected.txt`
files remain supported.

This builds a frozen benchmark from the sessions and scores what the app
actually inserted against the corrected references. With `--rerun-asr` it also
replays the audio through the current model, so a decoder change (vocabulary
boost weights, a new delta) is measurable on the owner's real speech before it
ships.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

LANGUAGES = {"fr": "french", "en": "english"}
CRITICAL_PATTERNS = (
    ("url", re.compile(r"https?://\S+", re.IGNORECASE)),
    ("email", re.compile(r"\b\S+@\S+\.\S+\b")),
    ("path", re.compile(r"(?<!\w)(?:~?/|/)[\w./~-]+")),
    ("command", re.compile(r"(?<!\w)--?[A-Za-z][\w-]*")),
    ("number", re.compile(r"(?<!\w)\d[\d.,:/%-]*(?!\w)")),
    (
        "code",
        re.compile(
            r"\b(?:[A-Z]{2,}[A-Za-z0-9]*|[a-z]+[A-Z][A-Za-z0-9]*|[A-Z][a-z]+[A-Z0-9][A-Za-z0-9]*)\b"
        ),
    ),
    (
        "negation",
        re.compile(
            r"\b(?:no|not|never|without|ne|pas|jamais|sans|aucun|aucune)\b|\bn['’]",
            re.IGNORECASE,
        ),
    ),
)


def critical_spans(text: str) -> list[dict[str, object]]:
    matches: list[tuple[int, int, str, str]] = []
    for kind, pattern in CRITICAL_PATTERNS:
        for match in pattern.finditer(text):
            expected = match.group(0).rstrip(".,;:!?")
            matches.append((match.start(), match.start() + len(expected), kind, expected))
    result = []
    occupied: list[tuple[int, int]] = []
    for start, end, kind, expected in sorted(matches, key=lambda item: (item[0], -(item[1] - item[0]))):
        if not expected or any(start < used_end and end > used_start for used_start, used_end in occupied):
            continue
        occupied.append((start, end))
        result.append({"kind": kind, "expected": expected, "acceptedAlternatives": []})
    return result


def sessions_in(root: Path) -> list[dict]:
    result = []
    for directory in sorted((root / "sessions").glob("*")):
        meta_path = directory / "meta.json"
        audio = directory / "audio.wav"
        corrected = directory / "corrected.txt"
        faithful = directory / "faithful.txt"
        if not (meta_path.is_file() and audio.is_file()):
            continue
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        reference_path = faithful if faithful.is_file() else corrected
        reference = (
            reference_path.read_text(encoding="utf-8").strip()
            if reference_path.is_file() else ""
        )
        if not reference:
            continue
        verbatim_path = directory / "verbatim.txt"
        verbatim_reference = (
            verbatim_path.read_text(encoding="utf-8").strip()
            if verbatim_path.is_file()
            else ""
        )
        review_path = directory / "review.json"
        review = (
            json.loads(review_path.read_text(encoding="utf-8"))
            if review_path.is_file()
            else {}
        )
        accepted = review.get("status") == "accepted" and bool(verbatim_reference)
        provenance = review.get("provenance", {})
        reference_tier = (
            str(provenance.get("tier", "ensemble-candidate"))
            if accepted
            else "unverified-capture"
        )
        result.append(
            {
                "name": directory.name,
                "meta": meta,
                "reference": reference,
                "verbatim_reference": verbatim_reference,
                "clean_reference": reference,
                "reference_tier": reference_tier,
                "reference_ready": accepted,
                "human_reviewed": provenance.get("human_reviewed") is True
                if accepted
                else False,
                "audioPath": f"sessions/{directory.name}/audio.wav",
            }
        )
    return result


def manifest_for(sessions: list[dict]) -> dict:
    items = []
    for session in sessions:
        meta = session["meta"]
        items.append(
            {
                "id": session["name"],
                "audioPath": session["audioPath"],
                "speakerID": "owner",
                "sessionID": session["name"].split("-")[0],
                "split": "blind",
                "language": LANGUAGES.get(meta.get("language", ""), "mixed"),
                "microphone": "owner-microphone",
                "environment": "owner-environment",
                "tags": [
                    "personal",
                    str(meta.get("engine", "unknown")),
                    f"reference-{session['reference_tier']}",
                ],
                "reference": {
                    "verbatim": session["verbatim_reference"],
                    "clean": session["clean_reference"],
                    "criticalSpans": critical_spans(session["clean_reference"]),
                    "reviewed": session["reference_ready"],
                },
            }
        )
    return {
        "schemaVersion": 1,
        "benchmarkID": "voxol-personal",
        "normalizationVersion": "voxol-asr-normalizer-v1",
        "items": items,
    }


def wer_of(report: Path, stage: str = "finalClean") -> float:
    counts = json.loads(report.read_text())[stage]["wordErrors"]
    total = counts["substitutions"] + counts["deletions"] + counts["insertions"]
    return 100 * total / max(counts["referenceUnitCount"], 1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.home()
        / "Library/Application Support/VoxoL/PersonalBenchmark",
    )
    parser.add_argument(
        "--cli",
        type=Path,
        default=Path(__file__).resolve().parent.parent
        / ".build/release/voxol-asr-benchmark",
    )
    parser.add_argument(
        "--model-root",
        type=Path,
        default=Path.home()
        / "Library/Application Support/VoxoL/Models/asr"
        / "7c35754d166cca382ad1e53e68b01e7c575f3a1d",
    )
    parser.add_argument(
        "--rerun-asr",
        action="store_true",
        help="Also replay the audio through the current model, to measure a "
        "decoder or model change on the owner's real speech.",
    )
    arguments = parser.parse_args()

    captured = sessions_in(arguments.root)
    sessions = [session for session in captured if session["reference_ready"]]
    if len(captured) != len(sessions):
        print(f"Excluded {len(captured) - len(sessions)} sessions without accepted, separate references.")
    if not sessions:
        print(
            "Aucune session avec deux références acceptées.\n"
            "Active « Personal benchmark capture » dans les réglages, dicte "
            "normalement, révise les références dans Training Studio, puis relance."
        )
        return 0

    build = arguments.root / "build"
    shutil.rmtree(build, ignore_errors=True)
    build.mkdir(parents=True)

    unfrozen = build / "manifest-unfrozen.json"
    unfrozen.write_text(
        json.dumps(manifest_for(sessions), ensure_ascii=False, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    frozen = build / "manifest-frozen.json"
    subprocess.run(
        [
            str(arguments.cli),
            "freeze",
            "--manifest",
            str(unfrozen),
            "--audio-root",
            str(arguments.root),
            "--output",
            str(frozen),
        ],
        check=True,
        capture_output=True,
    )

    # What the app inserted, straight from the capture: scoring it needs no
    # model and answers "what did the owner actually experience".
    predictions = build / "product-predictions.jsonl"
    predictions.write_text(
        "".join(
            json.dumps(
                {
                    "id": session["name"],
                    "rawText": session["meta"].get("rawText", ""),
                    "finalText": session["meta"].get("finalText", ""),
                },
                ensure_ascii=False,
                sort_keys=True,
            )
            + "\n"
            for session in sessions
        ),
        encoding="utf-8",
    )
    report = build / "product-report.json"
    subprocess.run(
        [
            str(arguments.cli),
            "score",
            "--manifest",
            str(frozen),
            "--predictions",
            str(predictions),
            "--output",
            str(report),
            "--per-item",
            str(build / "product-items.jsonl"),
        ],
        check=True,
        capture_output=True,
    )

    corrected = sum(
        1
        for session in sessions
        if session["reference"] != session["meta"].get("finalText", "").strip()
    )
    print(f"{len(sessions)} sessions, dont {corrected} corrigées")
    print(f"WER produit (ce qui a été inséré) : {wer_of(report):.2f}%")

    per_item = [
        json.loads(line)
        for line in (build / "product-items.jsonl").read_text().splitlines()
        if line.strip()
    ]
    worst = sorted(
        per_item,
        key=lambda row: -(
            row["finalWordErrors"]["substitutions"]
            + row["finalWordErrors"]["deletions"]
            + row["finalWordErrors"]["insertions"]
        ),
    )[:3]
    for row in worst:
        errors = row["finalWordErrors"]
        total = errors["substitutions"] + errors["deletions"] + errors["insertions"]
        if total:
            print(f"  pire session : {row['id']} ({total} erreurs)")

    if arguments.rerun_asr:
        asr_predictions = build / "asr-predictions.jsonl"
        subprocess.run(
            [
                str(arguments.cli),
                "run-parakeet",
                "--manifest",
                str(frozen),
                "--audio-root",
                str(arguments.root),
                "--model-root",
                str(arguments.model_root),
                "--output",
                str(asr_predictions),
                "--compute-units",
                "all",
            ],
            check=True,
        )
        asr_report = build / "asr-report.json"
        subprocess.run(
            [
                str(arguments.cli),
                "score",
                "--manifest",
                str(frozen),
                "--predictions",
                str(asr_predictions),
                "--output",
                str(asr_report),
            ],
            check=True,
            capture_output=True,
        )
        print(f"WER ASR verbatim (modèle actuel rejoué) : {wer_of(asr_report, 'rawVerbatim'):.2f}%")

    return 0


if __name__ == "__main__":
    sys.exit(main())
