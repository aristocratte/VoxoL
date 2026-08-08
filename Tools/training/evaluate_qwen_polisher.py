#!/usr/bin/env python3
"""Generate and score VoxoL Qwen cleanup outputs on a leakage-safe split."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import time
from typing import Iterable

import mlx.core as mx
from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler

from compact_polisher_edits import apply_compact_edits


SCHEMA_VERSION = "voxol-qwen-polisher-evaluation-v1"
TOKEN_PATTERN = re.compile(r"\bVOXOLP\d+\b")


def read_jsonl(path: Path) -> list[dict[str, object]]:
    rows = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise SystemExit(f"Invalid JSON at {path}:{line_number}") from error
        if not isinstance(row, dict):
            raise SystemExit(f"Expected a JSON object at {path}:{line_number}")
        rows.append(row)
    return rows


def append_jsonl(path: Path, row: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def words(text: str) -> list[str]:
    return re.findall(r"[^\W_]+(?:['’][^\W_]+)*", text.casefold(), re.UNICODE)


def edit_distance(source: list[str], target: list[str]) -> int:
    previous = list(range(len(target) + 1))
    for source_index, source_word in enumerate(source, 1):
        current = [source_index]
        for target_index, target_word in enumerate(target, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[target_index] + 1,
                    previous[target_index - 1] + (source_word != target_word),
                )
            )
        previous = current
    return previous[-1]


def transcript_from_user_message(message: str) -> str:
    for marker in ("DICTATION TO CLEAN:\n", "DICTÉE À CORRIGER:\n"):
        if marker in message:
            return message.rsplit(marker, 1)[1]
    raise ValueError("Training prompt does not contain the production transcript marker")


def resolve_generated_text(
    source: str,
    generated: str,
    output_format: str,
) -> tuple[str, bool]:
    if output_format == "full-text":
        return generated.strip(), True
    try:
        return apply_compact_edits(source, generated.strip()), True
    except (json.JSONDecodeError, ValueError):
        return source, False


def percentile(values: list[float], percentile_value: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, math.ceil(percentile_value * len(ordered)) - 1)
    return ordered[max(0, index)]


def score_rows(rows: list[dict[str, object]]) -> dict[str, object]:
    if not rows:
        return {
            "exampleCount": 0,
            "exactMatchRate": 0.0,
            "inputCopyRate": 0.0,
            "macroWordEditRate": 0.0,
            "microWordEditRate": 0.0,
            "protectedTokenRecall": 1.0,
            "unexpectedWordRate": 0.0,
        }
    exact = 0
    input_copies = 0
    distance_total = 0
    reference_word_total = 0
    macro_rates = 0.0
    protected_total = 0
    protected_retained = 0
    unexpected_total = 0
    output_word_total = 0
    latencies = []
    output_tokens = []
    for row in rows:
        expected = str(row["expected_text"])
        actual = str(row["actual_text"])
        source = str(row["source_text"])
        exact += actual == expected
        input_copies += actual == source
        expected_words = words(expected)
        actual_words = words(actual)
        distance = edit_distance(expected_words, actual_words)
        distance_total += distance
        reference_word_total += len(expected_words)
        macro_rates += distance / max(1, len(expected_words))
        expected_tokens = Counter(TOKEN_PATTERN.findall(expected))
        actual_tokens = Counter(TOKEN_PATTERN.findall(actual))
        protected_total += sum(expected_tokens.values())
        protected_retained += sum(
            count if actual_tokens[token] == count else 0
            for token, count in expected_tokens.items()
        )
        expected_counts = Counter(expected_words)
        for word in actual_words:
            output_word_total += 1
            if expected_counts[word] > 0:
                expected_counts[word] -= 1
            else:
                unexpected_total += 1
        latencies.append(float(row["latency_milliseconds"]))
        output_tokens.append(float(row["output_token_count"]))
    return {
        "exampleCount": len(rows),
        "exactMatchRate": exact / len(rows),
        "inputCopyRate": input_copies / len(rows),
        "latencyMilliseconds": {
            "mean": sum(latencies) / len(latencies),
            "p50": percentile(latencies, 0.50),
            "p95": percentile(latencies, 0.95),
            "p99": percentile(latencies, 0.99),
        },
        "macroWordEditRate": macro_rates / len(rows),
        "microWordEditRate": distance_total / max(1, reference_word_total),
        "outputTokens": {
            "mean": sum(output_tokens) / len(output_tokens),
            "p95": percentile(output_tokens, 0.95),
        },
        "protectedTokenRecall": (
            1.0 if protected_total == 0 else protected_retained / protected_total
        ),
        "unexpectedWordRate": unexpected_total / max(1, output_word_total),
    }


def apply_placeholder_fallback(
    rows: list[dict[str, object]],
) -> tuple[list[dict[str, object]], dict[str, object]]:
    validated = []
    fallback_count = 0
    for row in rows:
        expected_tokens = Counter(TOKEN_PATTERN.findall(str(row["expected_text"])))
        actual_tokens = Counter(TOKEN_PATTERN.findall(str(row["actual_text"])))
        if actual_tokens != expected_tokens:
            fallback_count += 1
            row = {**row, "actual_text": row["source_text"]}
        validated.append(row)
    return validated, {
        "fallbackCount": fallback_count,
        "fallbackRate": fallback_count / max(1, len(rows)),
        "reason": "placeholderMultisetMismatch",
    }


def balanced_limit(
    items: list[tuple[dict[str, object], dict[str, object]]],
    limit: int | None,
) -> list[tuple[dict[str, object], dict[str, object]]]:
    if limit is None or limit >= len(items):
        return items
    buckets: dict[tuple[str, str], list[tuple[dict[str, object], dict[str, object]]]] = (
        defaultdict(list)
    )
    for item in items:
        reference = item[1]
        buckets[(str(reference["language"]), str(reference["case_type"]))].append(item)
    selected = []
    bucket_keys = sorted(buckets)
    while len(selected) < limit and bucket_keys:
        remaining_keys = []
        for key in bucket_keys:
            if buckets[key] and len(selected) < limit:
                selected.append(buckets[key].pop(0))
            if buckets[key]:
                remaining_keys.append(key)
        bucket_keys = remaining_keys
    return selected


def load_items(
    dataset_root: Path,
    references_path: Path,
    split: str,
    limit: int | None,
) -> list[tuple[dict[str, object], dict[str, object]]]:
    filename = "valid.jsonl" if split == "validation" else f"{split}.jsonl"
    records = read_jsonl(dataset_root / filename)
    summary = json.loads((dataset_root / "summary.json").read_text(encoding="utf-8"))
    rejected = set(map(str, summary.get("rejected_ids", [])))
    references = sorted(
        (
            row
            for row in read_jsonl(references_path)
            if row.get("split") == split and str(row.get("id")) not in rejected
        ),
        key=lambda row: str(row["id"]),
    )
    if len(records) != len(references):
        raise SystemExit(
            f"Dataset/reference mismatch for {split}: "
            f"{len(records)} records vs {len(references)} references"
        )
    return balanced_limit(list(zip(records, references, strict=True)), limit)


def evaluate(arguments: argparse.Namespace) -> dict[str, object]:
    items = load_items(
        arguments.dataset,
        arguments.references,
        arguments.split,
        arguments.limit,
    )
    expected_ids = {str(reference["id"]) for _, reference in items}
    completed = {
        str(row["id"]): row
        for row in read_jsonl(arguments.predictions)
        if str(row.get("id")) in expected_ids
    } if arguments.predictions.is_file() else {}

    metadata_path = arguments.predictions.with_suffix(".run.json")
    run_identity = {
        "adapter": str(arguments.adapter.resolve()) if arguments.adapter else None,
        "datasetSHA256": sha256(
            arguments.dataset
            / ("valid.jsonl" if arguments.split == "validation" else f"{arguments.split}.jsonl")
        ),
        "model": str(arguments.model.resolve()),
        "split": arguments.split,
    }
    if arguments.output_format != "full-text":
        run_identity["outputFormat"] = arguments.output_format
    if metadata_path.is_file():
        previous_identity = json.loads(metadata_path.read_text(encoding="utf-8"))
        if previous_identity != run_identity:
            raise SystemExit(
                f"Refusing to mix predictions from another run: {metadata_path}"
            )
    else:
        write_json(metadata_path, run_identity)

    pending = [
        (record, reference)
        for record, reference in items
        if str(reference["id"]) not in completed
    ]
    if pending:
        model, tokenizer = load(
            str(arguments.model),
            adapter_path=str(arguments.adapter) if arguments.adapter else None,
        )
        sampler = make_sampler(temp=0)
        mx.reset_peak_memory()
        for index, (record, reference) in enumerate(pending, 1):
            messages = record["messages"]
            if not isinstance(messages, list) or len(messages) != 3:
                raise SystemExit(f"Invalid chat record for {reference['id']}")
            prompt_messages = messages[:2]
            expected_generation = str(messages[2]["content"])
            source = transcript_from_user_message(str(messages[1]["content"]))
            expected, expected_is_valid = resolve_generated_text(
                source,
                expected_generation,
                arguments.output_format,
            )
            if not expected_is_valid:
                raise SystemExit(f"Invalid compact reference for {reference['id']}")
            prompt = tokenizer.apply_chat_template(
                prompt_messages,
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False,
            )
            expected_token_count = len(
                tokenizer.encode(expected_generation, add_special_tokens=False)
            )
            maximum_tokens = min(384, max(32, expected_token_count + 32))
            started = time.perf_counter()
            generated = generate(
                model,
                tokenizer,
                prompt=prompt,
                max_tokens=maximum_tokens,
                sampler=sampler,
                verbose=False,
            )
            latency_milliseconds = (time.perf_counter() - started) * 1000
            actual, generation_is_valid = resolve_generated_text(
                source,
                generated,
                arguments.output_format,
            )
            prediction = {
                "actual_text": actual,
                "case_type": reference["case_type"],
                "expected_text": expected,
                "id": reference["id"],
                "language": reference["language"],
                "latency_milliseconds": round(latency_milliseconds, 3),
                "generation_valid": generation_is_valid,
                "output_token_count": len(
                    tokenizer.encode(generated, add_special_tokens=False)
                ),
                "source_text": source,
            }
            append_jsonl(arguments.predictions, prediction)
            completed[str(reference["id"])] = prediction
            if index == 1 or index % arguments.progress_every == 0:
                print(
                    f"[{len(completed)}/{len(items)}] "
                    f"{reference['language']}/{reference['case_type']} "
                    f"{latency_milliseconds:.0f} ms",
                    flush=True,
                )

    predictions = [completed[identifier] for identifier in sorted(expected_ids)]
    slices = {}
    for language in ("en", "fr"):
        for case_type in ("edit", "noop"):
            key = f"{language}-{case_type}"
            slices[key] = score_rows(
                [
                    row
                    for row in predictions
                    if row["language"] == language and row["case_type"] == case_type
                ]
            )
    placeholder_validated, placeholder_validation = apply_placeholder_fallback(
        predictions
    )
    report = {
        "adapter": str(arguments.adapter.resolve()) if arguments.adapter else None,
        "completedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "metrics": score_rows(predictions),
        "model": str(arguments.model.resolve()),
        "outputFormat": arguments.output_format,
        "peakMLXMemoryBytes": mx.get_peak_memory(),
        "placeholderValidatedMetrics": score_rows(placeholder_validated),
        "placeholderValidation": placeholder_validation,
        "predictionFileSHA256": sha256(arguments.predictions),
        "schemaVersion": SCHEMA_VERSION,
        "slices": slices,
        "split": arguments.split,
    }
    invalid_generation_count = sum(
        not bool(row.get("generation_valid", True)) for row in predictions
    )
    report["generationValidation"] = {
        "fallbackCount": invalid_generation_count,
        "fallbackRate": invalid_generation_count / max(1, len(predictions)),
    }
    write_json(arguments.report, report)
    return report


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--adapter", type=Path)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--references", type=Path, required=True)
    parser.add_argument("--split", choices=("validation", "test"), default="test")
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--progress-every", type=int, default=10)
    parser.add_argument(
        "--output-format",
        choices=("full-text", "compact-edits"),
        default="full-text",
    )
    return parser.parse_args()


def main() -> None:
    report = evaluate(parse_arguments())
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
