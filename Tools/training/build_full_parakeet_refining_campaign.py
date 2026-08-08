#!/usr/bin/env python3
"""Build the full GPT Pro refining campaign from VoxoL's final ASR runtime."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
import hashlib
import io
import json
import os
from pathlib import Path
from typing import Any
import zipfile

from build_gpt_pro_text_refining_pilot_v2 import (
    add_text,
    assign_batches,
    boundary_hints,
    checksum_manifest,
    is_appledouble,
    jsonl_line,
    pretty_json,
    rights_verified,
    sanitized_source,
    sha256_file,
    source_lexicon,
    source_map,
    stable_key,
    triage,
    write_batch_archive,
)
from build_parakeet_refining_adjudication_package import load_prior_reviews
from validate_review_output_v2 import input_sha256, seal_input


PACKAGE_PREFIX = "VoxoL-GPT-Pro-Final-Runtime-Refining-Full-v1"
PROMPT_NAME = "PROMPT_GPT_PRO_FINAL_RUNTIME_REFINING_FR_v1.md"
RUN_ALL_NAME = "PROMPT_RUN_ALL_BATCHES.md"
SUPPORTED_LANGUAGES = ("fr", "en")

PROMPT_ADDENDUM = """# Campagne complète : raw VoxoL final

Cette campagne utilise la sortie exacte du runtime VoxoL sélectionné : préprocesseur NeMo fusionné,
encodeur Core ML INT8 et décodeur TDT Swift corrigé. Les règles ci-dessous complètent et, en cas de
conflit, remplacent celles du protocole général.

- `raw` est l'unique autorité sémantique et l'entrée exacte que le polisher local recevra.
- `wispr_raw_auxiliary` et `wispr_edited_candidate` sont des indices non contraignants. Ils ne
  permettent jamais de restaurer une proposition, une négation, un nombre ou une entité absente du
  `raw`.
- `prior_review_evidence`, lorsqu'il existe, provient d'une ancienne entrée ASR. Il peut aider à
  repérer un risque, mais doit être réévalué intégralement face au `raw` courant.
- `raw_neighbors` sert seulement aux frontières et à confirmer la graphie d'une surface déjà
  présente dans le segment courant. Ne copie jamais leurs mots dans la cible.
- Si le `raw` a perdu une information nécessaire ou reste trop ambigu, choisis
  `exclude_unrecoverable`. Le modèle textuel ne doit pas apprendre à deviner l'audio.
- Une surface phonétique présente dans le `raw`, comme `chiper une feature`, peut devenir
  `shipper une feature` lorsqu'une seule interprétation est fortement soutenue.
- Le statut de droits est une métadonnée de gouvernance destinée à Codex. Il ne change jamais ton
  jugement textuel et ne doit pas apparaître dans `refined_edited`.

Le but est de produire la meilleure cible de refining apprenable depuis l'entrée réellement
disponible, avec mise en forme fidèle, sans résumé, traduction ni invention.

---

"""

RUN_ALL_TEMPLATE = """# Mission globale — traiter tous les lots VoxoL

Décompresse cette archive et traite les {batch_count} ZIP présents dans `batches/`, soit exactement
{segment_count} segments. Chaque lot contient son prompt, son schéma, son validateur et ses entrées.

Pour chaque lot :

1. traite chaque `segments/<id>/input.json` indépendamment selon le prompt embarqué ;
2. crée exactement un JSON par segment sous `review-results/<id>.json` ;
3. valide les résultats avec le schéma et le validateur du lot ;
4. conserve exactement `id` et `input_sha256` ;
5. ne saute aucun lot et n'ajoute aucun fichier de résultat non demandé.

Rends une seule archive finale organisée ainsi :

`<batch-name>/review-results/<segment-id>.json`

Avant de rendre l'archive, vérifie : {segment_count}/{segment_count} JSON, zéro doublon, zéro ID
inconnu, zéro erreur de schéma et zéro erreur du validateur. Les avertissements heuristiques doivent
être signalés dans un rapport séparé, sans modifier silencieusement la cible.

N'inclus ni chaîne de pensée, ni audio, ni texte extérieur aux JSON de résultats. Tu peux reprendre
un lot déjà terminé si l'exécution est interrompue.
"""

README_TEMPLATE = """# VoxoL — campagne complète GPT Pro sur le runtime final

Cette archive textuelle contient {segment_count} segments répartis en {batch_count} lots. Elle ne
contient aucun audio, aucun secret et aucun chemin local.

Le champ `raw` est la sortie exacte du runtime Core ML/Swift sélectionné. Wispr et les anciennes
revues sont seulement des indices non contraignants. Une cible ne pourra rejoindre le fine-tuning
Qwen qu'après validation, filtrage des droits, séparation par source et benchmark aveugle.

Pour tout traiter en une fois, suis `PROMPT_RUN_ALL_BATCHES.md`. Des archives séparées FR/EN et des
groupes plus petits sont également fournies comme reprise de secours.

Snapshot : `{snapshot_id}`.
"""


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-root", required=True, type=Path)
    parser.add_argument("--source-manifest", required=True, type=Path)
    parser.add_argument("--parakeet-predictions", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--snapshot-id", required=True)
    parser.add_argument("--model-root", required=True, type=Path)
    parser.add_argument("--prior-pilot-package-root", type=Path)
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--group-batch-count", type=int, default=20)
    parser.add_argument("--seed", default="voxol-final-runtime-full-refining-v1")
    return parser.parse_args()


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            value = json.loads(line)
            if not isinstance(value, dict):
                raise RuntimeError(f"Expected object at {path}:{line_number}")
            rows.append(value)
    return rows


def sha256_tree(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(candidate for candidate in root.rglob("*") if candidate.is_file()):
        relative = path.relative_to(root).as_posix()
        if any(part.startswith("._") for part in Path(relative).parts):
            continue
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(sha256_file(path).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def compact_prior_reviews(package_root: Path | None) -> dict[str, list[dict[str, Any]]]:
    if package_root is None:
        return {}
    return load_prior_reviews(package_root.resolve())


def review_rows(all_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        row
        for row in all_rows
        if row.get("usable_for_polisher") is True
        and row.get("detected_language") in SUPPORTED_LANGUAGES
    ]


def rows_by_recording(all_rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in all_rows:
        result[str(row["recording_id"])].append(row)
    for rows in result.values():
        rows.sort(key=lambda row: int(row["chunk"]))
    return result


def risk_metadata(raw: str, row: dict[str, Any]) -> dict[str, Any]:
    candidate = dict(row)
    candidate["raw"] = raw
    result = triage(candidate)
    return result


def build_inputs(
    rows: list[dict[str, Any]],
    all_rows: list[dict[str, Any]],
    sources_by_sha: dict[str, dict[str, Any]],
    predictions: dict[str, dict[str, Any]],
    prior_reviews: dict[str, list[dict[str, Any]]],
    snapshot_id: str,
    seed: str,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    expected_ids = {str(row["id"]) for row in rows}
    missing = sorted(expected_ids - set(predictions))
    if missing:
        raise RuntimeError(f"Missing final-runtime predictions: {missing[:3]}")

    grouped = rows_by_recording(all_rows)
    ordinary_ids = sorted(
        (
            str(row["id"])
            for row in rows
            if risk_metadata(
                str(predictions[str(row["id"])].get("rawText", "")), row
            )["primary_stratum"]
            == "ordinary"
        ),
        key=lambda identifier: stable_key(f"{seed}:double-review", identifier),
    )
    ordinary_review_count = round(len(ordinary_ids) * 0.12)
    ordinary_second_review = set(ordinary_ids[:ordinary_review_count])

    outputs: list[dict[str, Any]] = []
    counts: Counter[str] = Counter()
    for row in rows:
        identifier = str(row["id"])
        raw = str(predictions[identifier].get("rawText", ""))
        recording_rows = grouped[str(row["recording_id"])]
        offset = next(
            index
            for index, candidate in enumerate(recording_rows)
            if str(candidate["id"]) == identifier
        )
        previous = recording_rows[offset - 1] if offset > 0 else None
        following = recording_rows[offset + 1] if offset + 1 < len(recording_rows) else None

        def neighbor(value: dict[str, Any] | None) -> dict[str, str] | None:
            if value is None:
                return None
            neighbor_id = str(value["id"])
            prediction = predictions.get(neighbor_id)
            if prediction is None:
                counts["neighbor_context_unavailable"] += 1
                return None
            return {"id": neighbor_id, "raw": str(prediction.get("rawText", ""))}

        previous_neighbor = neighbor(previous)
        next_neighbor = neighbor(following)
        source_record = sources_by_sha.get(str(row.get("source_sha256")), {})
        source = sanitized_source(source_record, row)
        rights_status = "verified" if rights_verified(source_record) else "hold"
        source["training_rights_status"] = rights_status
        risk = risk_metadata(raw, row)
        second_review = (
            risk["primary_stratum"] != "ordinary"
            or identifier in ordinary_second_review
            or (previous is not None and previous_neighbor is None)
            or (following is not None and next_neighbor is None)
        )

        output = seal_input(
            {
                "schema_version": "voxol-text-refining-input-v4",
                "snapshot_id": snapshot_id,
                "id": identifier,
                "expected_response_filename": f"{identifier}.json",
                "review_scope": {
                    "campaign": "full_final_runtime_parakeet_refining",
                    "raw_origin": "voxol_nemo_direct_coreml_int8_swift_tdt_final",
                    "final_training_eligible": False,
                    "next_required_gate": (
                        "validate_rights_split_and_benchmark_qwen_dataset"
                    ),
                },
                "language": str(row["detected_language"]),
                "source": source,
                "segment": {
                    "recording_id": str(row["recording_id"]),
                    "chunk": int(row["chunk"]),
                    "chunk_count": len(recording_rows),
                    "duration_seconds": float(row["duration"]),
                },
                "raw": raw,
                "wispr_raw_auxiliary": str(row.get("raw", "")),
                "wispr_edited_candidate": str(row.get("edited", "")),
                "raw_neighbors": {
                    "previous": previous_neighbor,
                    "next": next_neighbor,
                },
                "entity_lexicon": source_lexicon(
                    source,
                    raw,
                    previous_neighbor["raw"] if previous_neighbor else "",
                    next_neighbor["raw"] if next_neighbor else "",
                ),
                "prior_review_evidence": {
                    "basis_raw_origin": "older_asr_snapshot",
                    "binding": False,
                    "reviews": prior_reviews.get(identifier, []),
                },
                "asr_confidence": predictions[identifier].get("confidence"),
                "transport_status": {
                    "raw_http_status": str(row.get("raw_http_status", "unknown")),
                    "edited_http_status": str(row.get("edited_http_status", "unknown")),
                },
                "boundary_hints": boundary_hints(raw),
                "quality_control": {
                    "second_review_required": second_review,
                    "selection_stratum": risk["primary_stratum"],
                    "selection_flags_are_not_a_quality_verdict": True,
                    "training_rights_status": rights_status,
                },
            }
        )
        if output["input_sha256"] != input_sha256(output):
            raise RuntimeError(f"Failed to seal input: {identifier}")
        outputs.append(output)
        counts[f"language:{row['detected_language']}"] += 1
        counts[f"rights:{rights_status}"] += 1
        counts[f"stratum:{risk['primary_stratum']}"] += 1
        counts[f"second_review:{str(second_review).lower()}"] += 1
        counts[f"prior_review:{str(identifier in prior_reviews).lower()}"] += 1
        counts[f"raw_empty:{str(not raw.strip()).lower()}"] += 1

    return outputs, dict(sorted(counts.items()))


def validate_inputs(
    inputs: list[dict[str, Any]],
    rows: list[dict[str, Any]],
    predictions: dict[str, dict[str, Any]],
) -> None:
    expected = {str(row["id"]): row for row in rows}
    actual = {str(item["id"]): item for item in inputs}
    if len(actual) != len(inputs) or set(actual) != set(expected):
        raise RuntimeError("Full-campaign ID coverage mismatch")
    serialized = "\n".join(jsonl_line(item) for item in inputs)
    for forbidden in (
        "/Users/",
        "/Volumes/",
        '"audio_path"',
        '"mp3_path"',
        '"original_path"',
        '"direct_download_url"',
    ):
        if forbidden in serialized:
            raise RuntimeError(f"Review input leaks forbidden material: {forbidden}")
    for identifier, item in actual.items():
        if item["input_sha256"] != input_sha256(item):
            raise RuntimeError(f"Invalid input seal: {identifier}")
        if item["raw"] != str(predictions[identifier].get("rawText", "")):
            raise RuntimeError(f"Final-runtime raw changed: {identifier}")
        if item["wispr_edited_candidate"] != str(expected[identifier].get("edited", "")):
            raise RuntimeError(f"Wispr candidate changed: {identifier}")
        for neighbor in item["raw_neighbors"].values():
            if neighbor is not None and set(neighbor) != {"id", "raw"}:
                raise RuntimeError(f"Neighbor contamination: {identifier}")


def progress_csv(inputs: list[dict[str, Any]], batch_by_id: dict[str, str]) -> str:
    output = io.StringIO()
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(
        (
            "id",
            "batch",
            "language",
            "recording_id",
            "rights_status",
            "second_review_required",
            "status",
        )
    )
    for item in sorted(inputs, key=lambda value: str(value["id"])):
        writer.writerow(
            (
                item["id"],
                batch_by_id[str(item["id"])],
                item["language"],
                item["segment"]["recording_id"],
                item["quality_control"]["training_rights_status"],
                item["quality_control"]["second_review_required"],
                "pending",
            )
        )
    return output.getvalue()


def write_bundle(
    path: Path,
    package_dir: Path,
    batch_names: list[str],
    run_all: str,
) -> None:
    partial = path.with_suffix(".zip.partial")
    with zipfile.ZipFile(
        partial,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        strict_timestamps=False,
    ) as archive:
        add_text(archive, RUN_ALL_NAME, run_all)
        add_text(archive, "README_FIRST.md", run_all)
        checksum_lines: list[str] = []
        for batch_name in batch_names:
            batch = package_dir / "batches" / f"{batch_name}.zip"
            archive.write(batch, f"batches/{batch.name}")
            checksum_lines.append(f"{sha256_file(batch)}  batches/{batch.name}")
        add_text(archive, "BATCHES.sha256", "\n".join(checksum_lines) + "\n")
    os.replace(partial, path)


def write_master(path: Path, package_dir: Path, package_name: str) -> None:
    partial = path.with_suffix(".zip.partial")
    with zipfile.ZipFile(
        partial,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        strict_timestamps=False,
    ) as archive:
        for candidate in sorted(package_dir.rglob("*")):
            if candidate.is_file() and not is_appledouble(candidate, package_dir):
                relative = candidate.relative_to(package_dir).as_posix()
                archive.write(candidate, f"{package_name}/{relative}")
    os.replace(partial, path)


def main() -> int:
    arguments = parse_arguments()
    if arguments.batch_size < 1 or arguments.group_batch_count < 1:
        raise RuntimeError("Batch sizes must be positive")
    dataset_root = arguments.dataset_root.resolve()
    source_manifest = arguments.source_manifest.resolve()
    prediction_path = arguments.parakeet_predictions.resolve()
    model_root = arguments.model_root.resolve()
    output_root = arguments.output_root.resolve()
    output_root.mkdir(parents=True, exist_ok=True)

    all_rows = load_jsonl(dataset_root / "all-manifest.jsonl")
    rows = review_rows(all_rows)
    predictions_list = load_jsonl(prediction_path)
    predictions = {str(row["id"]): row for row in predictions_list}
    if len(predictions) != len(predictions_list):
        raise RuntimeError("Duplicate final-runtime prediction ID")
    sources_by_sha = source_map(load_jsonl(source_manifest))
    prior_reviews = compact_prior_reviews(arguments.prior_pilot_package_root)
    inputs, audit_counts = build_inputs(
        rows,
        all_rows,
        sources_by_sha,
        predictions,
        prior_reviews,
        arguments.snapshot_id,
        arguments.seed,
    )
    validate_inputs(inputs, rows, predictions)

    base_prompt = (
        Path(__file__).with_name("PROMPT_GPT_PRO_TEXT_REFINING_FR_v2.md")
        .read_text(encoding="utf-8")
        .replace(
            "La campagne actuelle est un pilote sur le `raw` auxiliaire de Wispr : même une cible\n"
            "déclarée utilisable devra être réalignée plus tard sur le `raw` Parakeet/Core ML/Swift exact avant\n"
            "d'entrer dans le dataset final.",
            "La campagne actuelle utilise déjà le `raw` final de VoxoL. Une cible `raw_only` reste\n"
            "provisoire jusqu'aux contrôles de droits, de split, de fidélité et de benchmark.",
        )
    )
    prompt = PROMPT_ADDENDUM + base_prompt
    schema_path = Path(__file__).with_name("review-output.schema.v2.json")
    validator_path = Path(__file__).with_name("validate_review_output_v2.py")
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    validator = validator_path.read_text(encoding="utf-8")

    batches = assign_batches(inputs, arguments.batch_size, arguments.seed)
    package_name = f"{PACKAGE_PREFIX}-{arguments.snapshot_id}"
    package_dir = output_root / package_name
    if package_dir.exists():
        raise RuntimeError(f"Output already exists: {package_dir}")
    package_dir.mkdir()
    batches_dir = package_dir / "batches"
    bundles_dir = package_dir / "bulk-upload"
    groups_dir = bundles_dir / "groups"
    batches_dir.mkdir()
    bundles_dir.mkdir()
    groups_dir.mkdir()

    batch_by_id: dict[str, str] = {}
    batch_index: list[dict[str, Any]] = []
    for position, (batch_name, items) in enumerate(sorted(batches.items()), 1):
        print(f"[{position}/{len(batches)}] {batch_name}: {len(items)}", flush=True)
        batch_path = batches_dir / f"{batch_name}.zip"
        write_batch_archive(batch_path, items, prompt, schema, validator)
        for item in items:
            batch_by_id[str(item["id"])] = batch_name
        batch_index.append(
            {
                "batch": batch_name,
                "archive": f"batches/{batch_path.name}",
                "bytes": batch_path.stat().st_size,
                "language": items[0]["language"],
                "segmentCount": len(items),
                "sha256": sha256_file(batch_path),
            }
        )

    run_all = RUN_ALL_TEMPLATE.format(
        batch_count=len(batches),
        segment_count=len(inputs),
    )
    readme = README_TEMPLATE.format(
        segment_count=len(inputs),
        batch_count=len(batches),
        snapshot_id=arguments.snapshot_id,
    )
    (package_dir / "README_FIRST.md").write_text(readme, encoding="utf-8")
    (package_dir / RUN_ALL_NAME).write_text(run_all, encoding="utf-8")
    (package_dir / PROMPT_NAME).write_text(prompt, encoding="utf-8")
    (package_dir / schema_path.name).write_text(pretty_json(schema), encoding="utf-8")
    (package_dir / validator_path.name).write_text(validator, encoding="utf-8")
    (package_dir / "selected-review-manifest.jsonl").write_text(
        "\n".join(jsonl_line(item) for item in inputs) + "\n",
        encoding="utf-8",
    )
    (package_dir / "review-progress.csv").write_text(
        progress_csv(inputs, batch_by_id),
        encoding="utf-8",
    )

    batch_names = sorted(batches)
    all_bundle = bundles_dir / f"{package_name}-ALL-{len(batches)}-batches.zip"
    write_bundle(all_bundle, package_dir, batch_names, run_all)
    language_bundles: dict[str, str] = {}
    for language in SUPPORTED_LANGUAGES:
        names = [name for name in batch_names if name.startswith(f"batch-{language}-")]
        language_bundle = bundles_dir / f"{package_name}-{language.upper()}.zip"
        write_bundle(language_bundle, package_dir, names, run_all)
        language_bundles[language] = str(language_bundle.relative_to(package_dir))

    group_bundles: list[dict[str, Any]] = []
    for offset in range(0, len(batch_names), arguments.group_batch_count):
        names = batch_names[offset : offset + arguments.group_batch_count]
        group_number = offset // arguments.group_batch_count + 1
        group_path = groups_dir / f"group-{group_number:02d}.zip"
        write_bundle(group_path, package_dir, names, run_all)
        group_bundles.append(
            {
                "archive": str(group_path.relative_to(package_dir)),
                "batchCount": len(names),
                "firstBatch": names[0],
                "lastBatch": names[-1],
                "sha256": sha256_file(group_path),
            }
        )

    model_files = ("encoder.mlpackage", "decoder.mlpackage", "joint.mlpackage", "tokenizer.json")
    for filename in model_files:
        if not (model_root / filename).exists():
            raise RuntimeError(f"Missing final runtime file: {filename}")
    package_index = {
        "schemaVersion": 1,
        "snapshotID": arguments.snapshot_id,
        "segmentCount": len(inputs),
        "batchCount": len(batches),
        "recordingCount": len({item["segment"]["recording_id"] for item in inputs}),
        "auditCounts": audit_counts,
        "source": {
            "allManifestSHA256": sha256_file(dataset_root / "all-manifest.jsonl"),
            "sourceManifestSHA256": sha256_file(source_manifest),
            "parakeetPredictionSHA256": sha256_file(prediction_path),
            "modelTreeSHA256": sha256_tree(model_root),
            "tokenizerSHA256": sha256_file(model_root / "tokenizer.json"),
        },
        "priorReviewCoverage": len(set(prior_reviews) & {str(item["id"]) for item in inputs}),
        "trainingEligibleBeforeValidation": False,
        "batches": batch_index,
        "bulkUpload": str(all_bundle.relative_to(package_dir)),
        "languageBundles": language_bundles,
        "groupBundles": group_bundles,
    }
    (package_dir / "package-index.json").write_text(
        pretty_json(package_index), encoding="utf-8"
    )
    (package_dir / "CHECKSUMS.sha256").write_text(
        checksum_manifest(package_dir), encoding="utf-8"
    )

    master = output_root / f"{package_name}.zip"
    write_master(master, package_dir, package_name)
    result = {
        "package": str(package_dir),
        "bulkUpload": str(all_bundle),
        "bulkUploadSHA256": sha256_file(all_bundle),
        "masterArchive": str(master),
        "masterArchiveSHA256": sha256_file(master),
        "segmentCount": len(inputs),
        "batchCount": len(batches),
        "auditCounts": audit_counts,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
