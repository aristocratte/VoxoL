#!/usr/bin/env python3
"""Build a sealed, text-only GPT Pro pilot for VoxoL text refining."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
from typing import Any, Iterable
import zipfile

from validate_review_output_v2 import input_sha256, seal_input


ASSET_ROOT = Path(__file__).resolve().parent
PROMPT_PATH = ASSET_ROOT / "PROMPT_GPT_PRO_TEXT_REFINING_FR_v2.md"
SCHEMA_PATH = ASSET_ROOT / "review-output.schema.v2.json"
VALIDATOR_PATH = ASSET_ROOT / "validate_review_output_v2.py"

SUPPORTED_LANGUAGES = ("fr", "en")
NUMBER_RE = re.compile(r"(?<!\w)[+\-−]?\d+(?:[.,]\d+)*(?:\s?%|\s?[A-Za-z°]+)?(?!\w)")
TOKEN_RE = re.compile(r"[\wÀ-ÖØ-öø-ÿ'+\-−./:@%]+", re.UNICODE)
CODE_OR_URL_RE = re.compile(
    r"https?://|www\.|(?:[A-Za-z0-9-]+\.)+(?:com|org|net|io|dev|ai)\b|"
    r"(?:/[A-Za-z0-9_.-]+){2,}|--[A-Za-z0-9-]+|"
    r"\b(?:git|npm|swift|swiftui|python|javascript|typescript|sql|json|api|url|"
    r"email|terminal|branch|port|dashboard|build|code review)\b",
    re.IGNORECASE,
)

PRIMARY_STRATA = (
    "raw_empty",
    "candidate_failure",
    "very_large_deletion",
    "large_deletion",
    "large_expansion",
    "number_change",
    "code_or_url",
    "boundary_incomplete",
    "ordinary",
)

STRATUM_WEIGHTS = {
    "raw_empty": 0.02,
    "candidate_failure": 0.04,
    "very_large_deletion": 0.08,
    "large_deletion": 0.08,
    "large_expansion": 0.06,
    "number_change": 0.18,
    "code_or_url": 0.12,
    "boundary_incomplete": 0.22,
    "ordinary": 0.20,
}

PRODUCT_LEXICON = {
    "ActivityPub": ("activitypub", "activity pub"),
    "ChatGPT": ("chatgpt", "chat gpt"),
    "Codex": ("codex",),
    "Core ML": ("core ml", "coreml"),
    "GitHub": ("github", "git hub"),
    "Kimi": ("kimi",),
    "MLX": ("mlx",),
    "Parakeet": ("parakeet",),
    "Qwen": ("qwen", "quen"),
    "RunPod": ("runpod", "run pod"),
    "SwiftUI": ("swiftui", "swift ui"),
    "Visual Studio Code": ("visual studio code", "vs code"),
    "Wispr Flow": ("wispr flow", "whisper flow"),
    "macOS": ("macos", "mac os"),
    "npm": ("npm", "n p m"),
}

README_TEMPLATE = """# VoxoL — pilote GPT Pro de text refining v2

Ce package contient {segment_count} segments textuels stratifiés, répartis en {batch_count} petits
lots indépendants. Il ne contient aucun audio, aucun chemin local et aucune transcription complète.

## Ce que ce pilote mesure

Il vérifie le protocole de revue, la fidélité des cibles, les frontières et le validateur avant une
campagne de 3 275 segments. Le `raw` est encore le raw auxiliaire de Wispr : aucune sortie de ce
pilote ne devient une donnée finale avant réalignement sur la sortie exacte
Parakeet/Core ML/décodeur Swift de VoxoL.

## Ce que tu dois faire

1. Décompresse cette archive maître sur ton Mac.
2. Ouvre une nouvelle conversation GPT Pro pour chaque fichier `batches/batch-*.zip`.
3. Envoie le ZIP du lot et demande : « Traite tous les `input.json` selon le prompt fourni et
   rends-moi un ZIP `review-results` contenant un JSON par segment. »
4. Ne fournis aucun autre contexte et n'ajoute pas d'audio.
5. Conserve les ZIP de résultats sans les modifier ; Codex les validera et produira le rapport du
   pilote.

Chaque lot contient le prompt, le schéma, le validateur et des entrées autoportantes. Le modèle doit
recopier l'`id` et l'`input_sha256` de chaque entrée.

## Garde-fous

- seulement des sources dont les métadonnées déclarent une licence de réutilisation vérifiée sont
  incluses par défaut ;
- seuls les raw voisins immédiats sont présents ;
- aucun candidat edited voisin ni contexte complet n'est fourni ;
- les textes raw et candidat sont byte-faithful au snapshot ;
- les cas critiques et 12 % des cas ordinaires sont marqués pour une seconde revue indépendante ;
- `usable_for_polisher=true` reste un verdict textuel provisoire, pas une admission dans le dataset
  final.

Snapshot : `{snapshot_id}`.
Sélection : {fr_count} FR, {en_count} EN, {duration_hours:.2f} h cumulées.
"""

BATCH_README = """# Lot de revue VoxoL

Traite chaque fichier `segments/*/input.json` indépendamment avec
`PROMPT_GPT_PRO_TEXT_REFINING_FR_v2.md`.

Pour chaque entrée, crée exactement un fichier JSON nommé comme `expected_response_filename`.
Place tous les résultats dans un dossier `review-results/`, puis rends ce dossier en ZIP.

N'utilise aucun contenu d'un autre segment pour compléter le segment courant. Recopie exactement
l'`id` et l'`input_sha256` fournis. Ne renvoie ni analyse, ni Markdown, ni texte extérieur aux
objets JSON.
"""

REQUIREMENTS = "jsonschema>=4.22,<5\n"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-root", required=True, type=Path)
    parser.add_argument("--source-manifest", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--snapshot-id", required=True)
    parser.add_argument("--pilot-size", type=int, default=320)
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--seed", default="voxol-text-refining-pilot-v2")
    parser.add_argument(
        "--rights-policy",
        choices=("verified-only", "all"),
        default="verified-only",
    )
    return parser.parse_args()


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def pretty_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
        allow_nan=False,
    ) + "\n"


def jsonl_line(value: Any) -> str:
    return canonical_json_bytes(value).decode("utf-8")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise RuntimeError(f"Invalid JSONL at {path}:{line_number}") from error
            if not isinstance(value, dict):
                raise RuntimeError(f"Expected object at {path}:{line_number}")
            rows.append(value)
    return rows


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def is_appledouble(path: Path, root: Path) -> bool:
    return any(part.startswith("._") for part in path.relative_to(root).parts)


def stable_key(seed: str, segment_id: str) -> str:
    return hashlib.sha256(f"{seed}:{segment_id}".encode("utf-8")).hexdigest()


def normalized_tokens(text: str) -> list[str]:
    return [token.casefold() for token in TOKEN_RE.findall(text)]


def starts_lowercase(text: str) -> bool:
    for character in text.lstrip():
        if character.isalpha():
            return character.islower()
        if character.isdigit():
            return False
    return False


def boundary_hints(raw: str) -> dict[str, bool]:
    stripped = raw.rstrip()
    ends_suspended = stripped.endswith(("...", "…", ",", ":", ";"))
    ends_without_terminal = bool(stripped) and not stripped.endswith((".", "!", "?", "…"))
    return {
        "starts_with_lowercase_letter": starts_lowercase(raw),
        "ends_with_suspension_marker": ends_suspended,
        "ends_without_terminal_punctuation": ends_without_terminal,
    }


def triage(row: dict[str, Any]) -> dict[str, Any]:
    raw = str(row.get("raw") or "")
    candidate = str(row.get("edited") or "")
    raw_tokens = normalized_tokens(raw)
    candidate_tokens = normalized_tokens(candidate)
    ratio = len(candidate_tokens) / max(len(raw_tokens), 1)
    hints = boundary_hints(raw)
    flags: list[str] = []

    if not raw.strip():
        flags.append("raw_empty")
    if not candidate.strip():
        flags.append("edited_empty")
    if str(row.get("edited_http_status")) != "200":
        flags.append("edited_request_failed")
    if len(raw_tokens) >= 8 and ratio < 0.50:
        flags.append("very_large_deletion")
    elif len(raw_tokens) >= 8 and ratio < 0.75:
        flags.append("large_deletion")
    if len(raw_tokens) >= 8 and ratio > 1.25:
        flags.append("large_expansion")
    if NUMBER_RE.findall(raw) != NUMBER_RE.findall(candidate):
        flags.append("number_change")
    if CODE_OR_URL_RE.search(raw):
        flags.append("code_or_url")
    if any(hints.values()):
        flags.append("boundary_incomplete")
    if (
        row.get("requested_language")
        and row.get("detected_language")
        and row["requested_language"] != row["detected_language"]
    ):
        flags.append("language_risk")

    if "raw_empty" in flags:
        primary = "raw_empty"
    elif "edited_request_failed" in flags or "edited_empty" in flags:
        primary = "candidate_failure"
    else:
        primary = next(
            (name for name in PRIMARY_STRATA[2:-1] if name in flags),
            "ordinary",
        )

    return {
        "primary_stratum": primary,
        "risk_flags": flags,
        "candidate_to_raw_token_ratio": round(ratio, 6),
        "boundary_hints": hints,
    }


def rights_verified(source: dict[str, Any]) -> bool:
    license_text = str(source.get("license") or "").casefold()
    return (
        "cc by" in license_text
        or "cc0" in license_text
        or "public domain" in license_text
    )


def sanitized_source(source: dict[str, Any], row: dict[str, Any]) -> dict[str, str]:
    candidates = {
        "title": source.get("title") or row.get("source_name"),
        "creator": source.get("creator"),
        "language": source.get("language") or row.get("detected_language"),
        "source_page_url": source.get("source_page_url"),
        "license": source.get("license"),
    }
    return {
        key: str(value)
        for key, value in candidates.items()
        if value is not None and str(value).strip()
    }


def source_lexicon(
    source: dict[str, str],
    raw: str,
    previous_raw: str,
    next_raw: str,
) -> list[dict[str, str]]:
    haystack = " ".join(
        (
            raw,
            previous_raw,
            next_raw,
            source.get("title", ""),
            source.get("creator", ""),
        )
    ).casefold()
    entries: list[dict[str, str]] = []
    seen: set[str] = set()

    creator = source.get("creator", "").strip()
    if creator:
        entries.append({"canonical": creator, "basis": "source_creator"})
        seen.add(creator.casefold())

    for canonical, aliases in PRODUCT_LEXICON.items():
        if any(alias.casefold() in haystack for alias in aliases):
            key = canonical.casefold()
            if key not in seen:
                entries.append({"canonical": canonical, "basis": "product_lexicon"})
                seen.add(key)
    return entries[:20]


def source_map(
    sources: Iterable[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    return {
        str(source["original_sha256"]): source
        for source in sources
        if source.get("original_sha256")
    }


def select_language_rows(
    pool: list[dict[str, Any]],
    target: int,
    seed: str,
) -> list[dict[str, Any]]:
    if len(pool) < target:
        raise RuntimeError(f"Only {len(pool)} eligible rows for a target of {target}")

    by_id = {str(row["id"]): row for row in pool}
    metadata = {segment_id: triage(row) for segment_id, row in by_id.items()}
    selected: dict[str, dict[str, Any]] = {}

    def add(row: dict[str, Any]) -> None:
        if len(selected) < target:
            selected.setdefault(str(row["id"]), row)

    def ordered(values: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
        return sorted(values, key=lambda row: stable_key(seed, str(row["id"])))

    for row in ordered(
        row
        for row in pool
        if metadata[str(row["id"])]["primary_stratum"]
        in {"raw_empty", "candidate_failure"}
    ):
        add(row)

    rows_by_recording: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in pool:
        rows_by_recording[str(row["recording_id"])].append(row)
    stratum_rank = {name: index for index, name in enumerate(PRIMARY_STRATA)}
    for recording_id in sorted(rows_by_recording):
        candidates = sorted(
            rows_by_recording[recording_id],
            key=lambda row: (
                stratum_rank[metadata[str(row["id"])]["primary_stratum"]],
                stable_key(seed, str(row["id"])),
            ),
        )
        add(candidates[0])

    for stratum in PRIMARY_STRATA:
        quota = round(target * STRATUM_WEIGHTS[stratum])
        existing = sum(
            metadata[segment_id]["primary_stratum"] == stratum
            for segment_id in selected
        )
        for row in ordered(
            row
            for row in pool
            if metadata[str(row["id"])]["primary_stratum"] == stratum
            and str(row["id"]) not in selected
        )[: max(0, quota - existing)]:
            add(row)

    recording_counts = Counter(str(row["recording_id"]) for row in selected.values())
    stratum_counts = Counter(
        metadata[segment_id]["primary_stratum"] for segment_id in selected
    )
    remaining = [row for row in pool if str(row["id"]) not in selected]
    while len(selected) < target:
        row = min(
            remaining,
            key=lambda candidate: (
                recording_counts[str(candidate["recording_id"])],
                stratum_counts[metadata[str(candidate["id"])]["primary_stratum"]],
                stable_key(seed, str(candidate["id"])),
            ),
        )
        remaining.remove(row)
        add(row)
        recording_counts[str(row["recording_id"])] += 1
        stratum_counts[metadata[str(row["id"])]["primary_stratum"]] += 1

    return list(selected.values())


def select_pilot(
    rows: list[dict[str, Any]],
    sources_by_sha: dict[str, dict[str, Any]],
    pilot_size: int,
    seed: str,
    rights_policy: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if pilot_size < 2:
        raise RuntimeError("--pilot-size must be at least 2")

    eligible: list[dict[str, Any]] = []
    for row in rows:
        if row.get("detected_language") not in SUPPORTED_LANGUAGES:
            continue
        source = sources_by_sha.get(str(row.get("source_sha256")), {})
        if rights_policy == "verified-only" and not rights_verified(source):
            continue
        eligible.append(row)

    fr_target = pilot_size // 2 + pilot_size % 2
    targets = {"fr": fr_target, "en": pilot_size - fr_target}
    selected: list[dict[str, Any]] = []
    for language in SUPPORTED_LANGUAGES:
        language_rows = [
            row for row in eligible if row.get("detected_language") == language
        ]
        selected.extend(
            select_language_rows(
                language_rows,
                targets[language],
                f"{seed}:{language}",
            )
        )
    return selected, eligible


def build_inputs(
    selected: list[dict[str, Any]],
    all_rows: list[dict[str, Any]],
    sources_by_sha: dict[str, dict[str, Any]],
    snapshot_id: str,
    seed: str,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    rows_by_recording: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in all_rows:
        rows_by_recording[str(row["recording_id"])].append(row)
    for recording_rows in rows_by_recording.values():
        recording_rows.sort(key=lambda item: int(item["chunk"]))

    normal_ids = sorted(
        (
            str(row["id"])
            for row in selected
            if triage(row)["primary_stratum"] == "ordinary"
        ),
        key=lambda segment_id: stable_key(f"{seed}:double-review", segment_id),
    )
    ordinary_double_count = max(1, round(len(normal_ids) * 0.12)) if normal_ids else 0
    ordinary_double_ids = set(normal_ids[:ordinary_double_count])

    inputs: list[dict[str, Any]] = []
    selection_by_id: dict[str, dict[str, Any]] = {}
    for row in selected:
        recording_rows = rows_by_recording[str(row["recording_id"])]
        offset = next(
            index
            for index, item in enumerate(recording_rows)
            if item["id"] == row["id"]
        )
        previous = recording_rows[offset - 1] if offset > 0 else None
        following = (
            recording_rows[offset + 1]
            if offset + 1 < len(recording_rows)
            else None
        )
        previous_raw = str(previous["raw"]) if previous else ""
        next_raw = str(following["raw"]) if following else ""
        source = sanitized_source(
            sources_by_sha.get(str(row["source_sha256"]), {}),
            row,
        )
        triage_result = triage(row)
        critical = triage_result["primary_stratum"] != "ordinary"
        second_review = critical or str(row["id"]) in ordinary_double_ids

        review_input = seal_input(
            {
                "schema_version": "voxol-text-refining-input-v2",
                "snapshot_id": snapshot_id,
                "id": row["id"],
                "expected_response_filename": f"{row['id']}.json",
                "review_scope": {
                    "campaign": "stratified_protocol_pilot",
                    "raw_origin": "wispr_flow_raw_auxiliary",
                    "final_training_eligible": False,
                    "next_required_gate": (
                        "realign_on_exact_voxol_parakeet_coreml_swift_raw"
                    ),
                },
                "language": row["detected_language"],
                "source": source,
                "segment": {
                    "recording_id": row["recording_id"],
                    "chunk": row["chunk"],
                    "chunk_count": len(recording_rows),
                },
                "raw": str(row["raw"]),
                "wispr_edited_candidate": str(row["edited"]),
                "raw_neighbors": {
                    "previous": (
                        {"id": previous["id"], "raw": previous_raw}
                        if previous
                        else None
                    ),
                    "next": (
                        {"id": following["id"], "raw": next_raw}
                        if following
                        else None
                    ),
                },
                "entity_lexicon": source_lexicon(
                    source,
                    str(row["raw"]),
                    previous_raw,
                    next_raw,
                ),
                "transport_status": {
                    "raw_http_status": str(row["raw_http_status"]),
                    "edited_http_status": str(row["edited_http_status"]),
                },
                "boundary_hints": triage_result["boundary_hints"],
                "quality_control": {
                    "second_review_required": second_review,
                    "selection_stratum": triage_result["primary_stratum"],
                    "selection_flags_are_not_a_quality_verdict": True,
                },
            }
        )
        inputs.append(review_input)
        selection_by_id[str(row["id"])] = {
            **triage_result,
            "second_review_required": second_review,
            "recording_id": row["recording_id"],
            "language": row["detected_language"],
            "duration_seconds": row["duration"],
        }
    return inputs, selection_by_id


def assign_batches(
    inputs: list[dict[str, Any]],
    batch_size: int,
    seed: str,
) -> dict[str, list[dict[str, Any]]]:
    if batch_size < 1:
        raise RuntimeError("--batch-size must be positive")
    batches: dict[str, list[dict[str, Any]]] = {}
    for language in SUPPORTED_LANGUAGES:
        language_inputs = sorted(
            (item for item in inputs if item["language"] == language),
            key=lambda item: stable_key(f"{seed}:batch", str(item["id"])),
        )
        for offset in range(0, len(language_inputs), batch_size):
            number = offset // batch_size + 1
            batches[f"batch-{language}-{number:02d}"] = language_inputs[
                offset : offset + batch_size
            ]
    return batches


def progress_csv(inputs: list[dict[str, Any]], batch_by_id: dict[str, str]) -> str:
    output = io.StringIO()
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(
        [
            "id",
            "batch",
            "language",
            "recording_id",
            "chunk",
            "second_review_required",
            "status",
            "decision",
            "confidence",
            "response_file",
        ]
    )
    for item in sorted(inputs, key=lambda value: str(value["id"])):
        writer.writerow(
            [
                item["id"],
                batch_by_id[str(item["id"])],
                item["language"],
                item["segment"]["recording_id"],
                item["segment"]["chunk"],
                item["quality_control"]["second_review_required"],
                "pending",
                "",
                "",
                item["expected_response_filename"],
            ]
        )
    return output.getvalue()


def add_text(archive: zipfile.ZipFile, name: str, text: str) -> None:
    archive.writestr(
        name,
        text.encode("utf-8"),
        compress_type=zipfile.ZIP_DEFLATED,
    )


def add_json(archive: zipfile.ZipFile, name: str, value: Any) -> None:
    add_text(archive, name, pretty_json(value))


def write_batch_archive(
    path: Path,
    items: list[dict[str, Any]],
    prompt: str,
    schema: dict[str, Any],
    validator: str,
) -> None:
    partial = path.with_suffix(".zip.partial")
    with zipfile.ZipFile(
        partial,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        strict_timestamps=False,
    ) as archive:
        add_text(archive, "README_FIRST.md", BATCH_README)
        add_text(archive, PROMPT_PATH.name, prompt)
        add_json(archive, SCHEMA_PATH.name, schema)
        add_text(archive, VALIDATOR_PATH.name, validator)
        add_text(archive, "requirements-review.txt", REQUIREMENTS)
        manifest_lines: list[str] = []
        for item in items:
            segment_root = f"segments/{item['id']}"
            add_json(archive, f"{segment_root}/input.json", item)
            manifest_lines.append(jsonl_line(item))
        add_text(
            archive,
            "review-manifest.jsonl",
            "\n".join(manifest_lines) + "\n",
        )
        add_text(archive, "review-results/PUT_RESULTS_HERE.txt", BATCH_README)
    os.replace(partial, path)


def validate_generated_inputs(
    inputs: list[dict[str, Any]],
    original_rows: dict[str, dict[str, Any]],
) -> None:
    ids = [str(item["id"]) for item in inputs]
    if len(ids) != len(set(ids)):
        raise RuntimeError("Duplicate input id")
    serialized = "\n".join(jsonl_line(item) for item in inputs)
    for forbidden in (
        "/Users/",
        "/Volumes/",
        "\"audio_path\"",
        "\"mp3_path\"",
        "\"original_path\"",
        "\"direct_download_url\"",
    ):
        if forbidden in serialized:
            raise RuntimeError(f"Review input leaks forbidden material: {forbidden}")

    for item in inputs:
        expected_hash = input_sha256(item)
        if item.get("input_sha256") != expected_hash:
            raise RuntimeError(f"Invalid sealed input: {item['id']}")
        original = original_rows[str(item["id"])]
        if item["raw"] != original["raw"]:
            raise RuntimeError(f"Raw text changed: {item['id']}")
        if item["wispr_edited_candidate"] != original["edited"]:
            raise RuntimeError(f"Edited candidate changed: {item['id']}")
        for neighbor in item["raw_neighbors"].values():
            if neighbor is not None and set(neighbor) != {"id", "raw"}:
                raise RuntimeError(f"Neighbor contamination: {item['id']}")


def checksum_manifest(root: Path) -> str:
    lines: list[str] = []
    for path in sorted(root.rglob("*")):
        if (
            path.is_file()
            and path.name != "CHECKSUMS.sha256"
            and not is_appledouble(path, root)
        ):
            lines.append(f"{sha256_file(path)}  {path.relative_to(root).as_posix()}")
    return "\n".join(lines) + "\n"


def main() -> int:
    arguments = parse_arguments()
    dataset_root = arguments.dataset_root.resolve()
    source_manifest = arguments.source_manifest.resolve()
    output_root = arguments.output_root.resolve()
    output_root.mkdir(parents=True, exist_ok=True)

    all_manifest_path = dataset_root / "all-manifest.jsonl"
    summary_path = dataset_root / "dataset-summary.json"
    rows = load_jsonl(all_manifest_path)
    summary = load_json(summary_path)
    if len(rows) != int(summary["chunk_count"]):
        raise RuntimeError("Dataset summary and all-manifest.jsonl disagree")
    row_ids = [str(row["id"]) for row in rows]
    if len(row_ids) != len(set(row_ids)):
        raise RuntimeError("Duplicate segment id in all-manifest.jsonl")

    sources = load_jsonl(source_manifest)
    sources_by_sha = source_map(sources)
    prompt = PROMPT_PATH.read_text(encoding="utf-8")
    schema = load_json(SCHEMA_PATH)
    validator = VALIDATOR_PATH.read_text(encoding="utf-8")

    selected_rows, eligible_rows = select_pilot(
        rows,
        sources_by_sha,
        arguments.pilot_size,
        arguments.seed,
        arguments.rights_policy,
    )
    inputs, selection_by_id = build_inputs(
        selected_rows,
        rows,
        sources_by_sha,
        arguments.snapshot_id,
        arguments.seed,
    )
    original_rows = {str(row["id"]): row for row in rows}
    validate_generated_inputs(inputs, original_rows)
    batches = assign_batches(inputs, arguments.batch_size, arguments.seed)
    batch_by_id = {
        str(item["id"]): batch_name
        for batch_name, batch_items in batches.items()
        for item in batch_items
    }

    package_name = (
        f"VoxoL-GPT-Pro-Text-Refining-Pilot-v2-{arguments.snapshot_id}"
    )
    package_dir = output_root / package_name
    if package_dir.exists():
        raise RuntimeError(f"Output already exists: {package_dir}")
    package_dir.mkdir()
    batches_dir = package_dir / "batches"
    batches_dir.mkdir()

    batch_index: list[dict[str, Any]] = []
    for batch_number, (batch_name, batch_items) in enumerate(sorted(batches.items()), 1):
        print(
            f"[{batch_number}/{len(batches)}] {batch_name}: "
            f"{len(batch_items)} segments",
            flush=True,
        )
        archive_path = batches_dir / f"{batch_name}.zip"
        write_batch_archive(archive_path, batch_items, prompt, schema, validator)
        batch_index.append(
            {
                "batch": batch_name,
                "archive": f"batches/{archive_path.name}",
                "sha256": sha256_file(archive_path),
                "bytes": archive_path.stat().st_size,
                "language": batch_items[0]["language"],
                "segment_count": len(batch_items),
            }
        )

    language_counts = Counter(str(item["language"]) for item in inputs)
    selected_duration = sum(
        float(selection_by_id[str(item["id"])]["duration_seconds"])
        for item in inputs
    )
    selection_records = []
    for item in sorted(inputs, key=lambda value: str(value["id"])):
        metadata = selection_by_id[str(item["id"])]
        selection_records.append(
            {
                "id": item["id"],
                "batch": batch_by_id[str(item["id"])],
                **metadata,
            }
        )

    pool_by_language = Counter(str(row["detected_language"]) for row in eligible_rows)
    pool_by_stratum = Counter(triage(row)["primary_stratum"] for row in eligible_rows)
    selected_by_stratum = Counter(
        selection_by_id[str(item["id"])]["primary_stratum"] for item in inputs
    )
    selected_by_recording = Counter(
        str(item["segment"]["recording_id"]) for item in inputs
    )
    selection_report = {
        "schema_version": "voxol-text-refining-pilot-selection-v2",
        "snapshot_id": arguments.snapshot_id,
        "seed": arguments.seed,
        "rights_policy": arguments.rights_policy,
        "raw_origin": "wispr_flow_raw_auxiliary",
        "final_training_eligible": False,
        "required_next_gate": "realign_on_exact_voxol_parakeet_coreml_swift_raw",
        "source_dataset": {
            "all_manifest_sha256": sha256_file(all_manifest_path),
            "source_manifest_sha256": sha256_file(source_manifest),
            "total_segment_count": len(rows),
            "eligible_segment_count": len(eligible_rows),
            "eligible_by_language": dict(sorted(pool_by_language.items())),
            "eligible_by_primary_stratum": dict(sorted(pool_by_stratum.items())),
        },
        "selection": {
            "segment_count": len(inputs),
            "duration_hours": round(selected_duration / 3600, 6),
            "language_counts": dict(sorted(language_counts.items())),
            "primary_stratum_counts": dict(sorted(selected_by_stratum.items())),
            "recording_count": len(selected_by_recording),
            "recording_counts": dict(sorted(selected_by_recording.items())),
            "second_review_required_count": sum(
                bool(item["quality_control"]["second_review_required"])
                for item in inputs
            ),
        },
        "segments": selection_records,
    }

    readme = README_TEMPLATE.format(
        segment_count=len(inputs),
        batch_count=len(batches),
        snapshot_id=arguments.snapshot_id,
        fr_count=language_counts["fr"],
        en_count=language_counts["en"],
        duration_hours=selected_duration / 3600,
    )
    (package_dir / "README_FIRST.md").write_text(readme, encoding="utf-8")
    (package_dir / PROMPT_PATH.name).write_text(prompt, encoding="utf-8")
    (package_dir / SCHEMA_PATH.name).write_text(pretty_json(schema), encoding="utf-8")
    (package_dir / VALIDATOR_PATH.name).write_text(validator, encoding="utf-8")
    (package_dir / "requirements-review.txt").write_text(
        REQUIREMENTS,
        encoding="utf-8",
    )
    (package_dir / "pilot-selection.json").write_text(
        pretty_json(selection_report),
        encoding="utf-8",
    )
    (package_dir / "selected-review-manifest.jsonl").write_text(
        "\n".join(jsonl_line(item) for item in inputs) + "\n",
        encoding="utf-8",
    )
    (package_dir / "review-progress.csv").write_text(
        progress_csv(inputs, batch_by_id),
        encoding="utf-8",
    )

    package_index = {
        "schema_version": "voxol-text-refining-pilot-package-v2",
        "snapshot_id": arguments.snapshot_id,
        "contains_audio": False,
        "contains_full_recording_context": False,
        "contains_edited_neighbors": False,
        "contains_local_paths": False,
        "segment_count": len(inputs),
        "batch_count": len(batches),
        "batches": batch_index,
    }
    (package_dir / "package-index.json").write_text(
        pretty_json(package_index),
        encoding="utf-8",
    )
    (package_dir / "CHECKSUMS.sha256").write_text(
        checksum_manifest(package_dir),
        encoding="utf-8",
    )

    master_path = output_root / f"{package_name}.zip"
    partial = master_path.with_suffix(".zip.partial")
    with zipfile.ZipFile(
        partial,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        strict_timestamps=False,
    ) as archive:
        for path in sorted(package_dir.rglob("*")):
            if not path.is_file() or is_appledouble(path, package_dir):
                continue
            relative = path.relative_to(package_dir).as_posix()
            compression = (
                zipfile.ZIP_STORED
                if path.parent == batches_dir and path.suffix == ".zip"
                else zipfile.ZIP_DEFLATED
            )
            archive.write(
                path,
                f"{package_name}/{relative}",
                compress_type=compression,
                compresslevel=9 if compression == zipfile.ZIP_DEFLATED else None,
            )
    os.replace(partial, master_path)
    with zipfile.ZipFile(master_path) as archive:
        bad_member = archive.testzip()
        if bad_member is not None:
            raise RuntimeError(f"Corrupt master ZIP member: {bad_member}")

    master_hash = sha256_file(master_path)
    master_path.with_suffix(".zip.sha256").write_text(
        f"{master_hash}  {master_path.name}\n",
        encoding="utf-8",
    )
    print(
        pretty_json(
            {
                "status": "complete",
                "package_directory": str(package_dir),
                "master_archive": str(master_path),
                "master_sha256": master_hash,
                "master_bytes": master_path.stat().st_size,
                "segment_count": len(inputs),
                "batch_count": len(batches),
                "language_counts": dict(sorted(language_counts.items())),
                "rights_policy": arguments.rights_policy,
                "contains_audio": False,
            }
        ),
        end="",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
