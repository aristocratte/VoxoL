#!/usr/bin/env python3
"""Build a sealed GPT Pro package aligned on VoxoL's exact Parakeet output."""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
from pathlib import Path
from typing import Any
import zipfile

from build_gpt_pro_text_refining_pilot_v2 import (
    add_json,
    add_text,
    assign_batches,
    checksum_manifest,
    jsonl_line,
    pretty_json,
    sha256_file,
    write_batch_archive,
)
from score_asr_predictions import normalize
from validate_review_output_v2 import input_sha256, seal_input


PROMPT_NAME = "PROMPT_GPT_PRO_PARAKEET_REALIGNMENT_FR_v1.md"
PACKAGE_PREFIX = "VoxoL-GPT-Pro-Parakeet-Refining-Adjudication-v1"

PROMPT_ADDENDUM = """# Priorité de cette campagne : raw Parakeet exact

Cette campagne réaligne le pilote sur la sortie exacte du moteur VoxoL distribué : modèle Core ML,
features et décodeur Swift de production. Les règles ci-dessous complètent et, en cas de conflit,
remplacent celles du protocole général qui suit.

- `raw` est la sortie Parakeet exacte que le petit modèle textuel recevra en production. C'est
  l'unique autorité sur les propositions, nombres, entités, actions et relations récupérables.
- `wispr_raw_auxiliary` est une transcription teacher de la même tranche audio. Elle peut signaler
  une graphie plausible, mais elle ne permet jamais de restaurer dans la cible une unité de sens
  absente du `raw` Parakeet.
- `wispr_edited_candidate` et `prior_review_evidence` sont des propositions antérieures non
  contraignantes, établies sur le raw Wispr. Tu dois les réévaluer intégralement face au nouveau
  `raw`.
- `raw_neighbors` contient les sorties Parakeet exactes des voisins immédiats. Elles servent
  uniquement aux frontières et aux graphies déjà soutenues par le segment courant.
- Si Parakeet a perdu une proposition, un nombre, une négation ou une entité nécessaire, choisis
  `exclude_unrecoverable`. Un modèle textuel ne doit pas apprendre à deviner ce que son entrée ne
  contient pas.
- Une surface phonétique présente dans `raw`, par exemple `chiper une feature`, peut devenir
  `shipper une feature` lorsqu'une seule interprétation est fortement soutenue. Cette correction de
  surface est récupérable ; l'invention d'un mot ou d'une proposition absente ne l'est pas.
- Tous les segments exigent `requires_second_review`, car leur entrée d'exécution a changé depuis
  la revue précédente.

Le but est une cible de refining meilleure que le candidat Wispr tout en restant strictement
apprenable depuis l'entrée réellement disponible à VoxoL.

---

"""

README = """# VoxoL — réalignement du refining sur Parakeet

Ce package contient {segment_count} segments textuels répartis en {batch_count} lots. Il ne contient
aucun audio, aucun secret et aucun chemin local.

Le champ `raw` est la sortie exacte du moteur Parakeet/Core ML/Swift de VoxoL. Les anciennes sorties
Wispr et les revues précédentes sont présentes comme indices non contraignants. Une cible n'est
utilisable pour Qwen que si elle est fidèle et récupérable depuis ce `raw` exact.

Pour chaque ZIP dans `batches/`, traite tous les `input.json` selon le prompt fourni et rends un ZIP
`review-results` contenant un JSON par segment. Ne modifie jamais `id` ni `input_sha256`.

Après retour, Codex doit valider tous les JSON, exclure les cas non récupérables, figer les splits par
source et exécuter le benchmark avant tout fine-tune Qwen.
"""


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pilot-package-root", required=True, type=Path)
    parser.add_argument("--parakeet-predictions", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--snapshot-id", required=True)
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--seed", default="voxol-parakeet-realignment-v1")
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


def compact_review(review: dict[str, Any]) -> dict[str, Any]:
    fields = (
        "decision",
        "refined_edited",
        "confidence",
        "recoverable_from_raw",
        "raw_content_preserved",
        "runtime_support",
        "usable_for_polisher",
        "boundary_status",
        "edit_types",
        "formatting",
        "review_flags",
        "review_note",
    )
    return {field: review.get(field) for field in fields}


def load_prior_reviews(package_root: Path) -> dict[str, list[dict[str, Any]]]:
    result_root = (
        package_root
        / "validated-results"
        / "remaining-15-dual-review-20260801"
    )
    reviews: dict[str, list[dict[str, Any]]] = {}
    for filename in ("exact-target-consensus.jsonl", "adjudication-queue.jsonl"):
        for row in load_jsonl(result_root / filename):
            identifier = str(row["id"])
            if identifier in reviews:
                raise RuntimeError(f"Duplicate dual-review item: {identifier}")
            reviews[identifier] = [
                {"reviewer": "draft_a", **compact_review(row["reviewer_9715"])},
                {"reviewer": "draft_b", **compact_review(row["reviewer_b10f"])},
            ]

    single_archive = (
        package_root
        / "validated-results"
        / "batch-fr-01"
        / "review-results.normalized.zip"
    )
    with zipfile.ZipFile(single_archive) as archive:
        for name in archive.namelist():
            if not name.endswith(".json"):
                continue
            review = json.loads(archive.read(name))
            identifier = str(review["id"])
            if identifier in reviews:
                raise RuntimeError(f"Duplicate prior review item: {identifier}")
            reviews[identifier] = [
                {"reviewer": "pilot_single_review", **compact_review(review)}
            ]
    return reviews


def build_inputs(
    old_inputs: list[dict[str, Any]],
    predictions: dict[str, dict[str, Any]],
    prior_reviews: dict[str, list[dict[str, Any]]],
    snapshot_id: str,
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    old_by_id = {str(item["id"]): item for item in old_inputs}
    if len(old_by_id) != len(old_inputs):
        raise RuntimeError("Duplicate pilot input id")
    if set(old_by_id) - set(predictions):
        missing = sorted(set(old_by_id) - set(predictions))
        raise RuntimeError(f"Missing Parakeet predictions: {missing[:3]}")
    if set(old_by_id) != set(prior_reviews):
        missing = sorted(set(old_by_id) - set(prior_reviews))
        extra = sorted(set(prior_reviews) - set(old_by_id))
        raise RuntimeError(
            f"Prior-review coverage mismatch: missing={len(missing)} extra={len(extra)}"
        )

    byte_equal = 0
    normalized_equal = 0
    empty_raw = 0
    outputs: list[dict[str, Any]] = []
    for old in old_inputs:
        identifier = str(old["id"])
        parakeet_raw = str(predictions[identifier].get("rawText", ""))
        wispr_raw = str(old["raw"])
        byte_equal += parakeet_raw == wispr_raw
        normalized_equal += normalize(parakeet_raw) == normalize(wispr_raw)
        empty_raw += not normalize(parakeet_raw)

        neighbors: dict[str, dict[str, str] | None] = {}
        for side in ("previous", "next"):
            old_neighbor = old["raw_neighbors"].get(side)
            if old_neighbor is None:
                neighbors[side] = None
                continue
            neighbor_id = str(old_neighbor["id"])
            if neighbor_id not in predictions:
                raise RuntimeError(f"Missing Parakeet neighbor: {neighbor_id}")
            neighbors[side] = {
                "id": neighbor_id,
                "raw": str(predictions[neighbor_id].get("rawText", "")),
            }

        output = seal_input(
            {
                "schema_version": "voxol-text-refining-input-v3",
                "snapshot_id": snapshot_id,
                "id": identifier,
                "expected_response_filename": f"{identifier}.json",
                "review_scope": {
                    "campaign": "exact_parakeet_runtime_realignment",
                    "raw_origin": "voxol_parakeet_coreml_swift_production_exact",
                    "final_training_eligible": False,
                    "next_required_gate": "validate_freeze_and_benchmark_qwen_dataset",
                },
                "language": old["language"],
                "source": old["source"],
                "segment": old["segment"],
                "raw": parakeet_raw,
                "wispr_raw_auxiliary": wispr_raw,
                "wispr_edited_candidate": old["wispr_edited_candidate"],
                "raw_neighbors": neighbors,
                "entity_lexicon": old.get("entity_lexicon", []),
                "prior_review_evidence": {
                    "basis_raw_origin": "wispr_flow_raw_auxiliary",
                    "binding": False,
                    "reviews": prior_reviews[identifier],
                },
                "asr_confidence": predictions[identifier].get("confidence"),
                "transport_status": old.get("transport_status", {}),
                "boundary_hints": old.get("boundary_hints", {}),
                "quality_control": {
                    "second_review_required": True,
                    "selection_stratum": old["quality_control"]["selection_stratum"],
                    "selection_flags_are_not_a_quality_verdict": True,
                    "raw_changed_since_prior_review": parakeet_raw != wispr_raw,
                },
            }
        )
        if output["input_sha256"] != input_sha256(output):
            raise RuntimeError(f"Failed to seal input: {identifier}")
        outputs.append(output)

    return outputs, {
        "segmentCount": len(outputs),
        "parakeetWisprByteExactCount": byte_equal,
        "parakeetWisprNormalizedEqualCount": normalized_equal,
        "parakeetEmptyRawCount": empty_raw,
        "requiresFreshAdjudicationCount": len(outputs),
    }


def progress_csv(inputs: list[dict[str, Any]], batch_by_id: dict[str, str]) -> str:
    output = io.StringIO()
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(("id", "batch", "language", "recording_id", "status"))
    for item in sorted(inputs, key=lambda value: str(value["id"])):
        writer.writerow(
            (
                item["id"],
                batch_by_id[str(item["id"])],
                item["language"],
                item["segment"]["recording_id"],
                "pending_fresh_adjudication",
            )
        )
    return output.getvalue()


def write_bulk_archive(
    path: Path,
    package_dir: Path,
    segment_count: int,
    batch_count: int,
) -> None:
    partial = path.with_suffix(".zip.partial")
    with zipfile.ZipFile(
        partial,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        strict_timestamps=False,
    ) as archive:
        add_text(
            archive,
            "README_FIRST.md",
            README.format(segment_count=segment_count, batch_count=batch_count),
        )
        for batch in sorted(
            path
            for path in (package_dir / "batches").glob("*.zip")
            if not path.name.startswith("._")
        ):
            archive.write(batch, f"batches/{batch.name}")
    os.replace(partial, path)


def main() -> int:
    arguments = parse_arguments()
    package_root = arguments.pilot_package_root.resolve()
    predictions_path = arguments.parakeet_predictions.resolve()
    output_root = arguments.output_root.resolve()

    old_inputs = load_jsonl(package_root / "selected-review-manifest.jsonl")
    prediction_rows = load_jsonl(predictions_path)
    predictions = {str(row["id"]): row for row in prediction_rows}
    if len(predictions) != len(prediction_rows):
        raise RuntimeError("Duplicate Parakeet prediction id")
    prior_reviews = load_prior_reviews(package_root)
    inputs, audit = build_inputs(
        old_inputs,
        predictions,
        prior_reviews,
        arguments.snapshot_id,
    )

    package_name = f"{PACKAGE_PREFIX}-{arguments.snapshot_id}"
    package_dir = output_root / package_name
    if package_dir.exists():
        raise RuntimeError(f"Output already exists: {package_dir}")
    package_dir.mkdir(parents=True)
    batches_dir = package_dir / "batches"
    batches_dir.mkdir()

    base_prompt = (
        Path(__file__).with_name("PROMPT_GPT_PRO_TEXT_REFINING_FR_v2.md")
        .read_text(encoding="utf-8")
        .replace(
            "La campagne actuelle est un pilote sur le `raw` auxiliaire de Wispr : même une cible\n"
            "déclarée utilisable devra être réalignée plus tard sur le `raw` Parakeet/Core ML/Swift exact avant\n"
            "d'entrer dans le dataset final.",
            "La campagne actuelle utilise déjà le `raw` Parakeet/Core ML/Swift exact. Une cible\n"
            "validée comme `raw_only` peut franchir ensuite les gates de dataset et de benchmark.",
        )
    )
    prompt = PROMPT_ADDENDUM + base_prompt
    schema_path = package_root / "review-output.schema.v2.json"
    validator_path = package_root / "validate_review_output_v2.py"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    validator = validator_path.read_text(encoding="utf-8")

    batches = assign_batches(inputs, arguments.batch_size, arguments.seed)
    batch_by_id = {
        str(item["id"]): batch_name
        for batch_name, items in batches.items()
        for item in items
    }
    batch_index: list[dict[str, Any]] = []
    for batch_name, items in sorted(batches.items()):
        archive_path = batches_dir / f"{batch_name}.zip"
        write_batch_archive(archive_path, items, prompt, schema, validator)
        batch_index.append(
            {
                "batch": batch_name,
                "archive": f"batches/{archive_path.name}",
                "bytes": archive_path.stat().st_size,
                "language": items[0]["language"],
                "segmentCount": len(items),
                "sha256": sha256_file(archive_path),
            }
        )

    (package_dir / "README_FIRST.md").write_text(
        README.format(segment_count=len(inputs), batch_count=len(batches)),
        encoding="utf-8",
    )
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
    package_index = {
        "schemaVersion": 1,
        "snapshotID": arguments.snapshot_id,
        "audit": audit,
        "parakeetPredictionSHA256": sha256_file(predictions_path),
        "priorReviewCount": len(prior_reviews),
        "batchCount": len(batches),
        "batches": batch_index,
        "trainingEligibleBeforeAdjudication": False,
    }
    (package_dir / "package-index.json").write_text(
        pretty_json(package_index), encoding="utf-8"
    )
    (package_dir / "CHECKSUMS.sha256").write_text(
        checksum_manifest(package_dir), encoding="utf-8"
    )

    bulk_root = package_dir / "bulk-upload"
    bulk_root.mkdir()
    bulk_path = bulk_root / f"{package_name}-16-batches.zip"
    write_bulk_archive(bulk_path, package_dir, len(inputs), len(batches))
    (package_dir / "CHECKSUMS.sha256").write_text(
        checksum_manifest(package_dir), encoding="utf-8"
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
            if path.is_file() and not path.name.startswith("._"):
                archive.write(path, f"{package_name}/{path.relative_to(package_dir).as_posix()}")
    os.replace(partial, master_path)

    print(
        json.dumps(
            {
                **audit,
                "package": str(package_dir),
                "bulkUpload": str(bulk_path),
                "masterArchive": str(master_path),
                "masterArchiveSHA256": sha256_file(master_path),
            },
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
