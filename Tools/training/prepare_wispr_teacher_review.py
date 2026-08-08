#!/usr/bin/env python3
"""Build a deterministic, stratified human-review queue for Wispr labels."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict, deque
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
from typing import Iterable

try:
    from Tools.training.score_asr_predictions import edit_distance, normalize
except ModuleNotFoundError:
    from score_asr_predictions import edit_distance, normalize


SCHEMA_VERSION = "voxol-teacher-audit-queue-v1"
STATE_SCHEMA_VERSION = "voxol-teacher-audit-state-v1"
DEFAULT_SEED = "voxol-teacher-audit-2026-07-29"
LANGUAGES = ("en", "fr")
SPLITS = ("train", "validation", "test")
SPLIT_RATIOS = {"train": 0.70, "validation": 0.15, "test": 0.15}
TECHNICAL_PATTERN = re.compile(
    r"\b(?:api|http|https|linux|python|javascript|swift|sql|server|software|"
    r"copyright|activitypub|gnu|kde|libreoffice|xkcd|open\s+source)\b",
    re.IGNORECASE,
)


def read_jsonl(path: Path) -> list[dict[str, object]]:
    rows = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(),
        1,
    ):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise SystemExit(f"Invalid JSON at {path}:{line_number}") from error
        if not isinstance(row, dict):
            raise SystemExit(f"Expected an object at {path}:{line_number}")
        rows.append(row)
    if not rows:
        raise SystemExit(f"Empty manifest: {path}")
    return rows


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def write_jsonl(path: Path, rows: Iterable[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    with temporary.open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(
                json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            )
    os.replace(temporary, path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def content_sha256(items: list[dict[str, object]]) -> str:
    return hashlib.sha256(
        json.dumps(
            items,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode()
    ).hexdigest()


def load_split_map(prepared_root: Path) -> dict[str, str]:
    result = {}
    for split in SPLITS:
        manifest = prepared_root / f"{split}.template.jsonl"
        for row in read_jsonl(manifest):
            identifier = str(row.get("id", ""))
            if not identifier or identifier in result:
                raise SystemExit(
                    f"Missing or duplicate review id in {manifest}: {identifier!r}"
                )
            result[identifier] = split
    return result


def stable_order(seed: str, identifier: str) -> str:
    return hashlib.sha256(f"{seed}:{identifier}".encode()).hexdigest()


def transcript_edit_ratio(raw: str, edited: str) -> float:
    raw_tokens = normalize(raw).split()
    edited_tokens = normalize(edited).split()
    if not raw_tokens:
        return 0.0
    return edit_distance(raw_tokens, edited_tokens) / len(raw_tokens)


def review_categories(row: dict[str, object]) -> list[str]:
    raw = " ".join(str(row.get("raw", "")).split())
    edited = " ".join(str(row.get("edited", "")).split())
    duration = float(row.get("duration", 0.0))
    density = len(normalize(raw).split()) / duration if duration > 0 else 0.0
    categories = []
    if row.get("teacher_warning") is True:
        categories.append("teacher-warning")
    if str(row.get("edited_http_status", "")) != "200" or not edited:
        categories.append("edited-missing")
    elif normalize(raw) != normalize(edited):
        categories.append("raw-edited-disagreement")
    if re.search(r"\d", raw):
        categories.append("number")
    if TECHNICAL_PATTERN.search(raw):
        categories.append("technical")
    if duration < 8:
        categories.append("short")
    elif duration >= 25:
        categories.append("long")
    if density < 1.25:
        categories.append("low-density")
    elif density > 3.75:
        categories.append("high-density")
    if normalize(raw) in {
        "thanks for watching",
        "thank you for watching",
        "merci d'avoir regardé",
    }:
        categories.append("possible-boilerplate")
    return categories


def review_risk(row: dict[str, object], categories: list[str]) -> float:
    weights = {
        "teacher-warning": 8.0,
        "edited-missing": 4.0,
        "raw-edited-disagreement": 3.0,
        "possible-boilerplate": 6.0,
        "number": 2.0,
        "technical": 2.0,
        "short": 1.0,
        "long": 1.0,
        "low-density": 3.0,
        "high-density": 3.0,
    }
    score = sum(weights[category] for category in categories)
    edited = " ".join(str(row.get("edited", "")).split())
    if edited:
        score += min(
            transcript_edit_ratio(str(row.get("raw", "")), edited),
            1.0,
        ) * 5
    return round(score, 6)


def split_quotas(count: int) -> dict[str, int]:
    exact = {split: count * SPLIT_RATIOS[split] for split in SPLITS}
    quotas = {split: math.floor(exact[split]) for split in SPLITS}
    remaining = count - sum(quotas.values())
    ranked = sorted(
        SPLITS,
        key=lambda split: (-(exact[split] - quotas[split]), SPLITS.index(split)),
    )
    for split in ranked[:remaining]:
        quotas[split] += 1
    return quotas


def source_balanced_risk_sample(
    rows: list[dict[str, object]],
    count: int,
    seed: str,
) -> list[dict[str, object]]:
    sources: dict[str, deque[dict[str, object]]] = {}
    for recording_id, source_rows in sorted(
        _group_by(rows, "recording_id").items()
    ):
        sources[recording_id] = deque(
            sorted(
                source_rows,
                key=lambda row: (
                    -float(row["_reviewRisk"]),
                    stable_order(seed, str(row["id"])),
                ),
            )
        )
    selected = []
    while sources and len(selected) < count:
        for recording_id in list(sources):
            selected.append(sources[recording_id].popleft())
            if not sources[recording_id]:
                del sources[recording_id]
            if len(selected) == count:
                break
    return selected


def _group_by(
    rows: list[dict[str, object]],
    field: str,
) -> dict[str, list[dict[str, object]]]:
    groups: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        groups[str(row[field])].append(row)
    return groups


def select_stratum(
    rows: list[dict[str, object]],
    count: int,
    seed: str,
) -> list[dict[str, object]]:
    if len(rows) < count:
        raise SystemExit(
            f"Review stratum has {len(rows)} items but needs {count}."
        )
    risk_count = count // 2
    risk_selected = source_balanced_risk_sample(rows, risk_count, seed)
    risk_ids = {str(row["id"]) for row in risk_selected}
    representative = sorted(
        (row for row in rows if str(row["id"]) not in risk_ids),
        key=lambda row: stable_order(seed + ":representative", str(row["id"])),
    )[: count - risk_count]
    for row in risk_selected:
        row["_selectionReason"] = "risk"
    for row in representative:
        row["_selectionReason"] = "representative"
    return risk_selected + representative


def select_review_items(
    source_rows: list[dict[str, object]],
    split_map: dict[str, str],
    dataset_root: Path,
    count: int,
    seed: str,
) -> list[dict[str, object]]:
    if count < 2 or count % 2:
        raise SystemExit("--count must be an even integer of at least 2.")
    language_target = count // len(LANGUAGES)
    quotas = split_quotas(language_target)
    eligible = []
    for source in source_rows:
        identifier = str(source.get("id", ""))
        if (
            identifier not in split_map
            or source.get("usable_for_asr") is not True
            or str(source.get("raw_http_status", "")) != "200"
            or not str(source.get("raw", "")).strip()
        ):
            continue
        language = str(source.get("requested_language", ""))
        if language not in LANGUAGES:
            continue
        relative_audio = Path(str(source.get("audio_path", "")))
        if (
            relative_audio.is_absolute()
            or ".." in relative_audio.parts
            or not relative_audio.parts
        ):
            raise SystemExit(f"Unsafe audio path for {identifier}")
        audio_path = (dataset_root / relative_audio).resolve()
        if not audio_path.is_file() or audio_path.stat().st_size <= 44:
            raise SystemExit(f"Missing review audio: {audio_path}")
        row = dict(source)
        row["_split"] = split_map[identifier]
        row["_audioPath"] = str(audio_path)
        row["_reviewCategories"] = review_categories(row)
        row["_reviewRisk"] = review_risk(row, row["_reviewCategories"])
        eligible.append(row)

    selected = []
    for language in LANGUAGES:
        for split in SPLITS:
            stratum = [
                row
                for row in eligible
                if row["requested_language"] == language
                and row["_split"] == split
            ]
            selected.extend(
                select_stratum(
                    stratum,
                    quotas[split],
                    f"{seed}:{language}:{split}",
                )
            )
    selected.sort(
        key=lambda row: (
            SPLITS.index(str(row["_split"])),
            LANGUAGES.index(str(row["requested_language"])),
            str(row["recording_id"]),
            stable_order(seed + ":queue", str(row["id"])),
        )
    )
    items = []
    for index, row in enumerate(selected, 1):
        items.append(
            {
                "audioPath": row["_audioPath"],
                "audioSHA256": row["audio_sha256"],
                "categories": row["_reviewCategories"],
                "durationSeconds": row["duration"],
                "editedTranscript": " ".join(
                    str(row.get("edited", "")).split()
                ),
                "id": row["id"],
                "language": row["requested_language"],
                "rawTranscript": " ".join(str(row["raw"]).split()),
                "recordingID": row["recording_id"],
                "reviewOrder": index,
                "riskScore": row["_reviewRisk"],
                "selectionReason": row["_selectionReason"],
                "sourceName": row["source_name"],
                "speakerID": row["speaker_id"],
                "split": row["_split"],
                "startSeconds": row["start_seconds"],
            }
        )
    if len(items) != count:
        raise RuntimeError(f"Selected {len(items)} review items, expected {count}.")
    return items


def queue_report(items: list[dict[str, object]]) -> dict[str, object]:
    return {
        "byCategory": dict(
            sorted(Counter(category for row in items for category in row["categories"]).items())
        ),
        "byLanguage": dict(
            sorted(Counter(str(row["language"]) for row in items).items())
        ),
        "byRecording": dict(
            sorted(Counter(str(row["recordingID"]) for row in items).items())
        ),
        "bySelectionReason": dict(
            sorted(Counter(str(row["selectionReason"]) for row in items).items())
        ),
        "bySplit": dict(
            sorted(Counter(str(row["split"]) for row in items).items())
        ),
        "durationHours": round(
            sum(float(row["durationSeconds"]) for row in items) / 3600,
            6,
        ),
        "itemCount": len(items),
    }


def prepare(
    input_manifest: Path,
    dataset_root: Path,
    prepared_root: Path,
    output_root: Path,
    count: int,
    seed: str,
) -> dict[str, object]:
    items = select_review_items(
        read_jsonl(input_manifest),
        load_split_map(prepared_root),
        dataset_root,
        count,
        seed,
    )
    queue_digest = content_sha256(items)
    queue = {
        "schemaVersion": SCHEMA_VERSION,
        "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "inputManifest": str(input_manifest.resolve()),
        "inputManifestSHA256": sha256(input_manifest),
        "items": items,
        "queueContentSHA256": queue_digest,
        "report": queue_report(items),
        "seed": seed,
    }
    state_path = output_root / "review-state.json"
    if state_path.exists():
        state = json.loads(state_path.read_text(encoding="utf-8"))
        if state.get("queueContentSHA256") != queue_digest:
            raise SystemExit(
                "The existing review state belongs to a different queue. "
                "Move the output directory before rebuilding."
            )
    else:
        write_json(
            state_path,
            {
                "queueContentSHA256": queue_digest,
                "reviews": {},
                "schemaVersion": STATE_SCHEMA_VERSION,
                "updatedAt": None,
            },
        )
    write_json(output_root / "queue.json", queue)
    write_jsonl(output_root / "queue.jsonl", items)
    write_json(output_root / "queue-report.json", queue["report"])
    return queue


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-manifest", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--prepared-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--count", type=int, default=400)
    parser.add_argument("--seed", default=DEFAULT_SEED)
    arguments = parser.parse_args()
    queue = prepare(
        arguments.input_manifest,
        arguments.dataset_root,
        arguments.prepared_root,
        arguments.output_root,
        arguments.count,
        arguments.seed,
    )
    print(json.dumps(queue["report"], indent=2, sort_keys=True))
    print(f"Review queue ready: {arguments.output_root.resolve()}")


if __name__ == "__main__":
    main()
