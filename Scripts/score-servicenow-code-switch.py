#!/usr/bin/env python3
"""Score VoxoL predictions on the public ServiceNow FR/EN code-switch suite."""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import re
import unicodedata


AU_HARNESS_REVISION = "e07548bafd94ef816c9108c3983fc2f3c2356d55"
PUBLISHED_RESULTS_URL = "https://huggingface.co/blog/ServiceNow-AI/code-switching"
PUBLISHED_WER = {
    "en_fr": {
        "ElevenLabs Scribe V2": 0.031,
        "AssemblyAI Universal 3-Pro": 0.035,
        "Google Gemini 3 Flash": 0.040,
        "Deepgram Nova-3 Multilang": 0.052,
        "Mistral Voxtral Small 24B-2507": 0.060,
        "NVIDIA Parakeet TDT 0.6B v3": 0.075,
        "OpenAI Whisper Large v3 Turbo": 0.434,
    },
    "en_fr_ca": {
        "ElevenLabs Scribe V2": 0.041,
        "AssemblyAI Universal 3-Pro": 0.043,
        "Google Gemini 3 Flash": 0.055,
        "Mistral Voxtral Small 24B-2507": 0.059,
        "Deepgram Nova-3 Multilang": 0.072,
        "NVIDIA Parakeet TDT 0.6B v3": 0.099,
        "OpenAI Whisper Large v3 Turbo": 0.535,
    },
}


def load_json_lines(path: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise RuntimeError(f"Invalid JSON at {path}:{line_number}") from error
            if not isinstance(value, dict):
                raise RuntimeError(f"Expected an object at {path}:{line_number}")
            rows.append(value)
    return rows


def normalize_au_basic(text: str) -> str:
    """Mirror AU-Harness BasicTextNormalizer for its `en/fr` task language."""
    text = unicodedata.normalize("NFC", text)
    text = text.lower()
    text = re.sub(r"[<\[][^>\]]*[>\]]", "", text)
    text = re.sub(r"\(([^)]+?)\)", "", text)
    text = unicodedata.normalize("NFKC", text)
    text = "".join(
        " " if unicodedata.category(character)[0] in "MSP" else character
        for character in text
    )
    return re.sub(r"\s+", " ", text).strip()


def edit_alignment(reference: list[str], candidate: list[str]) -> list[tuple[str, int | None]]:
    """Return minimal word edits and the reference index each edit belongs to."""
    rows = len(reference) + 1
    columns = len(candidate) + 1
    costs = [[0] * columns for _ in range(rows)]
    matches = [[0] * columns for _ in range(rows)]
    steps: list[list[str | None]] = [[None] * columns for _ in range(rows)]
    for row in range(1, rows):
        costs[row][0] = row
        steps[row][0] = "delete"
    for column in range(1, columns):
        costs[0][column] = column
        steps[0][column] = "insert"
    for row in range(1, rows):
        for column in range(1, columns):
            if reference[row - 1] == candidate[column - 1]:
                costs[row][column] = costs[row - 1][column - 1]
                matches[row][column] = matches[row - 1][column - 1] + 1
                steps[row][column] = "equal"
                continue
            options = [
                (
                    costs[row - 1][column - 1] + 1,
                    -matches[row - 1][column - 1],
                    0,
                    "substitute",
                    matches[row - 1][column - 1],
                ),
                (
                    costs[row - 1][column] + 1,
                    -matches[row - 1][column],
                    1,
                    "delete",
                    matches[row - 1][column],
                ),
                (
                    costs[row][column - 1] + 1,
                    -matches[row][column - 1],
                    2,
                    "insert",
                    matches[row][column - 1],
                ),
            ]
            cost, _, _, step, match_count = min(options)
            costs[row][column] = cost
            matches[row][column] = match_count
            steps[row][column] = step

    alignment: list[tuple[str, int | None]] = []
    row, column = len(reference), len(candidate)
    while row or column:
        step = steps[row][column]
        if step == "equal" or step == "substitute":
            alignment.append((str(step), row - 1))
            row -= 1
            column -= 1
        elif step == "delete":
            alignment.append((step, row - 1))
            row -= 1
        elif step == "insert":
            alignment.append((step, None))
            column -= 1
        else:
            raise RuntimeError("Could not reconstruct edit alignment")
    alignment.reverse()
    return alignment


def reference_language_labels(
    words: list[object],
    word_languages: list[object],
    reference_tokens: list[str],
) -> tuple[list[str], bool]:
    """Map dataset word labels through the full-reference normalizer.

    AU's basic normalizer removes balanced parenthetical spans from the full
    sentence. Normalizing each dataset word separately would retain those
    words and shift every language label that follows them, so align the
    expanded word sequence back onto the actual normalized reference.
    """
    expanded_tokens: list[str] = []
    expanded_labels: list[str] = []
    for word, label in zip(words, word_languages):
        normalized = normalize_au_basic(str(word)).split()
        expanded_tokens.extend(normalized)
        expanded_labels.extend([str(label).upper()] * len(normalized))
    adjusted = expanded_tokens != reference_tokens
    labels: list[str] = []
    for operation, source_index in edit_alignment(expanded_tokens, reference_tokens):
        if operation == "insert":
            raise RuntimeError(
                "A normalized reference token could not be mapped to a dataset word"
            )
        if operation in {"equal", "substitute"}:
            if source_index is None:
                raise RuntimeError("Language-label alignment lost its source index")
            labels.append(expanded_labels[source_index])
    if len(labels) != len(reference_tokens):
        raise RuntimeError(
            f"Language-label alignment produced {len(labels)} labels for "
            f"{len(reference_tokens)} reference tokens"
        )
    return labels, adjusted


def percentile(values: list[float], quantile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def cmi_bucket(value: float) -> str:
    if value < 25:
        return "low"
    if value < 40:
        return "medium"
    return "high"


def switch_bucket(value: int) -> str:
    if value <= 2:
        return "0-2"
    if value <= 5:
        return "3-5"
    return "6+"


def score(
    manifest: dict[str, object],
    metadata_rows: list[dict[str, object]],
    prediction_rows: list[dict[str, object]],
    prediction_field: str,
) -> tuple[dict[str, object], list[dict[str, object]]]:
    items = {str(item["id"]): item for item in manifest.get("items", [])}
    metadata = {str(row["id"]): row for row in metadata_rows}
    predictions = {str(row["id"]): row for row in prediction_rows}
    if set(predictions) - set(items):
        raise RuntimeError("Predictions contain IDs outside the frozen manifest")
    missing = set(items) - set(predictions)
    if missing:
        raise RuntimeError(f"Missing predictions for {len(missing)} manifest items")
    if set(items) != set(metadata):
        raise RuntimeError("Code-switch metadata does not cover the manifest exactly")

    aggregate = defaultdict(int)
    language_stats: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    configuration_stats: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    cmi_stats: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    switch_stats: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    sample_wers: list[float] = []
    latencies: list[float] = []
    records: list[dict[str, object]] = []
    adjusted_language_label_items = 0

    for identifier in sorted(items):
        item = items[identifier]
        extra = metadata[identifier]
        prediction = predictions[identifier]
        candidate = str(prediction.get(prediction_field) or "")
        reference = str(item["reference"]["verbatim"])
        reference_tokens = normalize_au_basic(reference).split()
        candidate_tokens = normalize_au_basic(candidate).split()
        alignment = edit_alignment(reference_tokens, candidate_tokens)
        counts = defaultdict(int)
        for operation, _ in alignment:
            counts[operation] += 1
        errors = counts["substitute"] + counts["delete"] + counts["insert"]
        reference_count = len(reference_tokens)
        sample_wer = errors / reference_count if reference_count else 0.0
        sample_wers.append(sample_wer)
        for key in ("substitute", "delete", "insert"):
            aggregate[key] += counts[key]
        aggregate["reference"] += reference_count
        aggregate["items"] += 1

        labels, labels_adjusted = reference_language_labels(
            list(extra["words"]),
            list(extra["wordLanguages"]),
            reference_tokens,
        )
        adjusted_language_label_items += int(labels_adjusted)
        for operation, reference_index in alignment:
            if reference_index is None:
                continue
            label = labels[reference_index]
            language_stats[label]["reference"] += 1
            if operation != "equal":
                language_stats[label]["errors"] += 1

        configuration = str(extra["configuration"])
        cmi_group = cmi_bucket(float(extra["codeMixingIndex"]))
        switch_group = switch_bucket(int(extra["switchCount"]))
        for bucket in (
            configuration_stats[configuration],
            cmi_stats[cmi_group],
            switch_stats[switch_group],
        ):
            bucket["errors"] += errors
            bucket["reference"] += reference_count
            bucket["items"] += 1
        latency = prediction.get("inferenceMilliseconds")
        if isinstance(latency, (int, float)):
            latencies.append(float(latency))
        records.append(
            {
                "candidate": candidate,
                "codeMixingIndex": extra["codeMixingIndex"],
                "configuration": configuration,
                "deletions": counts["delete"],
                "id": identifier,
                "insertions": counts["insert"],
                "reference": reference,
                "referenceWords": reference_count,
                "substitutions": counts["substitute"],
                "switchCount": extra["switchCount"],
                "wer": sample_wer,
            }
        )

    def render_buckets(values: dict[str, dict[str, int]]) -> dict[str, object]:
        return {
            key: {
                "errorWords": row["errors"],
                "itemCount": row["items"],
                "referenceWords": row["reference"],
                "wer": row["errors"] / row["reference"] if row["reference"] else 0.0,
            }
            for key, row in sorted(values.items())
        }

    overall_errors = aggregate["substitute"] + aggregate["delete"] + aggregate["insert"]
    report = {
        "benchmarkID": manifest.get("benchmarkID"),
        "comparability": {
            "auHarnessRevision": AU_HARNESS_REVISION,
            "deterministicMetrics": [
                "overall micro WER",
                "average sample WER",
                "reference-attributed per-language error rate",
                "CMI and switch-count slices",
            ],
            "excludedMetrics": [
                "AU-Harness LLM-judge semantic error rate",
                "AU-Harness LLM-extracted answer error rate",
            ],
            "normalization": (
                "Independent mirror of AU-Harness normalize_text for the en/fr task: "
                "the task falls back to BasicTextNormalizer, then lowercases, removes "
                "punctuation and strips; no semantic judge is used."
            ),
        },
        "configurationSlices": render_buckets(configuration_stats),
        "cmiSlices": render_buckets(cmi_stats),
        "inferenceLatencyMilliseconds": {
            "count": len(latencies),
            "p50": percentile(latencies, 0.50),
            "p95": percentile(latencies, 0.95),
        },
        "itemCount": aggregate["items"],
        "languageReferenceErrorRate": {
            language: {
                "errorWords": row["errors"],
                "referenceWords": row["reference"],
                "rate": row["errors"] / row["reference"] if row["reference"] else 0.0,
            }
            for language, row in sorted(language_stats.items())
        },
        "languageLabelAlignmentAdjustedItemCount": adjusted_language_label_items,
        "macroWER": sum(sample_wers) / len(sample_wers) if sample_wers else 0.0,
        "microWER": overall_errors / aggregate["reference"] if aggregate["reference"] else 0.0,
        "predictionField": prediction_field,
        "publishedComparison": {
            "publicationDate": "2026-06-09",
            "source": PUBLISHED_RESULTS_URL,
            "valuesAreIndependentRuns": True,
            "wer": PUBLISHED_WER,
        },
        "schemaVersion": 1,
        "switchCountSlices": render_buckets(switch_stats),
        "wordErrors": {
            "deletions": aggregate["delete"],
            "insertions": aggregate["insert"],
            "referenceWords": aggregate["reference"],
            "substitutions": aggregate["substitute"],
        },
    }
    return report, records


def markdown(report: dict[str, object]) -> str:
    lines = [
        "# ServiceNow FR/EN code-switch benchmark",
        "",
        f"- Benchmark: `{report['benchmarkID']}`",
        f"- Clips: {report['itemCount']}",
        f"- Micro WER: {report['microWER'] * 100:.2f}%",
        f"- Macro WER: {report['macroWER'] * 100:.2f}%",
        "- Protocol: deterministic AU-Harness basic-normalization mirror; raw ASR output.",
        "- Excluded: semantic/AER judge scores, because they require separate model calls.",
        "",
        "## Configuration slices",
        "",
        "| Configuration | Clips | WER |",
        "|---|---:|---:|",
    ]
    for name, row in report["configurationSlices"].items():
        lines.append(f"| {name} | {row['itemCount']} | {row['wer'] * 100:.2f}% |")
    local_by_configuration = {
        name: row["wer"] for name, row in report["configurationSlices"].items()
    }
    published = report["publishedComparison"]["wer"]
    system_names = list(PUBLISHED_WER["en_fr"])
    lines.extend(
        [
            "",
            "## Comparison with ServiceNow's published runs",
            "",
            "These are independent auto-language runs on the same published dataset "
            "configurations, not simultaneous measurements. Only deterministic overall "
            "WER is compared; SWER and AER are not claimed for VoxoL.",
            "",
            "| System | EN/FR WER | EN/FR-CA WER |",
            "|---|---:|---:|",
            "| VoxoL local Core ML | "
            f"{local_by_configuration.get('en_fr', 0) * 100:.2f}% | "
            f"{local_by_configuration.get('en_fr_ca', 0) * 100:.2f}% |",
        ]
    )
    for system in system_names:
        lines.append(
            f"| {system} | {published['en_fr'][system] * 100:.2f}% | "
            f"{published['en_fr_ca'][system] * 100:.2f}% |"
        )
    lines.extend(
        [
            "",
            "## Reference-attributed language errors",
            "",
            "Insertions contribute to overall WER but are not assigned to a language.",
            "",
            "| Language | Reference words | Error rate |",
            "|---|---:|---:|",
        ]
    )
    for name, row in report["languageReferenceErrorRate"].items():
        lines.append(f"| {name} | {row['referenceWords']} | {row['rate'] * 100:.2f}% |")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--records-output", type=Path)
    parser.add_argument("--markdown-output", type=Path)
    parser.add_argument("--prediction-field", choices=("rawText", "finalText"), default="rawText")
    arguments = parser.parse_args()
    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    report, records = score(
        manifest,
        load_json_lines(arguments.metadata),
        load_json_lines(arguments.predictions),
        arguments.prediction_field,
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    if arguments.records_output:
        arguments.records_output.write_text(
            "".join(
                json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
                for row in records
            ),
            encoding="utf-8",
        )
    if arguments.markdown_output:
        arguments.markdown_output.write_text(markdown(report), encoding="utf-8")
    print(arguments.output)


if __name__ == "__main__":
    main()
