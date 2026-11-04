#!/usr/bin/env python3
"""Build reproducible long-form stress inputs from pinned public FLEURS clips.

Concatenation is not spontaneous dictation. Shared constituent clips remain one
regression group; none of these files is an independent held-out recording.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools/benchmarks"))
import dictation_campaign as campaign


def float_samples(path: Path) -> bytes:
    info = campaign.wav_info(path)
    if (info["sampleRate"], info["channels"], info["encoding"], info["bitsPerSample"]) != (16000, 1, "float", 32):
        raise ValueError("This recipe requires the original Float32 mono 16 kHz copies")
    data = path.read_bytes()
    offset = 12
    parts = []
    while offset + 8 <= len(data):
        tag, size = struct.unpack_from("<4sI", data, offset)
        offset += 8
        if tag == b"data":
            parts.append(data[offset:offset + size])
        offset += size + size % 2
    return b"".join(parts)


def write_float_wav(path: Path, samples: bytes) -> None:
    fmt = struct.pack("<HHIIHH", 3, 1, 16000, 64000, 4, 32)
    body = b"WAVEfmt " + struct.pack("<I", len(fmt)) + fmt
    body += b"data" + struct.pack("<I", len(samples)) + samples
    path.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--audio-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = json.loads(args.manifest.read_text())
    campaign.validate(source, args.audio_root)
    selected = campaign.select(source, "public")
    if len(selected) != 40 or any(i["references"]["verbatim"]["provenance"]["kind"] != "public" for i in selected):
        raise ValueError("The preregistered cohort is exactly forty public regression clips")
    by_language = {
        language: sorted([i for i in selected if i["language"] == language], key=lambda i: i["id"])
        for language in ("french", "english")
    }
    if any(len(items) != 20 for items in by_language.values()):
        raise ValueError("Expected twenty clips per language")
    recipes = []
    for language, items in by_language.items():
        for width in (5, 10, 20):
            for start in range(0, 20, width):
                recipes.append((f"{language}-{width}-{start}", language, items[start:start + width]))
    mixed = [item for pair in zip(by_language["french"], by_language["english"]) for item in pair]
    recipes.extend((f"mixed-20-{start}", "mixed", mixed[start:start + 20]) for start in (0, 20))
    args.output.mkdir(parents=True, exist_ok=False)
    audio_root = args.output / "audio"
    audio_root.mkdir()
    items = []
    for name, language, constituents in recipes:
        gap_frames = 4000  # Fixed 250 ms; never chosen using a prediction.
        data = bytes(gap_frames * 4).join(
            float_samples(campaign.safe_audio_path(args.audio_root, item["audioPath"]))
            for item in constituents
        )
        path = audio_root / (name + ".wav")
        write_float_wav(path, data)
        text = " ".join(i["references"]["verbatim"]["text"] for i in constituents)
        provenance = dict(constituents[0]["references"]["verbatim"]["provenance"])
        provenance.update(
            sourceSHA256=source["manifestSHA256"],
            checks=["Pinned public source bytes verified", "Official references concatenated without model output", "Synthetic joins explicitly identified"],
            construction="ordered concatenation with 250 ms gaps; not a natural long-form recording",
        )
        items.append({
            "id": "fleurs-seam-stress-" + name, "audioPath": path.name,
            "audio": campaign.wav_info(path), "language": language, "split": "public",
            "decision": "accepted", "sourceGroup": "shared-fleurs-regression-40",
            "categories": ["public", "constructed-long-form-stress"],
            "reasons": ["ID-order recipe frozen before either variant is scored"],
            "references": {field: {"text": text, "provenance": provenance} for field in ("verbatim", "faithful")},
            "constituents": [{"id": i["id"], "audioSHA256": i["audio"]["sha256"],
                              "referenceSHA256": i["referenceSHA256"]} for i in constituents],
            "silenceFramesBetweenConstituents": gap_frames,
        })
    frozen = campaign.freeze({
        "campaignID": "launch-seam-stress-v1", "sourceKind": "constructed-public-regression",
        "policy": {"trainingAllowed": False, "promotionAutomatic": False, "independentAudioSources": 40},
        "audit": {"sourceManifestSHA256": source["manifestSHA256"],
                  "recipeSHA256": campaign.file_digest(Path(__file__)),
                  "limitations": ["Shared clips, not sixteen independent speakers", "Artificial recording and language joins", "Exposed public regression, not a blind test"]},
        "items": items,
    })
    campaign.write_json(args.output / "manifest.json", frozen)
    print(json.dumps({"composites": len(items), "uniqueSourceClips": 40,
                      "durationSeconds": sum(i["audio"]["durationSeconds"] for i in items),
                      "manifestSHA256": frozen["manifestSHA256"]}, indent=2))


if __name__ == "__main__":
    main()
