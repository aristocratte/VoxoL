#!/usr/bin/env python3
"""Score NeMo predictions with VoxoL's public ASR normalization contract."""

from __future__ import annotations

import argparse
from collections.abc import Sequence
import hashlib
import json
from pathlib import Path
import statistics
import unicodedata


def normalize(text: str) -> str:
    canonical = unicodedata.normalize("NFC", text).replace("’", "'").replace("‘", "'")
    canonical = canonical.lower()
    output = []
    previous_was_space = True
    for character in canonical:
        keep = character.isalpha() or character.isdecimal() or character == "'"
        if keep:
            output.append(character)
            previous_was_space = False
        elif not previous_was_space:
            output.append(" ")
            previous_was_space = True
    return "".join(output).strip()


def edit_distance(reference: Sequence[object], hypothesis: Sequence[object]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for reference_index, reference_item in enumerate(reference, 1):
        current = [reference_index]
        for hypothesis_index, hypothesis_item in enumerate(hypothesis, 1):
            if reference_item == hypothesis_item:
                current.append(previous[hypothesis_index - 1])
            else:
                current.append(
                    1
                    + min(
                        previous[hypothesis_index - 1],
                        previous[hypothesis_index],
                        current[hypothesis_index - 1],
                    )
                )
        previous = current
    return previous[-1]


def edit_operation_counts(
    reference: Sequence[object],
    hypothesis: Sequence[object],
) -> tuple[int, int, int]:
    distances = [
        [0] * (len(hypothesis) + 1)
        for _ in range(len(reference) + 1)
    ]
    for reference_index in range(len(reference) + 1):
        distances[reference_index][0] = reference_index
    for hypothesis_index in range(len(hypothesis) + 1):
        distances[0][hypothesis_index] = hypothesis_index
    for reference_index, reference_item in enumerate(reference, 1):
        for hypothesis_index, hypothesis_item in enumerate(hypothesis, 1):
            substitution_cost = 0 if reference_item == hypothesis_item else 1
            distances[reference_index][hypothesis_index] = min(
                distances[reference_index - 1][hypothesis_index - 1]
                + substitution_cost,
                distances[reference_index - 1][hypothesis_index] + 1,
                distances[reference_index][hypothesis_index - 1] + 1,
            )

    substitutions = 0
    deletions = 0
    insertions = 0
    reference_index = len(reference)
    hypothesis_index = len(hypothesis)
    while reference_index or hypothesis_index:
        if (
            reference_index
            and hypothesis_index
            and reference[reference_index - 1] == hypothesis[hypothesis_index - 1]
            and distances[reference_index][hypothesis_index]
            == distances[reference_index - 1][hypothesis_index - 1]
        ):
            reference_index -= 1
            hypothesis_index -= 1
        elif (
            reference_index
            and hypothesis_index
            and distances[reference_index][hypothesis_index]
            == distances[reference_index - 1][hypothesis_index - 1] + 1
        ):
            substitutions += 1
            reference_index -= 1
            hypothesis_index -= 1
        elif (
            reference_index
            and distances[reference_index][hypothesis_index]
            == distances[reference_index - 1][hypothesis_index] + 1
        ):
            deletions += 1
            reference_index -= 1
        else:
            insertions += 1
            hypothesis_index -= 1
    return substitutions, deletions, insertions


def score_items(
    items: list[dict[str, object]],
    predictions: dict[str, dict[str, object]],
) -> dict[str, object]:
    macro_wer = 0.0
    word_errors = 0
    reference_words = 0
    character_errors = 0
    reference_characters = 0
    exact_matches = 0
    empty_outputs = 0
    substitutions = 0
    deletions = 0
    insertions = 0
    by_language: dict[str, list[tuple[int, int]]] = {}
    operations_by_language: dict[str, list[int]] = {}
    latencies = []

    for item in items:
        identifier = str(item["id"])
        if identifier not in predictions:
            raise SystemExit(f"Missing prediction: {identifier}")
        reference = normalize(str(item["reference"]["verbatim"]))
        hypothesis = normalize(str(predictions[identifier]["rawText"]))
        reference_word_list = reference.split()
        hypothesis_word_list = hypothesis.split()
        errors = edit_distance(reference_word_list, hypothesis_word_list)
        item_substitutions, item_deletions, item_insertions = edit_operation_counts(
            reference_word_list,
            hypothesis_word_list,
        )
        if item_substitutions + item_deletions + item_insertions != errors:
            raise RuntimeError(f"Inconsistent edit alignment for {identifier}")
        word_count = len(reference_word_list)
        macro_wer += errors / word_count if word_count else 0.0
        word_errors += errors
        reference_words += word_count
        character_errors += edit_distance(list(reference), list(hypothesis))
        reference_characters += len(reference)
        exact_matches += reference == hypothesis
        empty_outputs += not hypothesis
        substitutions += item_substitutions
        deletions += item_deletions
        insertions += item_insertions
        language = str(item["language"])
        by_language.setdefault(language, []).append((errors, word_count))
        language_operations = operations_by_language.setdefault(
            language,
            [0, 0, 0],
        )
        language_operations[0] += item_substitutions
        language_operations[1] += item_deletions
        language_operations[2] += item_insertions
        latency = predictions[identifier].get("inferenceMilliseconds")
        if isinstance(latency, (int, float)) and latency >= 0:
            latencies.append(float(latency))

    count = len(items)
    sorted_latencies = sorted(latencies)

    def percentile(fraction: float) -> float | None:
        if not sorted_latencies:
            return None
        position = fraction * (len(sorted_latencies) - 1)
        lower = int(position)
        upper = min(lower + 1, len(sorted_latencies) - 1)
        weight = position - lower
        return (
            sorted_latencies[lower] * (1 - weight)
            + sorted_latencies[upper] * weight
        )

    return {
        "itemCount": count,
        "macroWER": macro_wer / count if count else 0.0,
        "microWER": word_errors / reference_words if reference_words else 0.0,
        "microCER": (
            character_errors / reference_characters if reference_characters else 0.0
        ),
        "exactMatchRate": exact_matches / count if count else 0.0,
        "emptyOutputCount": empty_outputs,
        "wordErrors": {
            "substitutions": substitutions,
            "deletions": deletions,
            "insertions": insertions,
            "referenceWords": reference_words,
            "deletionRate": deletions / reference_words if reference_words else 0.0,
        },
        "latencyMilliseconds": {
            "sampleCount": len(sorted_latencies),
            "mean": statistics.fmean(sorted_latencies) if sorted_latencies else None,
            "p50": percentile(0.50),
            "p95": percentile(0.95),
            "p99": percentile(0.99),
        },
        "byLanguage": {
            language: {
                "itemCount": len(values),
                "microWER": (
                    sum(errors for errors, _ in values)
                    / sum(words for _, words in values)
                ),
                "wordErrors": {
                    "substitutions": operations_by_language[language][0],
                    "deletions": operations_by_language[language][1],
                    "insertions": operations_by_language[language][2],
                    "referenceWords": sum(words for _, words in values),
                    "deletionRate": (
                        operations_by_language[language][1]
                        / sum(words for _, words in values)
                    ),
                },
            }
            for language, values in sorted(by_language.items())
        },
    }


def load_predictions(path: Path) -> dict[str, dict[str, object]]:
    predictions = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        identifier = str(row["id"])
        if identifier in predictions:
            raise SystemExit(f"Duplicate prediction at {path}:{line_number}")
        predictions[identifier] = row
    return predictions


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    manifest_bytes = arguments.manifest.read_bytes()
    manifest = json.loads(manifest_bytes)
    report = {
        "schemaVersion": 1,
        "benchmarkID": manifest["benchmarkID"],
        "manifestFileSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
        **score_items(list(manifest["items"]), load_predictions(arguments.predictions)),
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
