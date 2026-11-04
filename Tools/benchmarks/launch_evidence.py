"""Re-score frozen public runs and publish an allowlisted, content-free evidence set."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re

import dictation_campaign as c

MODELS = {
    "parakeet": ("Parakeet TDT 0.6B v3", "Core ML", "converted Core ML weights", "CC-BY-4.0"),
    "qwen3-asr-0.6b-8bit": ("Qwen3-ASR 0.6B", "MLX Audio", "8-bit", "Apache-2.0"),
    "whisper-turbo-fp16": ("Whisper large-v3-turbo", "MLX Audio", "FP16", "MIT"),
}
COUNT_KEYS = ("count", "referenceWords", "errors", "substitutions", "deletions", "insertions", "failures", "missing")


def checked_hash(value: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("Expected a SHA-256, not arbitrary source metadata")
    return value


def counts(summary: dict) -> dict:
    out = {}
    for key in COUNT_KEYS:
        value = summary[key]
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError("Invalid count: " + key)
        out[key] = value
    if out["referenceWords"] == 0 or out["count"] == 0:
        raise ValueError("Cannot publish an empty denominator")
    if out["errors"] != out["substitutions"] + out["deletions"] + out["insertions"]:
        raise ValueError("Inconsistent edit counts")
    out["werPercent"] = 100 * out["errors"] / out["referenceWords"]
    return out


def validate_public(manifest: dict) -> list[dict]:
    c.validate(manifest)
    items = c.select(manifest, "public")
    for item in items:
        for reference in item["references"].values():
            if reference["provenance"]["kind"] != "public":
                raise ValueError("Private or AI-derived references cannot enter this public export")
            if reference["provenance"]["dataset"] != "google/fleurs":
                raise ValueError("This exporter is scoped to the pinned FLEURS campaign")
    return items


def export_model(model: str, manifest: dict, run: dict, predictions: list[dict]) -> tuple[dict, list[dict]]:
    items = validate_public(manifest)
    if run["manifestSHA256"] != manifest["manifestSHA256"] or run["split"] != "public":
        raise ValueError("Run and public cohort do not match")
    report = c.score(items, predictions, run, "raw")
    title, runtime, precision, license_name = MODELS[model]
    revision = run.get("revision") or run.get("model", {}).get("revision")
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("Missing pinned model revision")
    result = {
        "id": model, "name": title, "runtime": runtime, "precision": precision,
        "license": license_name, "revision": revision, "category": "measured-asr-component",
        "measurementWindow": "2026-09-08/2026-09-09", "stage": "raw-asr",
        "normalization": c.NORMALIZATION, "cohortSHA256": checked_hash(manifest["manifestSHA256"]),
        "runSHA256": c.digest(run), "runnerSHA256": checked_hash(run["runnerSHA256"]),
        "modelSHA256": checked_hash(run.get("modelSHA256") or run["model"]["sha256"]),
        "binarySHA256": checked_hash(run["binarySHA256"]) if run.get("binarySHA256") else None,
        "counts": counts(report["summary"]),
        "byLanguage": {language: counts(value) for language, value in report["byLanguage"].items()},
        "asrLatencyMilliseconds": report["latencyMilliseconds"],
        "latencyStatistic": "nearest-rank quantiles over clip inference durations",
        "latencyScope": "inference only; excludes loading, correction, capture, network and insertion",
        "coldModelLoadMilliseconds": None, "releaseToVisibleMilliseconds": None,
        "uncertainty95": None,
        "uncertaintyReason": "Speakers are unknown; two locale groups do not support a useful speaker-cluster confidence interval.",
        "configuration": {"languageHint": None, "vocabulary": [], "sampling": "deterministic; pinned run hash"},
        "limitations": ["40 read-speech clips, not a full official test or spontaneous dictation",
                        "no product-to-product claim", "first inference may contain lazy initialization",
                        "raw runs did not record chip model, power or per-process thermal state"],
    }
    by_id = {i["id"]: i for i in items}
    proofs = []
    for row in report["rows"]:
        item = by_id[row["id"]]
        # Stable public identifiers may be released, but never the raw path or text.
        identifier = item["id"]
        if re.fullmatch(r"fleurs-(?:en_us|fr_fr)-test-[0-9a-f]+", identifier) is None:
            raise ValueError("Unexpected public source identifier")
        proofs.append({"model": model, "publicSourceID": identifier,
                       "audioSHA256": checked_hash(item["audio"]["sha256"]),
                       "language": item["language"], "durationSeconds": item["audio"]["durationSeconds"],
                       "referenceWords": row["referenceWords"], "errors": row["errors"],
                       "substitutions": row["substitutions"], "deletions": row["deletions"],
                       "insertions": row["insertions"], "missing": row["missing"], "failure": row["failure"]})
    return result, proofs


def create_export(campaign: Path, manifest_path: Path) -> tuple[dict, dict]:
    manifest = json.loads(manifest_path.read_text())
    items = validate_public(manifest)
    models, proofs, source_files = [], [], []
    for model in MODELS:
        directory = campaign / (model + "-public")
        run = json.loads((directory / "run.json").read_text())
        predictions = c.read_jsonl(directory / "predictions.jsonl")
        exported, rows = export_model(model, manifest, run, predictions)
        stored = json.loads((directory / "raw-report.json").read_text())
        if counts(stored["summary"]) != exported["counts"]:
            raise ValueError("Stored report disagrees with re-scored predictions: " + model)
        models.append(exported)
        proofs.extend(rows)
        source_files.append({"model": model, "runFileSHA256": c.file_digest(directory / "run.json"),
                             "predictionsFileSHA256": c.file_digest(directory / "predictions.jsonl"),
                             "originalReportSHA256": c.file_digest(directory / "raw-report.json")})
    artifact = {
        "schemaVersion": "voxol-public-benchmarks-v1", "auditedOn": "2026-09-10",
        "cohort": {"name": "FLEURS FR/EN, fixed public regression subset", "split": "public",
                   "sourceCount": len(items), "independentSpeakerCount": None,
                   "durationSeconds": sum(i["audio"]["durationSeconds"] for i in items),
                   "referenceWords": models[0]["counts"]["referenceWords"],
                   "sourceLocaleGroups": len({i["sourceGroup"] for i in items}),
                   "manifestSHA256": manifest["manifestSHA256"],
                   "datasetRevision": "70bb2e84b976b7e960aa89f1c648e09c59f894dd", "license": "CC-BY-4.0"},
        "hardware": {"recordedPlatform": "macOS Apple Silicon", "recordedChip": None,
                     "recordedRAMBytes": None, "note": "M4/16 GB is the project reference machine, not a field recorded in these historical runs."},
        "models": models,
        "products": [{"name": name, "category": "not-measured", "releaseToVisibleMilliseconds": None,
                      "finalTextWER": None, "reason": "No comparable full-product run in this export"}
                     for name in ("VoxoL", "Wispr Flow", "Superwhisper", "OpenWhispr")],
        "methodology": "/benchmarks/methodology.v1.md", "evidence": "/benchmarks/evidence.v1.json",
        "csv": "/benchmarks/results.v1.csv",
    }
    evidence = {"schemaVersion": "voxol-public-proof-v1", "manifestSHA256": manifest["manifestSHA256"],
                "normalization": c.NORMALIZATION, "sourceFiles": source_files, "rows": proofs,
                "limitations": "Content-free counts are auditable aggregates, not a substitute for reproducing inference."}
    return artifact, evidence


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--campaign", type=Path, default=root / "outputs/self-quality-2026-09-08")
    parser.add_argument("--manifest", type=Path, default=root / ".build/precision-fleurs-v1/manifest.json")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    artifact, evidence = create_export(args.campaign, args.manifest)
    args.output.mkdir(parents=True, exist_ok=False)
    c.write_json(args.output / "results.v1.json", artifact)
    c.write_json(args.output / "evidence.v1.json", evidence)
    with (args.output / "results.v1.csv").open("x", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=["model", "language", "sources", "words", "errors", "wer_percent", "failures", "missing", "scope", "cohort_sha256"])
        writer.writeheader()
        for model in artifact["models"]:
            for language, value in {"pooled": model["counts"], **model["byLanguage"]}.items():
                writer.writerow({"model": model["name"], "language": language, "sources": value["count"],
                                 "words": value["referenceWords"], "errors": value["errors"],
                                 "wer_percent": value["werPercent"], "failures": value["failures"], "missing": value["missing"],
                                 "scope": "raw-ASR-only", "cohort_sha256": model["cohortSHA256"]})
    print(json.dumps({"models": len(artifact["models"]), "publicSources": artifact["cohort"]["sourceCount"],
                      "publicWords": artifact["cohort"]["referenceWords"], "proofRows": len(evidence["rows"])}))


if __name__ == "__main__":
    main()
