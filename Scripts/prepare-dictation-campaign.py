#!/usr/bin/env python3
"""Freeze a private AI-labelled diagnostic and reserve genuinely unused sessions.

Reads captures without modifying them. No inference or network requests. Historical
AI labels with undocumented model revisions stay diagnostic-only, never human gold.
"""
from __future__ import annotations

import argparse
from collections import Counter
from difflib import SequenceMatcher
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools/benchmarks"))
import dictation_campaign as campaign


POLICY = {
    "mode": "faithful", "referencePolicy": "ai-controlled-campaign-v1",
    "primaryMetric": "final-text micro lexical WER against faithful reference",
    "targetRelativeErrorReduction": 0.20,
    "normalization": "NFC, casefold, straight apostrophes; punctuation ignored except numeric signs/separators; accents, numbers and negations preserved",
    "missingInference": "empty hypothesis; all reference words remain in denominator",
    "failedCorrection": "score the actual deterministic fallback; also count the failure",
    "languageHint": "none", "contextVocabulary": "none",
    "selection": "diagnostic only; reserved control is not runnable until references are independently frozen and a selection is sealed",
    "latencyBudget": "must be fixed from the warm end-of-dictation baseline before selection; currently unset",
    "memoryBudgetBytes": 8 * 1024**3,
    "memoryBudgetMeaning": "provisional process ceiling leaving headroom on the 16 GiB target; confirm combined app footprint",
    "trainingEligible": False, "humanGateSatisfied": False,
    "requiredSafetyChecks": ["no new critical fact alterations", "no changed correct witnesses",
                             "commands and fidelity regressions pass", "failure and truncation counts retained"],
}


def legacy_references(directory: Path, review: dict) -> dict:
    chosen = review.get("chosen", {})
    result = {}
    for field, filename, aliases in (
        ("verbatim", "verbatim.txt", ("verbatim_gold", "verbatim")),
        ("faithful", "faithful.txt", ("faithful_gold", "clean")),
    ):
        path = directory / filename
        if not path.is_file() or not path.read_text().strip():
            raise ValueError("missing_separate_" + field)
        text = path.read_text().strip()
        approved_text = next((chosen[k] for k in aliases if isinstance(chosen.get(k), str)), None)
        if approved_text is None or approved_text.strip() != text:
            raise ValueError("review_file_disagrees_" + field)
        provenance = review.get("provenance", {})
        human = provenance.get("human_reviewed") is True
        result[field] = {
            "text": text,
            "provenance": {
                "kind": "human" if human else "ai-legacy", "humanReviewed": human,
                "historicalTier": provenance.get("tier"), "model": None, "revision": None,
                "promptSHA256": None, "sourceSHA256": campaign.file_digest(directory / "review.json"),
                "referenceFileSHA256": campaign.file_digest(path),
                "candidateParticipation": "historical ensemble may include Parakeet; independence not established",
                "checks": ["historical acceptance", "chosen reference equals stored reference",
                           "separate verbatim and faithful files", "source bytes hashed before inference"],
                "limitations": ["historical model revisions and prompts not fully recorded",
                                "previously exposed diagnostic, not an independent control"],
            },
        }
    return result


def categories(text: str, seconds: float, correct: bool) -> list[str]:
    import re
    result = ["already-correct-lexically" if correct else "not-an-exact-witness"]
    for label, pattern in (
        ("number", r"\d"), ("negation", r"\b(?:pas|jamais|not|never|sans|without)\b"),
        ("hesitation", r"\b(?:euh|heu|um|uh)\b"),
        ("self-correction", r"\b(?:pardon|plutôt|sorry|rather)\b"),
        ("technical", r"\b(?:code|git|api|python|swift|modèle|model|script|commit)\b"),
        ("list-or-command", r"\b(?:liste|list|tiret|bullet|virgule|comma|ligne|line)\b"),
    ):
        if re.search(pattern, text, re.I):
            result.append(label)
    if seconds >= 30:
        result.append("long")
    return result


def personal_items(root: Path) -> tuple[list[dict], dict]:
    historical = set()
    for path in (root / "head-to-head").rglob("manifest*.json"):
        payload = json.loads(path.read_text())
        historical.update(item["id"] for item in payload.get("items", []))
    items = []
    for directory in sorted((root / "sessions").iterdir()):
        if not (directory / "meta.json").is_file() or not (directory / "audio.wav").is_file():
            continue
        meta = json.loads((directory / "meta.json").read_text())
        review_path = directory / "review.json"
        review = json.loads(review_path.read_text()) if review_path.is_file() else {}
        info = campaign.wav_info(directory / "audio.wav")
        # The capture does not retain a reliable parent-session ID. A whole day
        # is a conservative grouping; no invented independence between its takes.
        group = "capture-day:" + str(meta.get("date", directory.name))[:10]
        item = {"id": directory.name, "sourceGroup": group,
                "audioPath": f"sessions/{directory.name}/audio.wav", "audio": info,
                "originalAudio": None, "language": str(meta.get("language") or "unknown"),
                "categories": [], "references": {}, "decision": "excluded", "split": "excluded",
                "reasons": ["reference_not_accepted"], "sourceMetaSHA256": campaign.file_digest(directory / "meta.json")}
        native = directory / "native.wav"
        if native.is_file():
            item["originalAudio"] = {"audioPath": f"sessions/{directory.name}/native.wav",
                                     "audio": campaign.wav_info(native), "evaluated": False}
        if info["sampleRate"] != 16000 or info["channels"] != 1:
            item["reasons"] = ["noncanonical_audio_format"]
        elif review.get("status") == "accepted":
            try:
                item["references"] = legacy_references(directory, review)
                item.update(decision="accepted", split="diagnostic", reasons=["accepted_historical_AI_diagnostic"])
                raw = str(meta.get("rawText") or "")
                faithful = item["references"]["faithful"]["text"]
                item["categories"] = categories(item["references"]["verbatim"]["text"], info["durationSeconds"],
                                                campaign.words(raw) == campaign.words(faithful))
            except ValueError as error:
                item["references"] = {}
                item["reasons"] = [str(error)]
        elif not review and directory.name not in historical:
            item.update(decision="reserved", split="reserved", reasons=["unseen_capture_without_reference"])
        else:
            item["reasons"] = ["historical_" + str(review.get("status", "unverified"))]
        items.append(item)

    seen_audio = {}
    unique = []
    duplicates = Counter()
    # Prefer an accepted reference over a pending duplicate without fabricating a new target.
    for item in sorted(items, key=lambda i: (i["decision"] != "accepted", i["id"])):
        key = campaign.digest({k: item["audio"][k] for k in
                               ("sampleDataSHA256", "sampleRate", "channels", "bitsPerSample", "encoding")})
        if key in seen_audio:
            item.update(decision="excluded", split="excluded", reasons=["exact_audio_duplicate:" + seen_audio[key]])
            duplicates["exactAudio"] += 1
        else:
            seen_audio[key] = item["id"]
        if item["decision"] == "accepted":
            tokens = campaign.words(item["references"]["verbatim"]["text"])
            duplicate = next((other for other, other_tokens in unique
                              if tokens == other_tokens or (min(len(tokens), len(other_tokens)) >= 8
                              and SequenceMatcher(None, tokens, other_tokens, autojunk=False).ratio() >= .94)), None)
            if duplicate:
                item.update(decision="excluded", split="excluded", reasons=["near_reference_duplicate:" + duplicate["id"]])
                duplicates["nearText"] += 1
            else:
                unique.append((item, tokens))
    diagnostic_groups = {item["sourceGroup"] for item in items if item["decision"] == "accepted"}
    historical_groups = {item["sourceGroup"] for item in items if item["id"] in historical}
    for item in items:
        if item["decision"] == "reserved" and item["sourceGroup"] in diagnostic_groups | historical_groups:
            item.update(decision="excluded", split="excluded", reasons=["reserve_group_previously_exposed"])
    return items, {"exactAudioDuplicates": duplicates["exactAudio"], "nearTextDuplicates": duplicates["nearText"],
                   "nearAudioLimitation": "No acoustic near-duplicate detector; whole-day grouping protects known session relations. Undocumented cross-day excerpts require review before a final control.",
                   "historicallySeenIDs": len(historical)}


def public_items(source: Path, audio_root: Path, per_language: int) -> tuple[list[dict], dict]:
    payload = json.loads(source.read_text())
    selected, counts = [], Counter()
    for old in sorted(payload["items"], key=lambda item: item["id"]):
        language = old["language"]
        if counts[language] >= per_language:
            continue
        counts[language] += 1
        text = old["reference"]["verbatim"]
        provenance = {"kind": "public", "humanReviewed": False, "dataset": "google/fleurs",
                      "revision": "70bb2e84b976b7e960aa89f1c648e09c59f894dd", "license": "CC-BY-4.0",
                      "sourceSHA256": campaign.file_digest(source),
                      "checks": ["official pinned archive and TSV checksums verified by existing preparer",
                                 "raw_transcription retained; no prediction used to construct reference"],
                      "model": None, "promptSHA256": None}
        selected.append({"id": old["id"], "sourceGroup": old["sessionID"], "split": "public",
                         "audioPath": old["audioPath"], "audio": campaign.wav_info(campaign.safe_audio_path(audio_root, old["audioPath"])),
                         "originalAudio": None, "language": language, "categories": ["public", "read-speech"],
                         "decision": "accepted", "reasons": ["deterministic_ID_sample_not_selected_by_errors"],
                         "references": {field: {"text": text, "provenance": dict(provenance)} for field in ("verbatim", "faithful")}})
    return selected, {"samplePerLanguage": dict(counts), "publicSourceSHA256": campaign.file_digest(source),
                      "limitations": ["read speech, not personal dictation", "not the full official test set",
                                      "unknown speakers; bootstrap groups conservatively use source locale"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("personal", "public"))
    parser.add_argument("--personal-root", type=Path, default=Path.home() / "Library/Application Support/VoxoL/PersonalBenchmark")
    parser.add_argument("--public-manifest", type=Path)
    parser.add_argument("--audio-root", type=Path)
    parser.add_argument("--per-language", type=int, default=20)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.kind == "personal":
        root = args.personal_root
        items, audit = personal_items(root)
    else:
        if not args.public_manifest or not args.audio_root or args.per_language < 1:
            parser.error("Public preparation requires --public-manifest, --audio-root and a positive sample size")
        root = args.audio_root
        items, audit = public_items(args.public_manifest, root, args.per_language)
    manifest = campaign.freeze({"campaignID": args.output.name, "sourceKind": args.kind,
                                "policy": POLICY, "audit": audit, "items": items})
    campaign.validate(manifest, root)
    args.output.mkdir(parents=True, exist_ok=False)
    args.output.chmod(0o700)
    campaign.write_json(args.output / "manifest.json", manifest)
    summary = {"total": len(items), "decisions": dict(Counter(i["decision"] for i in items)),
               "bySplit": dict(Counter(i["split"] for i in items)),
               "byLanguageAccepted": dict(Counter(i["language"] for i in items if i["decision"] == "accepted")),
               "sourceGroupsAccepted": len({i["sourceGroup"] for i in items if i["decision"] == "accepted"}),
               "exclusions": dict(Counter(i["reasons"][0].split(":")[0] for i in items if i["decision"] == "excluded")),
               "manifestSHA256": manifest["manifestSHA256"], "audit": audit,
               "audioRoot": str(root.resolve()), "trainingEligible": False, "promotionAllowed": False}
    campaign.write_json(args.output / "inventory.json", summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
