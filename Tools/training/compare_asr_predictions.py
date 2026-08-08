#!/usr/bin/env python3
"""Compare two ASR prediction JSONL files using VoxoL normalization."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from score_asr_predictions import edit_distance, normalize


def load_predictions(path: Path) -> dict[str, dict[str, object]]:
    predictions: dict[str, dict[str, object]] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        identifier = str(row.get("id", ""))
        if not identifier:
            raise ValueError(f"Missing prediction id at {path}:{line_number}")
        if identifier in predictions:
            raise ValueError(f"Duplicate prediction id at {path}:{line_number}")
        predictions[identifier] = row
    if not predictions:
        raise ValueError(f"Empty predictions file: {path}")
    return predictions


def compare(
    reference: dict[str, dict[str, object]],
    candidate: dict[str, dict[str, object]],
) -> dict[str, object]:
    if reference.keys() != candidate.keys():
        missing = sorted(reference.keys() - candidate.keys())
        extra = sorted(candidate.keys() - reference.keys())
        raise ValueError(
            f"Prediction ids differ: {len(missing)} missing, {len(extra)} extra."
        )

    exact_matches = 0
    word_errors = 0
    reference_words = 0
    empty_reference = 0
    empty_candidate = 0
    for identifier in sorted(reference):
        reference_text = normalize(str(reference[identifier].get("rawText", "")))
        candidate_text = normalize(str(candidate[identifier].get("rawText", "")))
        reference_tokens = reference_text.split()
        candidate_tokens = candidate_text.split()
        exact_matches += reference_text == candidate_text
        empty_reference += not reference_text
        empty_candidate += not candidate_text
        word_errors += edit_distance(reference_tokens, candidate_tokens)
        reference_words += len(reference_tokens)

    item_count = len(reference)
    return {
        "schemaVersion": 1,
        "itemCount": item_count,
        "normalizedExactMatchRate": exact_matches / item_count,
        "normalizedDisagreementCount": item_count - exact_matches,
        "referenceToCandidateWER": (
            word_errors / reference_words if reference_words else 0.0
        ),
        "referenceWordCount": reference_words,
        "wordErrorCount": word_errors,
        "emptyReferenceCount": empty_reference,
        "emptyCandidateCount": empty_candidate,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    report = compare(
        load_predictions(arguments.reference),
        load_predictions(arguments.candidate),
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
