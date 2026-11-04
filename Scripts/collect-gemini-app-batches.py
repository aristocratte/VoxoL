#!/usr/bin/env python3
"""Collect resumable Gemini.app predictions with several audio files per chat."""

from __future__ import annotations

import argparse
from difflib import SequenceMatcher
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
from typing import Iterable
import unicodedata


SESSION_TRANSPORT = "gemini_macos_session_file_upload_v2"
ALIGNED_BATCH_TRANSPORT = "gemini_macos_aligned_batch_file_upload_v3"
REUSABLE_TRANSPORTS = {
    "gemini_macos_file_upload",
    SESSION_TRANSPORT,
    ALIGNED_BATCH_TRANSPORT,
}
WORD_PATTERN = re.compile(r"[^\W_]+(?:['’][^\W_]+)*|\d+(?:[.,:/-]\d+)*", re.UNICODE)
BRIDGE_FAILURE_TEXT = (
    "no audio file was attached",
    "no audio was attached",
    "please upload or attach the audio",
    "please provide or attach the audio file",
    "je n'ai pas reçu de fichier audio",
    "aucun fichier audio n'a été joint",
)


DEFAULT_CONFIDENCE = {
    "blankDecisionRatio": 0.0,
    "emittedTokenCount": 0,
    "inferenceAttemptCount": 1,
    "lowerDecileDurationLogitMargin": 0.0,
    "lowerDecileTokenLogitMargin": 0.0,
    "maximumFramesWithoutEmission": 0,
    "meanDurationLogitMargin": 0.0,
    "meanTokenLogitMargin": 0.0,
    "usedFallbackSegmentation": False,
}


class GeminiBridgeError(RuntimeError):
    """A bridge/setup failure that cannot be repaired by splitting a batch."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def joined_transcript(record: dict[str, object], field: str) -> str:
    pieces = []
    for chunk in record.get("results") or []:
        text = str(chunk.get(field) or "").strip()
        if text:
            pieces.append(text)
    return " ".join(pieces)


def prediction_row(
    identifier: str,
    verbatim: str,
    polished: str = "",
    inference_milliseconds: float = 0.0,
    transport: str = SESSION_TRANSPORT,
    source_audio_sha256: str = "",
    alignment: dict[str, object] | None = None,
) -> dict[str, object]:
    confidence = dict(DEFAULT_CONFIDENCE)
    confidence["emittedTokenCount"] = len(verbatim.split())
    row: dict[str, object] = {
        "id": identifier,
        "rawText": verbatim.strip(),
        # Machine rewrites remain review candidates. Head-to-head adjudication uses
        # the faithful transcript so a Gemini rewrite cannot silently become truth.
        "finalText": verbatim.strip(),
        "inferenceMilliseconds": inference_milliseconds,
        "confidence": confidence,
        "teacher": {
            "provider": "Gemini macOS",
            "transport": transport,
            "labelTier": "silver",
        },
    }
    if source_audio_sha256:
        row["sourceAudioSHA256"] = source_audio_sha256
    if alignment:
        row["alignment"] = alignment
    if polished.strip():
        row["polishedCandidate"] = polished.strip()
    return row


def normalized_words(text: str) -> list[str]:
    value = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    return [match.group(0) for match in WORD_PATTERN.finditer(value)]


def transcript_similarity(left: str, right: str) -> float:
    left_words = normalized_words(left)
    right_words = normalized_words(right)
    if not left_words and not right_words:
        return 1.0
    return SequenceMatcher(None, left_words, right_words, autojunk=False).ratio()


def looks_like_bridge_failure(text: str) -> bool:
    normalized = unicodedata.normalize("NFKC", text).casefold().replace("’", "'")
    return any(fragment in normalized for fragment in BRIDGE_FAILURE_TEXT)


def validate_capture_alignment(
    identifier: str,
    verbatim: str,
    polished: str,
    reference: dict[str, object] | None,
) -> tuple[str, dict[str, object]]:
    if looks_like_bridge_failure(verbatim):
        raise ValueError(f"Gemini did not receive the audio for {identifier}")
    if reference is None:
        return polished, {"mode": "one_audio_per_message", "status": "not_checked"}

    reference_texts = {
        str(reference.get("rawText") or "").strip(),
        str(reference.get("finalText") or "").strip(),
    }
    reference_texts.discard("")
    if not reference_texts:
        return polished, {"mode": "one_audio_per_message", "status": "not_checked"}

    verbatim_score = max(
        transcript_similarity(verbatim, reference_text) for reference_text in reference_texts
    )
    reference_word_count = max(len(normalized_words(text)) for text in reference_texts)
    minimum_score = 0.25 if reference_word_count <= 5 else 0.35
    if verbatim_score < minimum_score:
        raise ValueError(
            f"Gemini transcript/reference mismatch for {identifier}: "
            f"{verbatim_score:.3f} < {minimum_score:.3f}"
        )

    polished_score = (
        max(transcript_similarity(polished, reference_text) for reference_text in reference_texts)
        if polished.strip()
        else 0.0
    )
    accepted_polished = polished if not polished.strip() or polished_score >= minimum_score else ""
    return accepted_polished, {
        "mode": "one_audio_per_message",
        "status": "verified_against_parakeet",
        "referenceSystem": "parakeet",
        "verbatimSimilarity": round(verbatim_score, 6),
        "polishedSimilarity": round(polished_score, 6),
        "minimumSimilarity": minimum_score,
        "polishedCandidateAccepted": bool(accepted_polished.strip()),
    }


def best_two_assignments(score_matrix: list[list[float]]) -> list[tuple[float, tuple[int, ...]]]:
    states: dict[int, list[tuple[float, tuple[int, ...]]]] = {0: [(0.0, ())]}
    for row in score_matrix:
        next_states: dict[int, list[tuple[float, tuple[int, ...]]]] = {}
        for mask, candidates in states.items():
            for score, assignment in candidates:
                for column, item_score in enumerate(row):
                    if mask & (1 << column):
                        continue
                    next_mask = mask | (1 << column)
                    next_states.setdefault(next_mask, []).append(
                        (score + item_score, assignment + (column,))
                    )
        states = {
            mask: sorted(candidates, key=lambda candidate: candidate[0], reverse=True)[:2]
            for mask, candidates in next_states.items()
        }
    return states.get((1 << len(score_matrix)) - 1, [])


def align_batch_captures(
    captures: dict[str, tuple[str, str]],
    identifiers: list[str],
    references: dict[str, dict[str, object]],
) -> dict[str, tuple[str, str, dict[str, object]]]:
    if len(captures) != len(identifiers) or any(identifier not in references for identifier in identifiers):
        raise ValueError("aligned Gemini batches require one reference per requested audio")

    capture_items = list(captures.items())
    for claimed_id, (verbatim, _) in capture_items:
        if looks_like_bridge_failure(verbatim):
            raise ValueError(f"Gemini did not receive the audio claimed as {claimed_id}")

    reference_texts: dict[str, list[str]] = {}
    for identifier in identifiers:
        row = references[identifier]
        texts = [
            str(row.get("rawText") or "").strip(),
            str(row.get("finalText") or "").strip(),
        ]
        reference_texts[identifier] = list(dict.fromkeys(text for text in texts if text))
        if not reference_texts[identifier]:
            raise ValueError(f"alignment reference is empty for {identifier}")

    score_matrix = [
        [
            max(transcript_similarity(verbatim, text) for text in reference_texts[identifier])
            for identifier in identifiers
        ]
        for _, (verbatim, _) in capture_items
    ]
    assignments = best_two_assignments(score_matrix)
    if not assignments:
        raise ValueError("Gemini batch alignment has no complete assignment")
    best_score, best_assignment = assignments[0]
    second_score = assignments[1][0] if len(assignments) > 1 else 0.0
    global_margin = best_score - second_score
    if len(identifiers) > 1 and global_margin < 0.08:
        raise ValueError(f"Gemini batch alignment is ambiguous: margin={global_margin:.3f}")

    aligned: dict[str, tuple[str, str, dict[str, object]]] = {}
    for capture_index, reference_index in enumerate(best_assignment):
        claimed_id, (verbatim, polished) = capture_items[capture_index]
        identifier = identifiers[reference_index]
        polished, base_alignment = validate_capture_alignment(
            identifier,
            verbatim,
            polished,
            references[identifier],
        )
        assigned_score = score_matrix[capture_index][reference_index]
        alternatives = [
            score
            for column, score in enumerate(score_matrix[capture_index])
            if column != reference_index
        ]
        # A global assignment can force an unrelated leftover onto a missing audio.
        # Require each individual match to be strong and unambiguous as well.
        item_margin = assigned_score - max(alternatives, default=0.0)
        if assigned_score < 0.60 or item_margin < 0.10:
            raise ValueError(
                f"Gemini batch match is uncertain for {identifier}: "
                f"similarity={assigned_score:.3f}, margin={item_margin:.3f}"
            )
        alignment = {
            **base_alignment,
            "mode": "reference_aligned_multi_file",
            "status": "verified_and_assigned",
            "claimedID": claimed_id,
            "assignedID": identifier,
            "assignmentSimilarity": round(assigned_score, 6),
            "assignmentMargin": round(item_margin, 6),
            "batchAssignmentMargin": round(global_margin, 6),
        }
        aligned[identifier] = (verbatim, polished, alignment)
    return aligned


def rows_from_records(
    manifest: dict[str, object], audio_root: Path, records_root: Path
) -> dict[str, dict[str, object]]:
    records_by_sha: dict[str, dict[str, object]] = {}
    for record_path in sorted(records_root.glob("*/record.json")):
        record = json.loads(record_path.read_text(encoding="utf-8"))
        source_sha = str((record.get("source") or {}).get("sha256") or "")
        if source_sha:
            records_by_sha[source_sha] = record

    rows = {}
    for item in manifest.get("items") or []:
        audio = audio_root / str(item["audioPath"])
        record = records_by_sha.get(sha256(audio))
        if record is None:
            continue
        verbatim = joined_transcript(record, "raw")
        if not verbatim or looks_like_bridge_failure(verbatim):
            continue
        rows[str(item["id"])] = prediction_row(
            str(item["id"]),
            verbatim,
            joined_transcript(record, "edited"),
            transport="gemini_macos_file_upload",
            source_audio_sha256=sha256(audio),
        )
    return rows


def parse_batch_response(text: str, expected_ids: Iterable[str]) -> dict[str, tuple[str, str]]:
    expected = list(expected_ids)
    value = text.strip()
    marker_pattern = re.compile(
        r"<{2,3}ITEM:([^>\n]+)>{2,3}"
        r"\s*<{2,3}VERBATIM>{2,3}\s*(.*?)\s*"
        r"<{2,3}POLISHED>{2,3}\s*(.*?)\s*<{2,3}END_ITEM>{2,3}",
        flags=re.DOTALL,
    )
    marker_matches = marker_pattern.findall(value)
    if marker_matches:
        parsed = {}
        for identifier, verbatim, polished in marker_matches:
            identifier = identifier.strip()
            verbatim = verbatim.strip()
            polished = polished.strip()
            if not identifier or not verbatim:
                raise ValueError("Gemini returned a delimited item without an id or transcript")
            if identifier in parsed:
                raise ValueError(f"Gemini returned duplicate id {identifier}")
            parsed[identifier] = (verbatim, polished)
        return require_exact_ids(parsed, expected)

    if value.startswith("```"):
        value = re.sub(r"^```(?:json)?\s*", "", value, count=1, flags=re.IGNORECASE)
        value = re.sub(r"\s*```$", "", value, count=1)
    start = value.find("{")
    end = value.rfind("}")
    if start < 0 or end < start:
        raise ValueError("Gemini returned no JSON object")
    try:
        payload = json.loads(value[start : end + 1])
    except json.JSONDecodeError as error:
        raise ValueError(f"Gemini returned invalid JSON: {error.msg}") from error
    items = payload.get("items") if isinstance(payload, dict) else None
    if not isinstance(items, list):
        raise ValueError("Gemini JSON has no items array")

    parsed: dict[str, tuple[str, str]] = {}
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("Gemini returned a non-object batch item")
        identifier = str(item.get("id") or "")
        verbatim = str(item.get("verbatim") or "").strip()
        polished = str(item.get("polished") or "").strip()
        if not identifier or not verbatim:
            raise ValueError("Gemini returned an item without an id or verbatim transcript")
        if identifier in parsed:
            raise ValueError(f"Gemini returned duplicate id {identifier}")
        parsed[identifier] = (verbatim, polished)

    return require_exact_ids(parsed, expected)


def require_exact_ids(
    parsed: dict[str, tuple[str, str]], expected: list[str]
) -> dict[str, tuple[str, str]]:
    missing = [identifier for identifier in expected if identifier not in parsed]
    unexpected = sorted(set(parsed) - set(expected))
    if missing or unexpected:
        raise ValueError(
            "Gemini batch ids do not match the request"
            + (f"; missing={','.join(missing)}" if missing else "")
            + (f"; unexpected={','.join(unexpected)}" if unexpected else "")
        )
    return parsed


def safe_alias_name(identifier: str, suffix: str) -> str:
    stem = re.sub(r"[^A-Za-z0-9._-]+", "-", identifier).strip(".-") or "audio"
    return f"{stem}{suffix.lower() or '.audio'}"


def invoke_bridge(
    items: list[dict[str, object]],
    audio_root: Path,
    bridge: Path,
    timeout: int,
    language: str,
    vocabulary: str,
    strategy: str,
    audit_root: Path,
) -> tuple[dict[str, tuple[str, str]], float, str]:
    with tempfile.TemporaryDirectory(prefix="voxol-gemini-batch-") as temporary:
        root = Path(temporary)
        request_items = []
        for item in items:
            source = (audio_root / str(item["audioPath"])).resolve()
            alias = root / safe_alias_name(str(item["id"]), source.suffix)
            try:
                os.link(source, alias)
            except OSError:
                shutil.copy2(source, alias)
            request_items.append({"id": str(item["id"]), "audioPath": str(alias)})

        request = root / "request.json"
        response = root / "response.txt"
        request.write_text(
            json.dumps(
                {
                    "items": request_items,
                    "language": language,
                    "vocabulary": vocabulary,
                    "strategy": strategy,
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        environment = os.environ.copy()
        environment["GEMINI_BRIDGE_HOSTED"] = "1"
        started = time.monotonic()
        completed = subprocess.run(
            [str(bridge), "--batch-bridge", str(request), str(response), str(timeout)],
            env=environment,
            text=True,
            capture_output=True,
        )
        elapsed = (time.monotonic() - started) * 1_000
        audit_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        capture_path = audit_root / f"{time.time_ns()}.json"
        with capture_path.open("x", encoding="utf-8") as handle:
            os.chmod(capture_path, 0o600)
            json.dump({
                "strategy": strategy,
                "items": [{"id": str(item["id"]), "audioPath": str(item["audioPath"]),
                           "sourceAudioSHA256": sha256(audio_root / str(item["audioPath"]))}
                          for item in items],
                "response": response.read_text(encoding="utf-8") if response.is_file() else None,
                "exitCode": completed.returncode,
                "elapsedMilliseconds": elapsed,
                "stderr": completed.stderr,
            }, handle, ensure_ascii=False, indent=2)
        if completed.returncode != 0:
            detail = completed.stderr.strip() or completed.stdout.strip() or "unknown bridge error"
            fatal_fragments = (
                "Accessibility access is required",
                "is signed out",
                "is not installed",
                "did not launch",
                "did not acknowledge",
                "extended reasoning",
            )
            if any(fragment in detail for fragment in fatal_fragments):
                raise GeminiBridgeError(detail)
            raise ValueError(detail)
        if not response.is_file():
            raise ValueError("Gemini batch bridge returned no response file")
        parsed = parse_batch_response(
            response.read_text(encoding="utf-8"),
            [str(item["id"]) for item in items],
        )
        return parsed, elapsed, str(capture_path)


def write_rows(
    path: Path, manifest_items: list[dict[str, object]], rows: dict[str, dict[str, object]]
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ordered = [rows[str(item["id"])] for item in manifest_items if str(item["id"]) in rows]
    encoded = "".join(
        json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in ordered
    )
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, delete=False
    ) as handle:
        handle.write(encoded)
        temporary = Path(handle.name)
    temporary.replace(path)


def load_cached_rows(
    path: Path,
    expected_audio_sha256: dict[str, str],
) -> dict[str, dict[str, object]]:
    if not path.is_file():
        return {}
    rows = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        identifier = str(row.get("id") or "")
        raw_text = str(row.get("rawText") or "").strip()
        transport = str((row.get("teacher") or {}).get("transport") or "")
        if identifier not in expected_audio_sha256 or not raw_text:
            continue
        if transport not in REUSABLE_TRANSPORTS or looks_like_bridge_failure(raw_text):
            continue
        if str(row.get("sourceAudioSHA256") or "") != expected_audio_sha256[identifier]:
            continue
        rows[identifier] = row
    return rows


def load_reference_rows(path: Path | None) -> dict[str, dict[str, object]]:
    if path is None:
        return {}
    rows: dict[str, dict[str, object]] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            row = json.loads(line)
            rows[str(row["id"])] = row
    return rows


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--manifest", type=Path, required=True)
    result.add_argument("--audio-root", type=Path, required=True)
    result.add_argument("--records", type=Path, required=True)
    result.add_argument("--output", type=Path, required=True)
    result.add_argument("--bridge", type=Path, required=True)
    result.add_argument(
        "--alignment-reference",
        type=Path,
        help="Parakeet predictions used only to reject a wrong or stale audio association.",
    )
    result.add_argument("--batch-size", type=int, default=4)
    result.add_argument("--timeout", type=int, default=300)
    result.add_argument("--language", default="auto")
    result.add_argument("--vocabulary", default="")
    result.add_argument("--retry-failures", action="store_true",
                        help="Retry audio hashes already quarantined after three failed attempts.")
    result.add_argument(
        "--max-new-items",
        type=int,
        default=0,
        help="Stop after this many uncached items; zero collects every missing item.",
    )
    return result


def main() -> int:
    arguments = parser().parse_args()
    if not 1 <= arguments.batch_size <= 10:
        raise SystemExit("--batch-size must be between 1 and 10")
    if arguments.timeout <= 0:
        raise SystemExit("--timeout must be positive")
    if arguments.max_new_items < 0:
        raise SystemExit("--max-new-items must be zero or positive")
    if not arguments.bridge.is_file():
        raise SystemExit(f"Gemini batch bridge is missing: {arguments.bridge}")

    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    items = list(manifest.get("items") or [])
    expected_audio_sha256 = {
        str(item["id"]): sha256(arguments.audio_root / str(item["audioPath"]))
        for item in items
    }
    alignment_references = load_reference_rows(arguments.alignment_reference)
    rows = rows_from_records(manifest, arguments.audio_root, arguments.records)
    rows.update(load_cached_rows(arguments.output, expected_audio_sha256))
    write_rows(arguments.output, items, rows)
    failure_path = arguments.output.with_suffix(".failures.jsonl")
    failures = {
        identifier: row
        for identifier, row in (load_reference_rows(failure_path) if failure_path.is_file() else {}).items()
        if not arguments.retry_failures and identifier not in rows and identifier in expected_audio_sha256
        and row.get("sourceAudioSHA256") == expected_audio_sha256.get(identifier)
    }
    missing = [item for item in items if str(item["id"]) not in rows
               and str(item["id"]) not in failures]
    total_missing = len(missing)
    if arguments.max_new_items:
        missing = missing[: arguments.max_new_items]
    print(
        f"Gemini batch cache: {len(rows)}/{len(items)}; "
        f"missing: {total_missing}; scheduled: {len(missing)}"
    )

    def collect(group: list[dict[str, object]], singleton_retry: int = 0) -> None:
        nonlocal rows
        identifiers = [str(item["id"]) for item in group]
        print(f"Gemini batch ({len(group)}): {identifiers[0]} … {identifiers[-1]}")
        try:
            use_aligned_batch = len(group) > 1 and all(
                identifier in alignment_references for identifier in identifiers
            )
            strategy = "aligned_multi_file" if use_aligned_batch else "one_audio_per_message"
            captures, elapsed, capture_path = invoke_bridge(
                group,
                arguments.audio_root,
                arguments.bridge,
                arguments.timeout,
                arguments.language,
                arguments.vocabulary,
                strategy,
                arguments.output.with_suffix(".captures"),
            )
            if use_aligned_batch:
                validated = align_batch_captures(
                    captures,
                    identifiers,
                    alignment_references,
                )
            else:
                validated = {}
                for item in group:
                    identifier = str(item["id"])
                    verbatim, polished = captures[identifier]
                    polished, alignment = validate_capture_alignment(
                        identifier,
                        verbatim,
                        polished,
                        alignment_references.get(identifier),
                    )
                    validated[identifier] = (verbatim, polished, alignment)
        except GeminiBridgeError as error:
            raise SystemExit(f"Gemini batch bridge failed: {error}") from error
        except (OSError, ValueError) as error:
            if len(group) == 1:
                if singleton_retry < 2:
                    print(
                        f"Gemini item retry {singleton_retry + 1}/2 for "
                        f"{identifiers[0]}: {error}"
                    )
                    collect(group, singleton_retry + 1)
                    return
                failures[identifiers[0]] = {
                    "id": identifiers[0],
                    "status": "needs_review",
                    "error": str(error),
                    "sourceAudioSHA256": expected_audio_sha256[identifiers[0]],
                }
                write_rows(arguments.output.with_suffix(".failures.jsonl"), items, failures)
                print(f"Gemini item quarantined after three attempts: {identifiers[0]}: {error}")
                return
            middle = len(group) // 2
            print(f"Gemini batch retry as {middle}+{len(group) - middle}: {error}")
            collect(group[:middle])
            collect(group[middle:])
            return
        per_item_elapsed = elapsed / len(group)
        for item in group:
            identifier = str(item["id"])
            verbatim, polished, alignment = validated[identifier]
            alignment["capturePath"] = capture_path
            rows[identifier] = prediction_row(
                identifier,
                verbatim,
                polished,
                per_item_elapsed,
                transport=(ALIGNED_BATCH_TRANSPORT if use_aligned_batch else SESSION_TRANSPORT),
                source_audio_sha256=expected_audio_sha256[identifier],
                alignment=alignment,
            )
        write_rows(arguments.output, items, rows)
        print(f"Gemini batch saved: {len(rows)}/{len(items)}")

    for start in range(0, len(missing), arguments.batch_size):
        collect(missing[start : start + arguments.batch_size])

    write_rows(arguments.output.with_suffix(".failures.jsonl"), items, failures)
    print(f"Gemini collection finished: {len(rows)}/{len(items)} predictions; "
          f"{len(failures)} need review -> {arguments.output}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
