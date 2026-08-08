#!/usr/bin/env python3

import argparse
import json
import re
import statistics
import time
from pathlib import Path

from transformers import pipeline


REMOVABLE_PUNCTUATION = re.compile(r"(?<!\d)[.,;:!?](?!\d)")
TRAILING_PUNCTUATION = re.compile(r"""[.,;:!?-]["'”’»)\]}]*$""")
TRAILING_CLOSERS = re.compile(r"""^(.*?)(["'”’»)\]}]+)$""")


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run FullStop as an insertion-only punctuation benchmark."
    )
    parser.add_argument("--suite", required=True, type=Path)
    parser.add_argument("--baseline-polisher-output", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--device", default="mps")
    return parser.parse_args()


def chunks(words: list[str], size: int = 230, overlap: int = 5):
    stride = size - overlap
    for start in range(0, len(words), stride):
        yield words[start : start + size]


def predict_labels(classifier, words: list[str]) -> list[str]:
    if not words:
        return []

    batches = list(chunks(words))
    if len(batches) > 1 and len(batches[-1]) <= 5:
        batches.pop()

    labels: list[str] = []
    for batch_index, batch in enumerate(batches):
        overlap = 0 if batch_index == len(batches) - 1 else 5
        text = " ".join(batch)
        predictions = classifier(text)
        if not predictions or predictions[-1]["end"] != len(text):
            raise RuntimeError("FullStop tokenizer clipped a benchmark segment")

        character_index = 0
        prediction_index = 0
        for word in batch[: len(batch) - overlap]:
            character_index += len(word) + 1
            label = "0"
            while (
                prediction_index < len(predictions)
                and character_index > predictions[prediction_index]["end"]
            ):
                label = predictions[prediction_index]["entity"]
                prediction_index += 1
            labels.append(label)

    if len(labels) != len(words):
        raise RuntimeError(
            f"FullStop returned {len(labels)} labels for {len(words)} words"
        )
    return labels


def insert_punctuation(classifier, text: str) -> str:
    parts = re.split(r"(\s+)", text)
    clean_words: list[str] = []
    part_indexes: list[int] = []
    for index, part in enumerate(parts):
        if not part or part.isspace():
            continue
        clean = REMOVABLE_PUNCTUATION.sub("", part)
        if clean:
            clean_words.append(clean)
            part_indexes.append(index)

    labels = predict_labels(classifier, clean_words)
    for part_index, label in zip(part_indexes, labels):
        if label not in ".,?-:" or label == "0":
            continue
        token = parts[part_index]
        if TRAILING_PUNCTUATION.search(token):
            continue
        closers = TRAILING_CLOSERS.match(token)
        if closers:
            parts[part_index] = f"{closers.group(1)}{label}{closers.group(2)}"
        else:
            parts[part_index] = f"{token}{label}"
    return "".join(parts)


def percentile(values: list[int], fraction: float) -> int:
    ordered = sorted(values)
    index = min(len(ordered) - 1, int((len(ordered) - 1) * fraction))
    return ordered[index]


def main() -> None:
    args = arguments()
    suite = json.loads(args.suite.read_text())
    baseline = json.loads(args.baseline_polisher_output.read_text())
    baseline_by_id = {result["id"]: result for result in baseline["results"]}

    classifier = pipeline(
        "token-classification",
        model=str(args.model),
        tokenizer=str(args.model),
        aggregation_strategy="none",
        device=args.device,
    )
    warmup_start = time.perf_counter_ns()
    insert_punctuation(classifier, "Bonjour ceci est un test simple")
    warmup_milliseconds = int(
        (time.perf_counter_ns() - warmup_start) / 1_000_000
    )

    results = []
    for item in suite["cases"]:
        baseline_result = baseline_by_id[item["id"]]
        normalized = baseline_result["normalized"]
        started = time.perf_counter_ns()
        candidate = insert_punctuation(classifier, normalized)
        duration_milliseconds = int(
            (time.perf_counter_ns() - started) / 1_000_000
        )
        results.append(
            {
                "id": item["id"],
                "candidate": candidate,
                "normalized": normalized,
                "finalText": candidate,
                "accepted": candidate != normalized,
                "rejection": None,
                "failure": None,
                "durationMilliseconds": duration_milliseconds,
                "promptTokens": len(normalized.split()),
                "outputTokens": 0,
                "processingLanguage": item["language"],
                "profile": item["profile"],
                "protectedTokenCount": baseline_result["protectedTokenCount"],
            }
        )

    durations = [result["durationMilliseconds"] for result in results]
    output = {
        "schemaVersion": 1,
        "modelPath": args.model.name,
        "promptVersion": "fullstop-insertion-only-v1",
        "caseCount": len(results),
        "acceptedCount": sum(result["accepted"] for result in results),
        "exactMatchCount": 0,
        "pipelineExactMatchCount": 0,
        "warmupDurationMilliseconds": warmup_milliseconds,
        "meanDurationMilliseconds": int(statistics.mean(durations)),
        "p50DurationMilliseconds": percentile(durations, 0.50),
        "p95DurationMilliseconds": percentile(durations, 0.95),
        "results": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary_output = args.output.with_suffix(f"{args.output.suffix}.tmp")
    temporary_output.write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n"
    )
    temporary_output.replace(args.output)


if __name__ == "__main__":
    main()
