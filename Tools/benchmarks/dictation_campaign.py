"""Portable, content-bound contracts for offline dictation experiments.

No model imports, network access, human approval, or application runtime here.
"""
from __future__ import annotations

from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
import random
import re
import struct
import unicodedata

SCHEMA = "voxol-dictation-campaign-v1"
NORMALIZATION = "nfc-casefold-apostrophes-lexical-v1"
SCORING = "stage-coverage-and-timing-v2"
# Conservative publication guard, not a guarantee of representative groups.
BOOTSTRAP_MINIMUM_GROUPS = 20
TOKEN = re.compile(r"[+\-−]?\d+(?:[.,:/]\d+)*(?:[%€$])?|[^\W\d_]+(?:['\-][^\W\d_]+)*|\w+", re.UNICODE)
NEGATION = re.compile(r"\b(?:pas|jamais|sans|aucun|aucune|not|never|without|no)\b|\bn['’]", re.I)
NUMBER = re.compile(r"(?<!\w)[+\-−]?\d+(?:[.,:/]\d+)*(?:[%€$])?")


def digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                     separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def file_digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path: Path, value: object, *, exclusive: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x" if exclusive else "w", encoding="utf-8") as stream:
        path.chmod(0o600)
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def safe_audio_path(root: Path, relative: str) -> Path:
    path = Path(relative)
    if not relative or path.is_absolute() or ".." in path.parts or relative.startswith("~"):
        raise ValueError("Audio path must be relative and confined to its root")
    resolved = (root / path).resolve(strict=True)
    if not resolved.is_relative_to(root.resolve()):
        raise ValueError("Audio symlink leaves its authorized root")
    return resolved


def wav_info(path: Path) -> dict:
    """Inspect PCM/Float WAV bytes, including the app's Float32 native copies."""
    size = path.stat().st_size
    fmt = None
    audio = hashlib.sha256()
    data_size = 0
    with path.open("rb") as stream:
        header = stream.read(12)
        if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
            raise ValueError("Expected a RIFF/WAVE recording")
        end = struct.unpack("<I", header[4:8])[0] + 8
        if end > size:
            raise ValueError("Truncated WAV recording")
        while stream.tell() + 8 <= end:
            kind, length = struct.unpack("<4sI", stream.read(8))
            start = stream.tell()
            if start + length > end:
                raise ValueError("Truncated WAV chunk")
            if kind == b"fmt ":
                raw = stream.read(min(length, 40))
                if len(raw) < 16:
                    raise ValueError("Incomplete WAV format")
                encoding, channels, rate, byte_rate, alignment, bits = struct.unpack("<HHIIHH", raw[:16])
                if encoding == 65534 and len(raw) >= 40:
                    encoding = struct.unpack("<H", raw[24:26])[0]
                fmt = (encoding, channels, rate, byte_rate, alignment, bits)
            elif kind == b"data":
                data_size += length
                remaining = length
                while remaining:
                    chunk = stream.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        raise ValueError("Truncated audio data")
                    audio.update(chunk)
                    remaining -= len(chunk)
            stream.seek(start + length + (length % 2))
    if fmt is None:
        raise ValueError("Missing WAV format")
    encoding, channels, rate, byte_rate, alignment, bits = fmt
    if (encoding not in (1, 3) or channels < 1 or rate < 1 or bits not in (8, 16, 24, 32, 64)
            or alignment != channels * bits // 8 or byte_rate != rate * alignment
            or not data_size or data_size % alignment):
        raise ValueError("Invalid or unsupported audio format")
    return {"container": "wav", "encoding": "float" if encoding == 3 else "pcm",
            "sampleRate": rate, "channels": channels, "bitsPerSample": bits,
            "frames": data_size // alignment, "durationSeconds": data_size / byte_rate,
            "sampleDataSHA256": audio.hexdigest(), "sha256": file_digest(path)}


def words(text: str) -> list[str]:
    if not isinstance(text, str):
        raise ValueError("Transcripts and references must be strings")
    return TOKEN.findall(unicodedata.normalize("NFC", text).casefold().replace("’", "'"))


def reference_hash(item: dict) -> str:
    return digest(item.get("references", {}))


def seal_item(item: dict) -> dict:
    item = dict(item)
    item.pop("itemSHA256", None)
    item["referenceSHA256"] = reference_hash(item)
    item["itemSHA256"] = digest(item)
    return item


def freeze(manifest: dict) -> dict:
    result = dict(manifest)
    result.pop("manifestSHA256", None)
    result["schemaVersion"] = SCHEMA
    result["normalizationVersion"] = NORMALIZATION
    result["items"] = [seal_item(item) for item in manifest["items"]]
    result["manifestSHA256"] = digest(result)
    validate(result)
    return result


def validate(manifest: dict, audio_root: Path | None = None) -> None:
    payload = {k: v for k, v in manifest.items() if k != "manifestSHA256"}
    if (manifest.get("schemaVersion") != SCHEMA or manifest.get("normalizationVersion") != NORMALIZATION
            or manifest.get("manifestSHA256") != digest(payload)):
        raise ValueError("Frozen campaign changed or uses an unsupported schema")
    if not manifest.get("items"):
        raise ValueError("Empty campaign")
    seen = set()
    group_splits, audio_ids, texts = {}, {}, {}
    for item in manifest["items"]:
        identifier = item.get("id")
        if not identifier or identifier in seen:
            raise ValueError("Duplicate or empty ID")
        seen.add(identifier)
        if item != seal_item(item):
            raise ValueError("Item or reference changed: " + identifier)
        if item.get("decision") not in ("accepted", "reserved", "excluded"):
            raise ValueError("Missing reference decision")
        if not item.get("sourceGroup") or not item.get("split") or not item.get("reasons"):
            raise ValueError("Source group, split, and decision reasons are required")
        if audio_root is not None:
            actual = wav_info(safe_audio_path(audio_root, item["audioPath"]))
            if actual != item["audio"]:
                raise ValueError("Audio/ID mismatch or changed recording: " + identifier)
        if item["decision"] == "excluded":
            continue
        group, split = item["sourceGroup"], item["split"]
        if group in group_splits and group_splits[group] != split:
            raise ValueError("Source group crosses splits: " + group)
        group_splits[group] = split
        acoustic_key = digest({k: item["audio"][k] for k in
                              ("sampleDataSHA256", "sampleRate", "channels", "bitsPerSample", "encoding")})
        if acoustic_key in audio_ids:
            raise ValueError("Duplicate recording: " + identifier)
        audio_ids[acoustic_key] = identifier
        if item["decision"] != "accepted":
            continue
        for field in ("verbatim", "faithful"):
            reference = item.get("references", {}).get(field, {})
            if not isinstance(reference.get("text"), str) or not reference["text"].strip():
                raise ValueError("Separate, nonempty references are required")
            provenance = reference.get("provenance", {})
            kind = provenance.get("kind")
            if kind not in ("human", "ai-controlled", "ai-legacy", "public"):
                raise ValueError("Unknown reference provenance")
            if provenance.get("humanReviewed") is not (kind == "human"):
                raise ValueError("AI/public reference must not claim personal human approval")
            if not provenance.get("checks") or not provenance.get("sourceSHA256"):
                raise ValueError("Missing provenance controls or source hash")
            if kind == "ai-controlled" and not all(provenance.get(k) for k in ("model", "revision", "promptSHA256")):
                raise ValueError("Controlled AI references require model, revision and prompt hash")
            if kind == "public" and not all(provenance.get(k) for k in ("dataset", "revision", "license")):
                raise ValueError("Public references require a documented source and license")
            key = (field, tuple(words(reference["text"])))
            if key in texts and texts[key] != split:
                raise ValueError("Duplicate reference crosses splits")
            texts[key] = split


def select(manifest: dict, split: str) -> list[dict]:
    validate(manifest)
    items = [item for item in manifest["items"] if item["split"] == split and item["decision"] == "accepted"]
    if not items:
        raise ValueError("No accepted references in requested split: " + split)
    return items


def identity(item: dict, run: dict) -> dict:
    return {"schemaVersion": 2, "id": item["id"], "itemSHA256": item["itemSHA256"],
            "audioSHA256": item["audio"]["sha256"], "referenceSHA256": item["referenceSHA256"],
            "runSHA256": digest(run)}


def validate_results(rows: list[dict], items: list[dict], run: dict) -> dict[str, dict]:
    expected = {item["id"]: item for item in items}
    found = {}
    for row in rows:
        identifier = row.get("id")
        if identifier not in expected or identifier in found:
            raise ValueError("Unknown or duplicate prediction ID")
        if any(row.get(k) != v for k, v in identity(expected[identifier], run).items()):
            raise ValueError("Stale prediction: audio, reference, runner, model or parameters changed")
        if row.get("status") not in ("ok", "error"):
            raise ValueError("Inference status is required")
        for key in ("inferenceMilliseconds", "durationMilliseconds"):
            value = row.get(key)
            if value is not None and (isinstance(value, bool) or not isinstance(value, (float, int))
                                      or not math.isfinite(value) or value < 0):
                raise ValueError("Invalid latency")
        found[identifier] = row
    return found


def edit_counts(reference: list[str], hypothesis: list[str]) -> dict:
    # Cost, substitutions, deletions, insertions; diagonal wins tied alignments.
    previous = [(i, 0, 0, i) for i in range(len(hypothesis) + 1)]
    for i, word in enumerate(reference, 1):
        current = [(i, 0, i, 0)]
        for j, actual in enumerate(hypothesis, 1):
            c, s, d, ins = previous[j - 1]
            diagonal = (c + (word != actual), s + (word != actual), d, ins)
            c, s, d, ins = previous[j]
            deletion = (c + 1, s, d + 1, ins)
            c, s, d, ins = current[j - 1]
            insertion = (c + 1, s, d, ins + 1)
            current.append(min((diagonal, deletion, insertion), key=lambda v: v[0]))
        previous = current
    cost, substitutions, deletions, insertions = previous[-1]
    return {"errors": cost, "substitutions": substitutions, "deletions": deletions,
            "insertions": insertions, "referenceWords": len(reference)}


def percentile(values: list[float], p: float) -> float | None:
    if (isinstance(p, bool) or not isinstance(p, (int, float))
            or not math.isfinite(p) or not 0 <= p <= 1
            or any(isinstance(v, bool) or not isinstance(v, (int, float))
                   or not math.isfinite(v) or v < 0 for v in values)):
        raise ValueError("Percentile requires finite non-negative observations and a fraction in [0, 1]")
    return sorted(values)[min(len(values) - 1, max(0, math.ceil(len(values) * p) - 1))] if values else None


def summarize(rows: list[dict]) -> dict:
    total = sum(row["referenceWords"] for row in rows)
    result = {key: sum(row[key] for row in rows) for key in
              ("errors", "substitutions", "deletions", "insertions", "referenceWords")}
    result.update(count=len(rows), lexicalWER=result["errors"] / total if total else None,
                  missing=sum(row["missing"] for row in rows), failures=sum(row["failure"] for row in rows),
                  exact=sum(row["exact"] for row in rows),
                  numericSequenceDifferences=sum(row["numericDifference"] for row in rows),
                  negationSequenceDifferences=sum(row["negationDifference"] for row in rows))
    groups = defaultdict(lambda: [0, 0])
    for row in rows:
        groups[row["sourceGroup"]][0] += row["errors"]
        groups[row["sourceGroup"]][1] += row["referenceWords"]
    rng = random.Random(1729)
    values = list(groups.values())
    estimates = []
    if len(values) >= BOOTSTRAP_MINIMUM_GROUPS:
        for _ in range(1000):
            draws = rng.choices(values, k=len(values))
            estimates.append(sum(d[0] for d in draws) / max(1, sum(d[1] for d in draws)))
    result["sourceGroupCount"] = len(values)
    result["bootstrapMinimumGroups"] = BOOTSTRAP_MINIMUM_GROUPS
    result["groupBootstrap95CI"] = [percentile(estimates, 0.025), percentile(estimates, 0.975)]
    return result


def score(items: list[dict], predictions: list[dict], run: dict, stage: str = "raw") -> dict:
    if stage == "candidate":
        raise ValueError("Candidate text contains unrestored protected tokens; score normalized or final text instead")
    if stage not in ("raw", "normalized", "final"):
        raise ValueError("Unknown processing stage")
    found = validate_results(predictions, items, run)
    reference_field = "verbatim" if stage == "raw" else "faithful"
    output_field = {"raw": "transcript", "normalized": "normalized", "candidate": "candidate", "final": "finalText"}[stage]
    rows = []
    for item in items:
        prediction = found.get(item["id"], {})
        missing = not isinstance(prediction.get(output_field), str) or bool(prediction.get("missingInference"))
        actual = prediction.get(output_field, "")
        if missing:
            actual = ""
        if stage == "raw" and prediction.get("status") == "error":
            actual = ""
        expected = item["references"][reference_field]["text"]
        row = {"id": item["id"], "sourceGroup": item["sourceGroup"], "language": item["language"],
               "categories": item["categories"], "missing": missing,
               "failure": missing or prediction.get("status") == "error" or bool(prediction.get("failure")),
               "exact": actual == expected,
               "numericDifference": NUMBER.findall(actual) != NUMBER.findall(expected),
               "negationDifference": NEGATION.findall(actual.casefold()) != NEGATION.findall(expected.casefold()),
               **edit_counts(words(expected), words(actual))}
        rows.append(row)
    grouped = defaultdict(list)
    for row in rows:
        grouped[row["language"]].append(row)
    timing_field = {"raw": "inferenceMilliseconds", "final": "durationMilliseconds"}.get(stage)
    successful_times, failed_times = [], []
    for row in rows:
        prediction = found.get(row["id"], {})
        timing = prediction.get(timing_field) if timing_field else None
        if timing is not None and not prediction.get("missingInference"):
            (failed_times if row["failure"] else successful_times).append(timing)
    latencies = successful_times + failed_times
    def timing_summary(values: list[float]) -> dict:
        return {"p50": percentile(values, .5), "p95": percentile(values, .95)}
    return {"stage": stage, "normalizationVersion": NORMALIZATION, "scoringVersion": SCORING,
            "runSHA256": digest(run),
            "coverageComplete": len(found) == len(items) and not any(row["missing"] for row in rows),
            "promotionAllowed": False,
            "interpretation": "Diagnostic; numeric/negation checks are literal alerts, not semantic factual approval.",
            "summary": summarize(rows), "byLanguage": {k: summarize(v) for k, v in grouped.items()},
            "latencyObservationField": timing_field,
            "latencyScope": "selected stage only; all recorded attempts, including failures; not end-to-end delivery",
            "timingCoverage": {"expected": len(items), "observed": len(latencies),
                               "missing": len(items) - len(latencies),
                               "successful": len(successful_times), "failed": len(failed_times)},
            "latencyMilliseconds": timing_summary(latencies),
            "successfulLatencyMilliseconds": timing_summary(successful_times),
            "failedLatencyMilliseconds": timing_summary(failed_times),
            "rows": rows}
