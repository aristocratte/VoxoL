#!/usr/bin/env python3
"""Freeze explicitly AI-curated development data without fabricating human approval."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import unicodedata

ROOT = Path(__file__).resolve().parents[2]
PERSONAL_KEEP = {
    "20260902-132637-e22d72ff", "20260902-135248-da621587",
    "20260902-143744-7f6c9e83", "20260902-144412-43f0c51e",
    "20260902-144638-c8073119", "20260902-144950-03818711",
    "20260902-150321-a94ca3e8", "20260902-150614-8d14ce9a",
    "20260902-151835-5492622e", "20260902-152711-4fc217ed",
    "20260902-152732-3b6fcd0d", "20260902-153125-f9b67e34",
    "20260902-163911-9f1adf4d", "20260902-163915-1b5b6797",
    "20260902-231355-34f5aed5", "20260902-231945-914e7901",
    "20260902-232818-3489fa17", "20260902-233023-991552c1",
    "20260902-233315-ff2328eb", "20260902-233615-d1f0e624",
    "20260902-234608-3fcdc41b", "20260902-234614-83833ad0",
    "20260903-010925-6a16d7a1", "20260903-011056-0027b0ba",
    "20260903-161953-f15d1bbc", "20260903-172523-0916bf3c",
}
PERSONAL_EDITS = {
    "20260902-144942-030d6370": (
        "première slide en est bon", "première slide, on est bon",
        "Qwen ASR and Whisper both independently emitted 'on est bon'; local grammatical recovery."
    ),
    "20260902-153452-82c5adc3": (
        "idem fait une analyse", "idem, fais une analyse",
        "Imperative agreement with the explicitly addressed second-person recipient."
    ),
    "20260903-173448-e470bf1d": (
        "que tu la revois", "que tu la revoies",
        "Subjunctive required after 'faut vraiment que'; no content change."
    ),
}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def write_rows(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))


def key(text: str) -> str:
    return " ".join(unicodedata.normalize("NFC", text).casefold().split())


def audit(rows: list[dict]) -> dict:
    groups, texts = defaultdict(set), defaultdict(set)
    for r in rows:
        if r["approved"] is not False or r["humanReviewed"] is not False:
            raise ValueError("AI curation must not claim human approval")
        if r["source"] != "ai-curated-experimental":
            raise ValueError("Explicit AI provenance required")
        groups[r["split_group"]].add(r["split"])
        for field in ["raw_transcript", "target_text"]:
            texts[key(r[field])].add(r["split"])
        if not r["raw_transcript"].strip() or not r["target_text"].strip():
            raise ValueError("Empty input or target")
    if any(len(s) > 1 for s in groups.values()):
        raise ValueError("Source group crosses splits")
    if any(len(s) > 1 for s in texts.values()):
        raise ValueError("Exact normalized text crosses splits")
    return {"rows": len(rows), "bySplit": dict(Counter(r["split"] for r in rows)),
            "byOrigin": dict(Counter(r["origin"] for r in rows)),
            "byLanguage": dict(Counter(r["language"] for r in rows)),
            "changedTargets": sum(key(r["raw_transcript"]) != key(r["target_text"]) for r in rows),
            "humanReviewedRows": 0, "crossSplitGroups": 0, "crossSplitExactTexts": 0}


def row(identifier: str, language: str, category: str, raw: str, target: str,
        split: str, group: str, origin: str, reason: str) -> dict:
    return {"id": identifier, "language": language, "profile": "document",
            "app_category": "document", "raw_transcript": raw, "target_text": target,
            "source": "ai-curated-experimental", "approved": False, "humanReviewed": False,
            "curation": {"agent": "Codex", "method": "explicit-target-review",
                         "date": "2026-09-11", "reason": reason},
            "split": split, "split_group": group, "mode": "faithful",
            "category": category, "origin": origin, "operations": [category],
            "dictionary": [], "protected_tokens": [], "before_cursor": "", "after_cursor": ""}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--builder", type=Path, default=ROOT / ".build/debug/voxol-dataset-builder")
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    tsv = ROOT / "Data/corpus/faithful-ai-experiment-v1.tsv"
    inputs = [tsv, Path(__file__)]
    rows = []
    with tsv.open() as stream:
        for n, r in enumerate(csv.DictReader(stream, delimiter="\t"), 1):
            identifier = f"ai-text-{n:03}"
            rows.append(row(identifier, r["language"], r["category"], r["input"], r["target"],
                            r["split"], identifier, "synthetic-text",
                            "AI-authored grammar/spelling or preservation example. Not an audio transcript."))

    manifest = Path.home() / "Library/Application Support/VoxoL/PersonalBenchmark/campaigns/precision-20260908-v1/manifest.json"
    prediction = ROOT / "outputs/self-quality-2026-09-08/processor-installed/predictions.jsonl"
    inputs += [manifest, prediction]
    source_manifest = json.loads(manifest.read_text())
    eligible = {r["id"]: r for r in source_manifest["items"] if r["decision"] == "accepted"}
    reserved = [r["id"] for r in source_manifest["items"] if r["decision"] == "reserved"]
    exclusions = []
    for item in map(json.loads, prediction.read_text().splitlines()):
        identifier = item["id"]
        if identifier not in PERSONAL_KEEP and identifier not in PERSONAL_EDITS:
            exclusions.append({"id": identifier, "reason": "Not curated in cycle 1; ambiguous, long or outside bounded initial selection."})
            continue
        src = eligible[identifier]
        raw = item["transcript"] if "transcript" in item else item.get("raw", item["normalized"])
        # Reuse the recorded ASR input, not a historical rewritten reference.
        raw = item["normalized"]
        target = raw
        reason = "AI text review: grammatical spoken wording retained; no claim of an independently verified verbatim."
        category = "preserve"
        if identifier in PERSONAL_EDITS:
            old, new, reason = PERSONAL_EDITS[identifier]
            if raw.count(old) != 1:
                raise ValueError(f"Source drift: {identifier}")
            target = raw.replace(old, new)
            category = "grammar"
        split = "validation" if src["sourceGroup"] == "capture-day:2026-09-03" else "train"
        r = row("personal-" + identifier, "fr", category, raw, target, split,
                src["sourceGroup"], "personal-asr-text", reason)
        r.update(sourceAudioSHA256=src["audio"]["sha256"], sourceID=identifier,
                 sourceAudioPath=src["audioPath"], originalReferenceUsed=False,
                 inputStage="deterministic-normalized", acousticVerbatimVerified=False)
        rows.append(r)
    report = audit(rows)
    source = args.output / "source.jsonl"
    write_rows(source, rows)
    write_json(args.output / "exclusions.json", exclusions)
    # Kept as identifiers only: their audio and target contents are not read by this preparation.
    write_json(args.output / "reserved-control-ids.json", reserved)
    for split in ["train", "validation"]:
        suite = {"purpose": "AI-labeled development comparison; not an independent final benchmark.",
                 "cases": [{"id": r["id"], "source": r["source"], "humanReviewed": False,
                            "category": r["category"], "language": r["language"], "mode": "faithful",
                            "profile": r["profile"], "transcript": r["raw_transcript"],
                            "expected": r["target_text"], "sourceGroup": r["split_group"]}
                           for r in rows if r["split"] == split]}
        write_json(args.output / f"{split}-suite.json", suite)
    subprocess.run([str(args.builder.resolve()), "--ai-experiment", "--input", str(source),
                    "--output", str(args.output / "mlx")], check=True)
    summary = json.loads((args.output / "mlx/summary.json").read_text())
    if summary.get("review_policy") != "ai-curated-experimental":
        raise ValueError("Builder does not support explicit AI provenance")
    report["builder"] = summary
    report["excludedPersonalRows"] = len(exclusions)
    report["reservedControlCount"] = len(reserved)
    report["limitations"] = ["Synthetic grammar cases are AI-authored and share grammar families across development splits.",
                            "Personal inputs are previously observed diagnostic data, not a new independent test.",
                            "No video or newly verified acoustic transcript is claimed in this initial corpus."]
    report["inputSHA256"] = {str(p): sha(p) for p in inputs}
    report["builderSHA256"] = sha(args.builder)
    report["files"] = {str(p.relative_to(args.output)): sha(p) for p in args.output.rglob("*") if p.is_file()}
    write_json(args.output / "manifest.json", report)
    print(json.dumps({k: v for k, v in report.items() if k not in ["files", "inputSHA256", "limitations"]}))


if __name__ == "__main__":
    main()
