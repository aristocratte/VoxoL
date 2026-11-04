#!/usr/bin/env python3
"""Build a private, auditable diagnosis of personal VoxoL dictations.

The report keeps three layers separate: the ASR transcript, Qwen's cleanup,
and machine teacher suggestions. Gemini and Wispr remain silver evidence;
only an explicitly human-reviewed session is treated as gold.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime
import json
import os
from pathlib import Path
import re
import unicodedata


WORD_PATTERN = re.compile(r"[^\W_]+(?:['’][^\W_]+)*|\d+(?:[.,:/-]\d+)*", re.UNICODE)
FRENCH_MARKERS = {
    "je", "tu", "il", "elle", "nous", "vous", "on", "le", "la", "les", "un",
    "une", "des", "du", "au", "aux", "ce", "cette", "ces", "et", "est", "sont",
    "dans", "sur", "avec", "pour", "que", "qui", "pas", "donc", "alors",
}
ENGLISH_MARKERS = {
    "i", "you", "he", "she", "we", "they", "the", "a", "an", "and", "is", "are",
    "was", "were", "in", "on", "at", "with", "for", "that", "this", "not", "so",
}
FRENCH_CODE_SWITCH_MARKERS = FRENCH_MARKERS | {
    "a", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "ne", "ça",
    "très", "bien", "plus", "mais", "comme", "quand", "après", "avant", "faut",
    "voudrais", "aimerais", "faire", "peux", "peut", "maintenant",
}
ENGLISH_CODE_SWITCH_MARKERS = ENGLISH_MARKERS | {
    "my", "your", "our", "their", "it", "to", "from", "of", "as", "if", "but",
    "then", "now", "when", "what", "how", "can", "could", "should", "would", "will",
    "need", "want", "think", "because", "please", "just", "really", "maybe", "after",
    "before", "app", "benchmark", "code", "design", "footer", "header", "laptop",
    "meeting", "model", "plugin", "prompt", "section", "slide", "switch", "teams",
    "training", "update", "website",
}
FRENCH_ONLY_CODE_SWITCH_MARKERS = FRENCH_CODE_SWITCH_MARKERS - ENGLISH_CODE_SWITCH_MARKERS
ENGLISH_ONLY_CODE_SWITCH_MARKERS = ENGLISH_CODE_SWITCH_MARKERS - FRENCH_CODE_SWITCH_MARKERS


def read_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def words(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    return [match.group(0) for match in WORD_PATTERN.finditer(normalized)]


def edit_distance(left: list[str], right: list[str]) -> int:
    previous = list(range(len(right) + 1))
    for left_index, left_word in enumerate(left):
        current = [left_index + 1]
        for right_index, right_word in enumerate(right):
            current.append(
                min(
                    current[right_index] + 1,
                    previous[right_index + 1] + 1,
                    previous[right_index] + (left_word != right_word),
                )
            )
        previous = current
    return previous[-1]


def normalized_distance(left: str, right: str) -> float:
    left_words, right_words = words(left), words(right)
    return edit_distance(left_words, right_words) / max(len(left_words), len(right_words), 1)


def language_signal(text: str) -> dict[str, object]:
    tokens = words(text)
    french = sum(token in FRENCH_MARKERS for token in tokens)
    english = sum(token in ENGLISH_MARKERS for token in tokens)
    unique = set(tokens)
    code_switch_french = len(unique & FRENCH_ONLY_CODE_SWITCH_MARKERS)
    code_switch_english = len(unique & ENGLISH_ONLY_CODE_SWITCH_MARKERS)
    code_switch = code_switch_french >= 2 and code_switch_english >= 2
    if code_switch:
        language = "mixed"
    elif french > english and french:
        language = "fr"
    elif english > french and english:
        language = "en"
    else:
        language = "unknown"
    return {
        "language": language,
        "french_marker_count": french,
        "english_marker_count": english,
        "code_switch_french_marker_count": code_switch_french,
        "code_switch_english_marker_count": code_switch_english,
        "code_switch_candidate": code_switch,
    }


def timestamp(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def load_sessions(personal_root: Path, selected_ids: set[str] | None = None) -> list[dict]:
    sessions = []
    for directory in sorted((personal_root / "sessions").glob("*")):
        if selected_ids is not None and directory.name not in selected_ids:
            continue
        meta_path = directory / "meta.json"
        audio_path = directory / "audio.wav"
        if not meta_path.is_file() or not audio_path.is_file():
            continue
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        review_path = directory / "review.json"
        review = json.loads(review_path.read_text(encoding="utf-8")) if review_path.is_file() else None
        sessions.append(
            {
                "id": directory.name,
                "directory": directory,
                "audio_path": audio_path,
                "meta": meta,
                "review": review,
            }
        )
    return sessions


def prediction_map(path: Path) -> dict[str, dict]:
    return {str(row["id"]): row for row in read_jsonl(path)}


def chosen_value(review: dict | None, *keys: str) -> str:
    chosen = (review or {}).get("chosen") or {}
    for key in keys:
        value = str(chosen.get(key) or "").strip()
        if value:
            return value
    return ""


def reference_for(session: dict, mode: str) -> tuple[str, str, bool]:
    directory, meta, review = session["directory"], session["meta"], session["review"]
    human = bool((review or {}).get("provenance", {}).get("human_reviewed", False))
    if mode == "rewrite":
        reviewed = chosen_value(review, "rewrite_gold")
        stored = directory / "rewrite.txt"
        if reviewed:
            return reviewed, "human-review" if human else "machine-review", human
        if stored.is_file() and stored.read_text(encoding="utf-8").strip():
            return stored.read_text(encoding="utf-8").strip(), "stored-rewrite", human
    faithful = chosen_value(review, "faithful_gold", "clean")
    if faithful:
        return faithful, "human-review" if human else "machine-review", human
    for name in ("faithful.txt", "corrected.txt"):
        path = directory / name
        if path.is_file() and path.read_text(encoding="utf-8").strip():
            return path.read_text(encoding="utf-8").strip(), "unverified-capture", False
    return str(meta.get("finalText") or "").strip(), "observed-insertion", False


def load_metric_pairs(path: Path) -> tuple[list[dict], dict[str, dict]]:
    rows = read_jsonl(path)
    dictations = [row for row in rows if row.get("type") == "dictation"]
    outcomes = {
        str(row.get("id")): row
        for row in rows
        if row.get("type") == "outcome" and row.get("id")
    }
    return dictations, outcomes


def match_metrics(sessions: list[dict], metrics_path: Path) -> dict[str, dict]:
    dictations, outcomes = load_metric_pairs(metrics_path)
    available = list(dictations)
    matches: dict[str, dict] = {}
    for session in sessions:
        captured = timestamp(session["meta"].get("date"))
        if captured is None or not available:
            continue
        best = min(available, key=lambda row: abs(float(row.get("ts", 0)) - captured))
        if abs(float(best.get("ts", 0)) - captured) > 5:
            continue
        available.remove(best)
        combined = dict(best)
        combined["userOutcome"] = outcomes.get(str(best.get("id")))
        matches[session["id"]] = combined
    return matches


def build_suite(
    sessions: list[dict],
    parakeet: dict[str, dict],
    mode: str,
    fallback_language: str,
    accepted_only: bool = False,
) -> dict:
    cases = []
    for session in sessions:
        if accepted_only and (session.get("review") or {}).get("status") != "accepted":
            continue
        identifier = session["id"]
        transcript = str(parakeet.get(identifier, {}).get("rawText") or session["meta"].get("rawText") or "").strip()
        if not transcript:
            continue
        expected, expected_source, human_reviewed = reference_for(session, mode)
        explicit = str(session["meta"].get("language") or "auto")
        cases.append(
            {
                "id": identifier,
                "language": explicit if explicit in {"fr", "en"} else "auto",
                "fallbackLanguage": fallback_language,
                "transcript": transcript,
                "expected": expected or transcript,
                "expectedSource": expected_source,
                "humanReviewed": human_reviewed,
                "mode": mode,
                "profile": "automatic",
            }
        )
    return {
        "schemaVersion": 1,
        "role": "private-personal-pipeline-diagnostic",
        "promotionEligible": False,
        "cases": cases,
    }


def priority_for(row: dict) -> tuple[int, list[str]]:
    score, reasons = 0, []
    outcome = str(
        (((row.get("metric") or {}).get("userOutcome") or {}).get("outcome")) or ""
    )
    if outcome in {"corrected", "rewritten"}:
        score += 100
        reasons.append(f"user_{outcome}")
    if row.get("adjudicationStatus") == "quarantined":
        score += 70
        reasons.append("teacher_conflict")
    elif row.get("adjudicationStatus") == "context_review":
        score += 45
        reasons.append("teacher_context_review")
    diagnostic = row.get("polisher") or {}
    if diagnostic.get("polisherOutcome") == "validatorRejected":
        score += 35
        reasons.append("qwen_rejected")
    if diagnostic.get("polisherOutcome") in {"modelOutputUsed", "partialRecovery"} \
        and diagnostic.get("v3Status") == "rejected":
        score += 60
        reasons.append("qwen_visible_v3_rejected")
    elif diagnostic.get("polisherOutcome") == "partialRecovery":
        score += 20
        reasons.append("qwen_partial_recovery")
    if row.get("codeSwitchCandidate"):
        score += 30
        reasons.append("code_switch_candidate")
    if float(row.get("teacherRawDistance") or 0) > 0.20:
        score += 25
        reasons.append("asr_teacher_disagreement")
    return score, reasons


def build_audit(
    sessions: list[dict],
    predictions: dict[str, dict[str, dict]],
    metrics: dict[str, dict],
    adjudications: dict[str, dict],
    polisher_results: dict[str, dict],
    mode: str,
) -> tuple[dict, list[dict]]:
    rows = []
    for session in sessions:
        identifier, meta = session["id"], session["meta"]
        product_raw = str(meta.get("rawText") or "").strip()
        product_final = str(meta.get("finalText") or "").strip()
        parakeet = predictions.get("parakeet", {}).get(identifier, {})
        raw = str(parakeet.get("rawText") or product_raw).strip()
        gemini = predictions.get("gemini", {}).get(identifier, {})
        wispr = predictions.get("wispr", {}).get(identifier, {})
        review = adjudications.get(identifier) or session.get("review") or {}
        reference, reference_source, human_reviewed = reference_for(session, mode)
        signal = language_signal(raw)
        teacher_distance = (
            normalized_distance(str(gemini.get("rawText") or ""), str(wispr.get("rawText") or ""))
            if gemini and wispr
            else None
        )
        polisher = polisher_results.get(identifier)
        reference_delta = None
        if polisher and reference and human_reviewed:
            reference_delta = round(
                normalized_distance(str(polisher.get("finalText") or ""), reference)
                - normalized_distance(str(polisher.get("normalized") or ""), reference),
                6,
            )
        row = {
            "id": identifier,
            "capturedAt": meta.get("date"),
            "durationSeconds": meta.get("durationSeconds"),
            "application": meta.get("application"),
            "audioPath": str(session["audio_path"]),
            "productRawText": product_raw,
            "productFinalText": product_final,
            "insertedChangedFromCapturedASR": product_raw != product_final,
            "currentParakeetRawText": raw,
            "geminiRawText": gemini.get("rawText"),
            "geminiFinalText": gemini.get("finalText"),
            "wisprRawText": wispr.get("rawText"),
            "wisprFinalText": wispr.get("finalText"),
            "teacherRawDistance": round(teacher_distance, 6) if teacher_distance is not None else None,
            "adjudicationStatus": review.get("status"),
            "adjudicationTier": (review.get("provenance") or {}).get("tier"),
            "adjudicationReasons": review.get("reasons") or [],
            "reference": reference,
            "referenceSource": reference_source,
            "humanReviewedReference": human_reviewed,
            "detectedLanguage": signal["language"],
            "frenchMarkerCount": signal["french_marker_count"],
            "englishMarkerCount": signal["english_marker_count"],
            "codeSwitchFrenchMarkerCount": signal["code_switch_french_marker_count"],
            "codeSwitchEnglishMarkerCount": signal["code_switch_english_marker_count"],
            "codeSwitchCandidate": signal["code_switch_candidate"],
            "metric": metrics.get(identifier),
            "polisher": polisher,
            "qwenReferenceDistanceDelta": reference_delta,
        }
        row["priority"], row["priorityReasons"] = priority_for(row)
        rows.append(row)

    rows.sort(key=lambda row: (int(row["priority"]), str(row.get("capturedAt") or "")), reverse=True)
    metric_rows = [row["metric"] for row in rows if row.get("metric")]
    polisher_rows = [row["polisher"] for row in rows if row.get("polisher")]
    requested_polisher_rows = [row for row in polisher_rows if row.get("qwenRequested")]
    visible_polisher_rows = [
        row
        for row in polisher_rows
        if row.get("polisherOutcome") in {"modelOutputUsed", "partialRecovery"}
    ]
    verified_deltas = [
        float(row["qwenReferenceDistanceDelta"])
        for row in rows
        if row.get("qwenReferenceDistanceDelta") is not None
    ]
    summary = {
        "schemaVersion": 1,
        "interpretation": "private diagnostic; machine teachers are silver and unreviewed captures are not ground truth",
        "sessionCount": len(rows),
        "durationMinutes": round(
            sum(float(row.get("durationSeconds") or 0) for row in rows) / 60,
            2,
        ),
        "capturedRawEqualsFinalCount": sum(not row["insertedChangedFromCapturedASR"] for row in rows),
        "capturedRawDiffersFinalCount": sum(row["insertedChangedFromCapturedASR"] for row in rows),
        "metricMatchedCount": len(metric_rows),
        "routes": dict(sorted(Counter(str(row.get("route") or "unknown") for row in metric_rows).items())),
        "runtimeRejections": dict(sorted(Counter(str(row.get("rejection")) for row in metric_rows if row.get("rejection")).items())),
        "userOutcomes": dict(sorted(Counter(str((row.get("userOutcome") or {}).get("outcome") or "unknown") for row in metric_rows).items())),
        "polisherDiagnosticCount": len(polisher_rows),
        "qwenRequestedCount": len(requested_polisher_rows),
        "qwenCandidateCopiedCount": sum(
            str(row.get("candidate") or "") == str(row.get("normalized") or "")
            for row in requested_polisher_rows
        ),
        "qwenCandidateChangedCount": sum(
            str(row.get("candidate") or "") != str(row.get("normalized") or "")
            for row in requested_polisher_rows
        ),
        "qwenVisibleChangedCount": len(visible_polisher_rows),
        "qwenVisibleV3RejectedCount": sum(
            row.get("v3Status") == "rejected" for row in visible_polisher_rows
        ),
        "polisherOutcomes": dict(sorted(Counter(str(row.get("polisherOutcome") or "unknown") for row in polisher_rows).items())),
        "v3Statuses": dict(sorted(Counter(str(row.get("v3Status") or "off") for row in polisher_rows).items())),
        "codeSwitchCandidateCount": sum(row["codeSwitchCandidate"] for row in rows),
        "adjudicationStatuses": dict(sorted(Counter(str(row.get("adjudicationStatus") or "pending") for row in rows).items())),
        "adjudicatedReferenceCount": sum(
            row.get("adjudicationStatus") == "accepted" for row in rows
        ),
        "humanReviewedReferenceCount": sum(row["humanReviewedReference"] for row in rows),
        "verifiedQwenHelpfulCount": sum(delta < -0.01 for delta in verified_deltas),
        "verifiedQwenHarmfulCount": sum(delta > 0.01 for delta in verified_deltas),
        "verifiedQwenNeutralCount": sum(abs(delta) <= 0.01 for delta in verified_deltas),
        "priorityReviewCount": sum(int(row["priority"]) > 0 for row in rows),
    }
    return summary, rows


def markdown_report(summary: dict, paths: dict[str, Path]) -> str:
    outcomes = summary["polisherOutcomes"] or {"not-run": 0}
    statuses = summary["adjudicationStatuses"] or {"pending": summary["sessionCount"]}
    return "\n".join(
        [
            "# Audit privé des dictées VoxoL",
            "",
            "> Les références Gemini/Wispr sont des indices silver. Les captures non relues ne sont pas du gold humain.",
            "",
            f"- Sessions : {summary['sessionCount']} ({summary['durationMinutes']:.2f} min)",
            f"- ASR brut identique au texte inséré : {summary['capturedRawEqualsFinalCount']}",
            f"- ASR brut différent du texte inséré : {summary['capturedRawDiffersFinalCount']}",
            f"- Routes observées : {json.dumps(summary['routes'], ensure_ascii=False, sort_keys=True)}",
            f"- Résultats Qwen rejoués : {json.dumps(outcomes, ensure_ascii=False, sort_keys=True)}",
            f"- Qwen sollicité : {summary['qwenRequestedCount']} ; copie brute : {summary['qwenCandidateCopiedCount']} ; candidat modifié : {summary['qwenCandidateChangedCount']}",
            f"- Changements Qwen visibles : {summary['qwenVisibleChangedCount']} ; candidats Qwen associés refusés par le validateur v3 en shadow : {summary['qwenVisibleV3RejectedCount']}",
            f"- Adjudication : {json.dumps(statuses, ensure_ascii=False, sort_keys=True)}",
            f"- Références silver tranchées : {summary['adjudicatedReferenceCount']}",
            f"- Candidats franglais/code-switch à écouter : {summary['codeSwitchCandidateCount']}",
            f"- Références réellement humaines : {summary['humanReviewedReferenceCount']}",
            "",
            "## Fichiers de travail",
            "",
            f"- File de relecture privée : `{paths['queue']}`",
            f"- Suite de rejeu Qwen : `{paths['suite']}`",
            f"- Suite Qwen limitée aux références tranchées : `{paths['adjudicated_suite']}`",
            f"- Résumé machine : `{paths['summary']}`",
            "",
            "Les éléments sont classés d'abord par correction explicite de l'utilisateur, puis par conflit entre enseignants, rejet Qwen et suspicion de code-switch.",
            "",
        ]
    )


def write_private(path: Path, value: str) -> None:
    path.write_text(value, encoding="utf-8")
    os.chmod(path, 0o600)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument(
        "--personal-root",
        type=Path,
        default=Path.home() / "Library/Application Support/VoxoL/PersonalBenchmark",
    )
    result.add_argument("--head-to-head", type=Path, required=True)
    result.add_argument(
        "--metrics",
        type=Path,
        default=Path.home() / "Library/Application Support/VoxoL/Metrics/dictations.jsonl",
    )
    result.add_argument("--polisher-output", type=Path)
    result.add_argument("--adjudication-review", type=Path)
    result.add_argument("--output-dir", type=Path, required=True)
    result.add_argument("--mode", choices=("faithful", "rewrite"), default="rewrite")
    result.add_argument("--fallback-language", choices=("fr", "en"), default="fr")
    return result


def main() -> int:
    arguments = parser().parse_args()
    if arguments.adjudication_review is not None and not arguments.adjudication_review.is_file():
        raise SystemExit(f"Adjudication review not found: {arguments.adjudication_review}")
    manifest = json.loads((arguments.head_to_head / "manifest-frozen.json").read_text(encoding="utf-8"))
    selected_ids = {str(item["id"]) for item in manifest.get("items") or []}
    sessions = load_sessions(arguments.personal_root, selected_ids)
    predictions = {
        system: prediction_map(arguments.head_to_head / f"{system}-predictions.jsonl")
        for system in ("parakeet", "gemini", "wispr")
    }
    adjudications = prediction_map(
        arguments.adjudication_review
        if arguments.adjudication_review is not None
        else arguments.head_to_head / "adjudication/review.jsonl"
    )
    if arguments.adjudication_review is not None:
        for session in sessions:
            session["review"] = adjudications.get(session["id"])
    metrics = match_metrics(sessions, arguments.metrics)
    polisher_payload = (
        json.loads(arguments.polisher_output.read_text(encoding="utf-8"))
        if arguments.polisher_output and arguments.polisher_output.is_file()
        else {}
    )
    polisher_results = {
        str(row["id"]): row for row in polisher_payload.get("results") or []
    }
    suite = build_suite(
        sessions,
        predictions["parakeet"],
        arguments.mode,
        arguments.fallback_language,
    )
    adjudicated_suite = build_suite(
        sessions,
        predictions["parakeet"],
        arguments.mode,
        arguments.fallback_language,
        accepted_only=True,
    )
    summary, rows = build_audit(
        sessions,
        predictions,
        metrics,
        adjudications,
        polisher_results,
        arguments.mode,
    )
    arguments.output_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(arguments.output_dir, 0o700)
    paths = {
        "suite": arguments.output_dir / "polisher-suite.json",
        "adjudicated_suite": arguments.output_dir / "polisher-adjudicated-suite.json",
        "summary": arguments.output_dir / "summary.json",
        "queue": arguments.output_dir / "review-queue.jsonl",
        "report": arguments.output_dir / "report.md",
    }
    write_private(paths["suite"], json.dumps(suite, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    write_private(
        paths["adjudicated_suite"],
        json.dumps(adjudicated_suite, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    )
    write_private(paths["summary"], json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    write_private(
        paths["queue"],
        "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows),
    )
    write_private(paths["report"], markdown_report(summary, paths))
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    print(paths["report"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
