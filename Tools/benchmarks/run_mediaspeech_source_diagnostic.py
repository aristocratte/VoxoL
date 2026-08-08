#!/usr/bin/env python3
"""Compare official Parakeet with VoxoL Core ML on a diagnostic sample."""

from __future__ import annotations

import argparse
import json
import statistics
import time
import unicodedata
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--coreml-predictions", type=Path, required=True)
    parser.add_argument("--audio-root", type=Path, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--transformers-revision", required=True)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--batch-size", type=int, default=4)
    return parser.parse_args()


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def words(text: str) -> list[str]:
    canonical = (
        unicodedata.normalize("NFC", text)
        .casefold()
        .replace("’", "'")
        .replace("‘", "'")
    )
    normalized = []
    previous_was_space = True
    for character in canonical:
        keep = character.isalpha() or character.isdecimal() or character == "'"
        if keep:
            normalized.append(character)
            previous_was_space = False
        elif not previous_was_space:
            normalized.append(" ")
            previous_was_space = True
    return "".join(normalized).strip().split()


def edit_counts(reference: list[str], hypothesis: list[str]) -> tuple[int, int, int]:
    previous = [(index, 0, 0, index) for index in range(len(hypothesis) + 1)]
    for reference_index, reference_word in enumerate(reference):
        current = [(reference_index + 1, 0, reference_index + 1, 0)]
        for hypothesis_index, hypothesis_word in enumerate(hypothesis):
            if reference_word == hypothesis_word:
                current.append(previous[hypothesis_index])
                continue
            substitution = previous[hypothesis_index]
            deletion = previous[hypothesis_index + 1]
            insertion = current[hypothesis_index]
            current.append(
                min(
                    (
                        (
                            substitution[0] + 1,
                            substitution[1] + 1,
                            substitution[2],
                            substitution[3],
                        ),
                        (
                            deletion[0] + 1,
                            deletion[1],
                            deletion[2] + 1,
                            deletion[3],
                        ),
                        (
                            insertion[0] + 1,
                            insertion[1],
                            insertion[2],
                            insertion[3] + 1,
                        ),
                    ),
                    key=lambda value: value,
                )
            )
        previous = current
    _, substitutions, deletions, insertions = previous[-1]
    return substitutions, deletions, insertions


def score(reference: str, hypothesis: str) -> dict[str, object]:
    reference_words = words(reference)
    hypothesis_words = words(hypothesis)
    substitutions, deletions, insertions = edit_counts(
        reference_words,
        hypothesis_words,
    )
    errors = substitutions + deletions + insertions
    return {
        "wer": errors / max(len(reference_words), 1),
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
        "referenceWordCount": len(reference_words),
        "empty": not hypothesis_words,
    }


def evenly_spaced(rows: list[dict[str, object]], count: int) -> list[dict[str, object]]:
    if len(rows) < count:
        raise ValueError(f"Need {count} rows, found {len(rows)}")
    if count == 1:
        return [rows[0]]
    indices = {
        round(position * (len(rows) - 1) / (count - 1))
        for position in range(count)
    }
    if len(indices) != count:
        raise ValueError("Could not select the requested deterministic sample")
    return [rows[index] for index in sorted(indices)]


def select_sample(
    manifest: dict[str, object],
    coreml_predictions: list[dict[str, object]],
) -> list[dict[str, object]]:
    predictions = {str(row["id"]): row for row in coreml_predictions}
    candidates = []
    for item in manifest["items"]:
        prediction = predictions[str(item["id"])]
        reference = str(item["reference"]["verbatim"])
        raw_text = str(prediction["rawText"])
        candidates.append(
            {
                "id": item["id"],
                "audioPath": item["audioPath"],
                "reference": reference,
                "coreMLText": raw_text,
                "coreMLScore": score(reference, raw_text),
            }
        )

    empty = sorted(
        (row for row in candidates if row["coreMLScore"]["empty"]),
        key=lambda row: str(row["id"]),
    )
    high_error = sorted(
        (
            row
            for row in candidates
            if not row["coreMLScore"]["empty"]
            and float(row["coreMLScore"]["wer"]) >= 0.5
        ),
        key=lambda row: (-float(row["coreMLScore"]["wer"]), str(row["id"])),
    )
    low_error = sorted(
        (
            row
            for row in candidates
            if float(row["coreMLScore"]["wer"]) <= 0.1
        ),
        key=lambda row: (float(row["coreMLScore"]["wer"]), str(row["id"])),
    )
    selected = []
    for bucket, rows, count in (
        ("empty", empty, 20),
        ("high-error", high_error, 20),
        ("low-error", low_error, 10),
    ):
        for row in evenly_spaced(rows, count):
            selected.append({**row, "bucket": bucket})
    return selected


def run_source(
    args: argparse.Namespace,
    selected: list[dict[str, object]],
    output: Path,
) -> list[dict[str, object]]:
    import soundfile
    import torch
    from transformers import AutoModelForTDT, AutoProcessor

    existing = read_jsonl(output) if output.exists() else []
    completed_ids = {str(row["id"]) for row in existing}
    pending = [row for row in selected if str(row["id"]) not in completed_ids]
    if not pending:
        return existing

    processor = AutoProcessor.from_pretrained(
        args.model,
        revision=args.revision,
        cache_dir=args.cache_dir,
    )
    model = AutoModelForTDT.from_pretrained(
        args.model,
        revision=args.revision,
        cache_dir=args.cache_dir,
        dtype=torch.float32,
    ).eval()

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("a", encoding="utf-8") as stream:
        for offset in range(0, len(pending), args.batch_size):
            batch = pending[offset : offset + args.batch_size]
            waveforms = []
            for row in batch:
                waveform, sample_rate = soundfile.read(
                    args.audio_root / str(row["audioPath"]),
                    dtype="float32",
                    always_2d=False,
                )
                if sample_rate != 16_000 or waveform.ndim != 1:
                    raise ValueError(f"Expected mono 16 kHz audio: {row['id']}")
                waveforms.append(waveform)

            started = time.perf_counter()
            inputs = processor(
                waveforms,
                sampling_rate=16_000,
                return_tensors="pt",
                padding=True,
                return_attention_mask=True,
            )
            outputs = model.generate(**inputs, return_dict_in_generate=True)
            decoded = processor.batch_decode(
                outputs.sequences,
                skip_special_tokens=True,
            )
            elapsed_ms = (time.perf_counter() - started) * 1_000 / len(batch)
            for row, transcript in zip(batch, decoded, strict=True):
                prediction = {
                    "id": row["id"],
                    "rawText": transcript,
                    "finalText": transcript,
                    "inferenceMilliseconds": elapsed_ms,
                }
                stream.write(json.dumps(prediction, ensure_ascii=False) + "\n")
                stream.flush()
                existing.append(prediction)
            print(
                f"source={min(offset + len(batch), len(pending))}/{len(pending)}",
                flush=True,
            )
    return existing


def summarize(rows: list[dict[str, object]], field: str) -> dict[str, object]:
    scored = [score(str(row["reference"]), str(row[field])) for row in rows]
    reference_words = sum(int(row["referenceWordCount"]) for row in scored)
    errors = sum(
        int(row["substitutions"]) + int(row["deletions"]) + int(row["insertions"])
        for row in scored
    )
    return {
        "itemCount": len(rows),
        "macroWER": statistics.mean(float(row["wer"]) for row in scored),
        "microWER": errors / max(reference_words, 1),
        "emptyOutputCount": sum(bool(row["empty"]) for row in scored),
        "substitutions": sum(int(row["substitutions"]) for row in scored),
        "deletions": sum(int(row["deletions"]) for row in scored),
        "insertions": sum(int(row["insertions"]) for row in scored),
    }


def build_report(
    args: argparse.Namespace,
    selected: list[dict[str, object]],
    source_predictions: list[dict[str, object]],
) -> dict[str, object]:
    source_by_id = {str(row["id"]): row for row in source_predictions}
    joined = []
    improved = equal = worsened = 0
    for row in selected:
        source_text = str(source_by_id[str(row["id"])]["rawText"])
        source_score = score(str(row["reference"]), source_text)
        delta = float(source_score["wer"]) - float(row["coreMLScore"]["wer"])
        improved += delta < -1e-12
        equal += abs(delta) <= 1e-12
        worsened += delta > 1e-12
        joined.append(
            {
                **row,
                "sourceText": source_text,
                "sourceScore": source_score,
            }
        )

    by_bucket = {}
    for bucket in ("empty", "high-error", "low-error"):
        bucket_rows = [row for row in joined if row["bucket"] == bucket]
        by_bucket[bucket] = {
            "coreML": summarize(bucket_rows, "coreMLText"),
            "source": summarize(bucket_rows, "sourceText"),
        }
    recovered_empty = sum(
        row["coreMLScore"]["empty"] and not row["sourceScore"]["empty"]
        for row in joined
    )
    source_empty_from_nonempty = sum(
        not row["coreMLScore"]["empty"] and row["sourceScore"]["empty"]
        for row in joined
    )
    return {
        "schemaVersion": 1,
        "sampleDesign": {
            "empty": 20,
            "highError": 20,
            "lowError": 10,
            "selectionBiasedTowardCoreMLFailures": True,
        },
        "model": args.model,
        "modelRevision": args.revision,
        "transformersRevision": args.transformers_revision,
        "coreML": summarize(joined, "coreMLText"),
        "source": summarize(joined, "sourceText"),
        "byBucket": by_bucket,
        "pairwise": {
            "sourceImprovedCount": improved,
            "equalCount": equal,
            "sourceWorsenedCount": worsened,
            "coreMLEmptyRecoveredBySource": recovered_empty,
            "sourceEmptyFromCoreMLNonempty": source_empty_from_nonempty,
        },
        "items": joined,
    }


def main() -> None:
    args = parse_args()
    if args.batch_size < 1:
        raise ValueError("--batch-size must be positive")
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    coreml_predictions = read_jsonl(args.coreml_predictions)
    selected = select_sample(manifest, coreml_predictions)
    args.output_root.mkdir(parents=True, exist_ok=True)
    selection_path = args.output_root / "selection.json"
    selection_path.write_text(
        json.dumps(selected, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    source_predictions = run_source(
        args,
        selected,
        args.output_root / "source-predictions.jsonl",
    )
    report = build_report(args, selected, source_predictions)
    report_path = args.output_root / "report.json"
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(report_path)


if __name__ == "__main__":
    main()
