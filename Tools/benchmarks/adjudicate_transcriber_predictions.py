#!/usr/bin/env python3
"""Create auditable silver references from transcriber agreement.

The output is deliberately not human gold. Gemini and Wispr can resolve an
obvious product error when they agree, while critical disagreements and large
semantic drift stay quarantined. Optional context decisions remain labeled as
agent adjudication, so promotion gates cannot mistake them for human labels.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import unicodedata


SCHEMA_VERSION = "voxol-transcript-adjudication-v2"
SUMMARY_SCHEMA = "voxol-transcript-adjudication-summary-v1"
SYSTEMS = ("parakeet", "gemini", "wispr")
TEACHERS = ("gemini", "wispr")
WORD_PATTERN = re.compile(r"[^\W_]+(?:['’][^\W_]+)*|\d+(?:[.,:/-]\d+)*", re.UNICODE)
CRITICAL_PATTERNS = {
    "url": re.compile(r"https?://\S+|\b\S+@\S+\.\S+\b", re.IGNORECASE),
    "command": re.compile(r"(?<!\w)(?:--?[A-Za-z][\w-]*|[/~][\w./~-]+)(?!\w)"),
    "number": re.compile(r"(?<!\w)[\w.-]*\d[\w.,:/%-]*(?!\w)"),
    "code": re.compile(
        r"\b(?:[A-Z]{2,}[A-Za-z0-9]*|[a-z]+[A-Z][A-Za-z0-9]*|[A-Z][a-z]+[A-Z0-9][A-Za-z0-9]*)\b"
    ),
    "negation": re.compile(
        r"\b(?:no|not|never|without|ne|pas|jamais|sans|aucun|aucune)\b|\bn['’]",
        re.IGNORECASE,
    ),
}


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def normalized_words(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    return [match.group(0) for match in WORD_PATTERN.finditer(normalized)]


def edit_distance(source: list[str], target: list[str]) -> int:
    previous = list(range(len(target) + 1))
    for source_index, source_word in enumerate(source):
        current = [source_index + 1]
        for target_index, target_word in enumerate(target):
            current.append(
                min(
                    current[target_index] + 1,
                    previous[target_index + 1] + 1,
                    previous[target_index] + (source_word != target_word),
                )
            )
        previous = current
    return previous[-1]


def normalized_distance(left: str, right: str) -> float:
    left_words = normalized_words(left)
    right_words = normalized_words(right)
    return edit_distance(left_words, right_words) / max(len(left_words), len(right_words), 1)


def critical_values(text: str) -> dict[str, list[str]]:
    values: dict[str, list[str]] = {}
    for kind, pattern in CRITICAL_PATTERNS.items():
        found = {
            match.group(0).rstrip(".,;:!?").casefold().replace("’", "'")
            for match in pattern.finditer(text)
            if match.group(0).rstrip(".,;:!?")
        }
        if found:
            values[kind] = sorted(found)
    return values


def disagreement_kinds(texts: dict[str, str]) -> list[str]:
    per_system = {system: critical_values(text) for system, text in texts.items()}
    kinds = set().union(*(values.keys() for values in per_system.values()))
    return sorted(
        kind
        for kind in kinds
        if len({tuple(values.get(kind, [])) for values in per_system.values()}) > 1
    )


def medoid(texts: dict[str, str], preferred: tuple[str, ...] = TEACHERS + ("parakeet",)) -> dict[str, object]:
    scores: dict[str, tuple[float, float]] = {}
    for system, text in texts.items():
        distances = [
            normalized_distance(text, other)
            for other_system, other in texts.items()
            if other_system != system
        ]
        scores[system] = (
            sum(distances) / max(len(distances), 1),
            max(distances, default=0.0),
        )
    priority = {system: index for index, system in enumerate(preferred)}
    selected = min(
        texts,
        key=lambda system: (scores[system][0], priority.get(system, len(priority)), system),
    )
    return {
        "system": selected,
        "text": texts[selected],
        "mean_distance": round(scores[selected][0], 6),
        "maximum_distance": round(scores[selected][1], 6),
    }


def candidate_payload(row: dict[str, object]) -> dict[str, object]:
    raw = str(row.get("rawText", "")).strip()
    final = str(row.get("finalText", "")).strip() or raw
    return {
        "raw": raw,
        "clean": final,
        "raw_sha256": sha256_text(raw),
        "clean_sha256": sha256_text(final),
        "teacher": row.get("teacher"),
        "alignment": row.get("alignment"),
        "source_audio_sha256": row.get("sourceAudioSHA256"),
    }


def adjudicate_item(
    item: dict[str, object],
    predictions: dict[str, dict[str, dict[str, object]]],
    decision: dict[str, object] | None = None,
) -> dict[str, object]:
    identifier = str(item["id"])
    candidates = {
        system: candidate_payload(rows[identifier])
        for system, rows in predictions.items()
        if identifier in rows
    }
    raw_texts = {system: str(candidate["raw"]) for system, candidate in candidates.items()}
    clean_texts = {system: str(candidate["clean"]) for system, candidate in candidates.items()}
    raw_choice = medoid(raw_texts) if raw_texts else {"system": "", "text": "", "mean_distance": 1.0, "maximum_distance": 1.0}
    clean_choice = medoid(clean_texts) if clean_texts else {"system": "", "text": "", "mean_distance": 1.0, "maximum_distance": 1.0}
    raw_critical = disagreement_kinds(raw_texts) if raw_texts else []
    clean_critical = disagreement_kinds(clean_texts) if clean_texts else []
    critical_disagreements = sorted(set(raw_critical + clean_critical))
    teacher_raw_texts = {system: raw_texts[system] for system in TEACHERS if system in raw_texts}
    teacher_clean_texts = {
        system: clean_texts[system] for system in TEACHERS if system in clean_texts
    }
    teacher_raw_choice = (
        medoid(teacher_raw_texts, preferred=TEACHERS)
        if teacher_raw_texts
        else raw_choice
    )
    teacher_clean_choice = (
        medoid(teacher_clean_texts, preferred=TEACHERS)
        if teacher_clean_texts
        else clean_choice
    )
    teacher_critical_disagreements = sorted(
        set(
            disagreement_kinds(teacher_raw_texts)
            + disagreement_kinds(teacher_clean_texts)
        )
    )
    missing = sorted(set(SYSTEMS) - set(candidates))

    teacher_raw_distance = (
        normalized_distance(raw_texts[TEACHERS[0]], raw_texts[TEACHERS[1]])
        if all(system in raw_texts for system in TEACHERS)
        else 1.0
    )
    teacher_clean_distance = (
        normalized_distance(clean_texts[TEACHERS[0]], clean_texts[TEACHERS[1]])
        if all(system in clean_texts for system in TEACHERS)
        else 1.0
    )
    proposed_raw = str(teacher_raw_choice["text"])
    proposed_clean = str(teacher_clean_choice["text"])
    clean_ratio = len(normalized_words(proposed_clean)) / max(len(normalized_words(proposed_raw)), 1)
    reasons: list[str] = []
    if missing:
        reasons.append("missing_system_predictions")
    if teacher_critical_disagreements:
        reasons.append("critical_value_disagreement")
    if teacher_raw_distance > 0.14 or teacher_clean_distance > 0.14:
        reasons.append("teacher_disagreement")
    if not 0.55 <= clean_ratio <= 1.25:
        reasons.append("clean_length_drift")
    if normalized_distance(proposed_raw, proposed_clean) > 0.35:
        reasons.append("raw_clean_content_drift")

    if decision:
        chosen_raw = str(decision.get("verbatim", "")).strip()
        chosen_clean = str(
            decision.get("faithful", decision.get("clean", ""))
        ).strip()
        chosen_rewrite = str(decision.get("rewrite", "")).strip()
        chosen_code = str(decision.get("code", "")).strip()
        chosen_raw_source = "context_decision"
        chosen_clean_source = "context_decision"
        if not chosen_raw or not chosen_clean or not str(decision.get("rationale", "")).strip():
            raise ValueError(f"Context decision for {identifier} requires verbatim, clean and rationale")
        status = "accepted"
        provenance = {
            "tier": "agent-context-adjudicated",
            "human_reviewed": False,
            "rationale": str(decision["rationale"]).strip(),
        }
        reasons = ["context_decision"]
    elif not reasons:
        chosen_raw = proposed_raw
        chosen_clean = proposed_clean
        chosen_rewrite = ""
        chosen_code = ""
        chosen_raw_source = str(teacher_raw_choice["system"])
        chosen_clean_source = str(teacher_clean_choice["system"])
        status = "accepted"
        provenance = {
            "tier": "ensemble-adjudicated",
            "human_reviewed": False,
            "rationale": "Gemini and Wispr agree within the automatic fidelity thresholds.",
        }
    elif not missing and not teacher_critical_disagreements and raw_choice["mean_distance"] <= 0.22 and clean_choice["mean_distance"] <= 0.22:
        chosen_raw = str(raw_choice["text"])
        chosen_clean = str(clean_choice["text"])
        chosen_rewrite = ""
        chosen_code = ""
        chosen_raw_source = str(raw_choice["system"])
        chosen_clean_source = str(clean_choice["system"])
        status = "context_review"
        provenance = {
            "tier": "ensemble-candidate",
            "human_reviewed": False,
            "rationale": "The medoid is plausible, but the teachers do not agree strongly enough for automatic use.",
        }
    else:
        chosen_raw = str(raw_choice["text"])
        chosen_clean = str(clean_choice["text"])
        chosen_rewrite = ""
        chosen_code = ""
        chosen_raw_source = str(raw_choice["system"])
        chosen_clean_source = str(clean_choice["system"])
        status = "quarantined"
        provenance = {
            "tier": "quarantined",
            "human_reviewed": False,
            "rationale": "The available machine evidence is not safe enough to choose a reference.",
        }

    return {
        "schema_version": SCHEMA_VERSION,
        "id": identifier,
        "audio_path": str(item.get("audioPath", "")),
        "status": status,
        "provenance": provenance,
        "chosen": {
            "verbatim_gold": chosen_raw,
            "faithful_gold": chosen_clean,
            "rewrite_gold": chosen_rewrite,
            "code_gold": chosen_code,
            "verbatim": chosen_raw,
            "clean": chosen_clean,
            "verbatim_source": chosen_raw_source,
            "faithful_source": chosen_clean_source,
            "rewrite_source": "context_decision" if chosen_rewrite else "unreviewed",
            "code_source": "context_decision" if chosen_code else "not-applicable",
            "clean_source": chosen_clean_source,
            "verbatim_sha256": sha256_text(chosen_raw),
            "faithful_sha256": sha256_text(chosen_clean),
            "rewrite_sha256": sha256_text(chosen_rewrite) if chosen_rewrite else "",
            "code_sha256": sha256_text(chosen_code) if chosen_code else "",
            "clean_sha256": sha256_text(chosen_clean),
        },
        "agreement": {
            "teacher_raw_distance": round(teacher_raw_distance, 6),
            "teacher_clean_distance": round(teacher_clean_distance, 6),
            "raw_medoid_distance": raw_choice["mean_distance"],
            "clean_medoid_distance": clean_choice["mean_distance"],
        },
        "critical_disagreements": critical_disagreements,
        "teacher_critical_disagreements": teacher_critical_disagreements,
        "reasons": sorted(set(reasons)),
        "candidates": candidates,
        "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def load_jsonl(path: Path) -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            row = json.loads(line)
            result[str(row["id"])] = row
    return result


def load_decisions(path: Path | None) -> dict[str, dict[str, object]]:
    if path is None:
        return {}
    return load_jsonl(path)


def atomic_write_text(path: Path, value: str) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


def session_directory(personal_root: Path, review: dict[str, object]) -> Path:
    audio_path = Path(str(review.get("audio_path", "")))
    if len(audio_path.parts) >= 3 and audio_path.parts[0] == "sessions":
        return personal_root / "sessions" / audio_path.parts[1]
    return personal_root / "sessions" / str(review["id"])


def write_session_review(personal_root: Path, review: dict[str, object], apply: bool) -> None:
    directory = session_directory(personal_root, review)
    if not directory.is_dir():
        return
    review_path = directory / "review.json"
    if review_path.is_file():
        existing = json.loads(review_path.read_text(encoding="utf-8"))
        if bool(existing.get("provenance", {}).get("human_reviewed", False)):
            return
    encoded = json.dumps(review, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if apply and review["status"] == "accepted":
        chosen = review["chosen"]
        verbatim = str(chosen.get("verbatim_gold", chosen["verbatim"]))
        faithful = str(chosen.get("faithful_gold", chosen["clean"]))
        rewrite = str(chosen.get("rewrite_gold", "")).strip()
        code = str(chosen.get("code_gold", "")).strip()
        atomic_write_text(directory / "verbatim.txt", verbatim)
        atomic_write_text(directory / "faithful.txt", faithful)
        atomic_write_text(directory / "corrected.txt", faithful)
        if rewrite:
            atomic_write_text(directory / "rewrite.txt", rewrite)
        if code:
            atomic_write_text(directory / "code.txt", code)
    atomic_write_text(review_path, encoded)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--manifest", type=Path, required=True)
    result.add_argument("--parakeet", type=Path, required=True)
    result.add_argument("--gemini", type=Path, required=True)
    result.add_argument("--wispr", type=Path, required=True)
    result.add_argument("--personal-root", type=Path, required=True)
    result.add_argument("--output", type=Path, required=True)
    result.add_argument("--decisions", type=Path)
    result.add_argument("--apply", action="store_true")
    return result


def main() -> int:
    arguments = parser().parse_args()
    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    predictions = {
        "parakeet": load_jsonl(arguments.parakeet),
        "gemini": load_jsonl(arguments.gemini),
        "wispr": load_jsonl(arguments.wispr),
    }
    decisions = load_decisions(arguments.decisions)
    reviews = [
        adjudicate_item(item, predictions, decision=decisions.get(str(item["id"])))
        for item in manifest["items"]
    ]
    arguments.output.mkdir(parents=True, exist_ok=True)
    review_path = arguments.output / "review.jsonl"
    atomic_write_text(
        review_path,
        "".join(json.dumps(review, ensure_ascii=False, sort_keys=True) + "\n" for review in reviews),
    )
    for review in reviews:
        write_session_review(arguments.personal_root, review, apply=arguments.apply)
    statuses = Counter(str(review["status"]) for review in reviews)
    tiers = Counter(str(review["provenance"]["tier"]) for review in reviews)
    summary = {
        "schema_version": SUMMARY_SCHEMA,
        "item_count": len(reviews),
        "statuses": dict(sorted(statuses.items())),
        "tiers": dict(sorted(tiers.items())),
        "applied_count": sum(arguments.apply and review["status"] == "accepted" for review in reviews),
        "human_reviewed_count": 0,
    }
    atomic_write_text(
        arguments.output / "summary.json",
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
