#!/usr/bin/env python3
"""Build or check the Qwen human gate without treating teacher approval as human review.

The canonical source contract declares human approval with source='human' and
approved=true. This checks that declaration, not the identity of the reviewer.
Generated, contextual and synthetic sources never contribute to human quotas.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import unicodedata


PARENT_REVISION = "2fc06364715b967f1860aea9cf38778875588b17"
SPLITS = ("train", "validation", "test")
LANGUAGES = ("fr", "en")
INPUTS = (
    "source/source.jsonl", "prepared-source.jsonl", "source/evaluation-reference.jsonl",
    "mlx-data/summary.json", "mlx-data/train.jsonl", "mlx-data/valid.jsonl", "mlx-data/test.jsonl",
)


def read_rows(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def indexed(rows: list[dict], label: str) -> dict[str, dict]:
    result = {}
    for row in rows:
        identifier = row.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in result:
            raise ValueError(f"Missing or duplicate {label} id: {identifier!r}")
        result[identifier] = row
    return result


def source_key(text: str) -> str:
    # Faithful/rewrite copies and cosmetic case/spacing variants count once.
    return " ".join(unicodedata.normalize("NFKC", text).casefold().split())


def evaluate(source_rows: list[dict], prepared_rows: list[dict], summary: dict) -> dict:
    source = indexed(source_rows, "source")
    prepared = indexed(prepared_rows, "prepared")
    if set(source) != set(prepared):
        raise ValueError("Source/prepared coverage mismatch")
    rejected_list = summary["rejected_ids"]
    if not isinstance(rejected_list, list) or any(type(summary[split]) is not int for split in SPLITS):
        raise ValueError("Invalid dataset summary types")
    rejected = set(rejected_list)
    if len(rejected) != len(rejected_list) or not rejected <= set(source):
        raise ValueError("Invalid rejected_ids coverage")
    groups, texts = defaultdict(set), defaultdict(set)
    accepted_counts, human_counts = Counter(), Counter()
    seen_human = set()
    unreviewed_accepted = 0
    for identifier, row in source.items():
        split, language, group = row.get("split"), row.get("language"), row.get("split_group")
        if split not in SPLITS or language not in LANGUAGES or not isinstance(group, str) or not group:
            raise ValueError(f"Invalid split, language or split_group: {identifier}")
        raw, target = row.get("raw_transcript"), row.get("target_text")
        normalized = prepared[identifier].get("normalized_text")
        if any(not isinstance(value, str) or not value.strip() for value in (raw, target, normalized)):
            raise ValueError(f"Missing source/target/normalized text: {identifier}")
        if identifier in rejected:
            continue
        key = source_key(raw)
        groups[group].add(split)
        texts[key].add(split)
        accepted_counts[split] += 1
        # 'approved' alone also occurs on Wispr/LLM examples and is not evidence of human review.
        human = row.get("source") == "human" and row.get("approved") is True
        synthetic_train = row.get("source") == "synthetic-reviewed" and row.get("approved") is True and split == "train"
        if not human and not synthetic_train:
            unreviewed_accepted += 1
        if not human or normalized == target:
            continue
        if key not in seen_human:
            human_counts[(split, language)] += 1
            seen_human.add(key)
    if any(summary[split] != accepted_counts[split] for split in SPLITS):
        raise ValueError("Dataset summary/source split counts mismatch")
    crossings = sum(len(splits) > 1 for splits in groups.values())
    text_crossings = sum(len(splits) > 1 for splits in texts.values())
    train = {language: human_counts[("train", language)] for language in LANGUAGES}
    evaluation = {
        language: sum(human_counts[(split, language)] for split in ("validation", "test"))
        for language in LANGUAGES
    }
    total, heldout = sum(human_counts.values()), sum(evaluation.values())
    reasons = []
    for failed, reason in (
        (unreviewed_accepted > 0, "unreviewed_or_nonhuman_heldout_examples"),
        (crossings > 0, "split_group_crossing"),
        (text_crossings > 0, "raw_text_crossing"),
        (total < 500, "human_corrections_below_500"),
        (heldout < 150, "human_evaluation_below_150"),
        (any(count < 100 for count in train.values()), "human_train_language_below_100"),
        (any(count < 50 for count in evaluation.values()), "human_evaluation_language_below_50"),
    ):
        if failed:
            reasons.append(reason)
    return {
        "schema_version": "voxol-qwen-human-gate-v2",
        "promotion_training_eligible": not reasons,
        "training_parent_revision": PARENT_REVISION,
        "accepted_example_count": sum(accepted_counts.values()),
        "rejected_example_count": len(rejected),
        "unreviewed_accepted_example_count": unreviewed_accepted,
        "split_group_crossing_count": crossings,
        "raw_text_crossing_count": text_crossings,
        "human_reviewed_correction_count": total,
        "human_reviewed_evaluation_count": heldout,
        "human_reviewed_train_by_language": train,
        "human_reviewed_evaluation_by_language": evaluation,
        "blocking_reasons": reasons,
    }


def build(root: Path) -> dict:
    source = read_rows(root / "source/source.jsonl")
    summary = json.loads((root / "mlx-data/summary.json").read_text())
    result = evaluate(source, read_rows(root / "prepared-source.jsonl"), summary)
    references = indexed(read_rows(root / "source/evaluation-reference.jsonl"), "reference")
    if set(references) != {row["id"] for row in source}:
        raise ValueError("Evaluation reference coverage mismatch")
    for row in source:
        reference = references[row["id"]]
        if any(reference.get(field) != row.get(field) for field in ("split", "split_group", "language")):
            raise ValueError(f"Evaluation reference mismatch: {row['id']}")
    for split, filename in (("train", "train"), ("validation", "valid"), ("test", "test")):
        if len(read_rows(root / f"mlx-data/{filename}.jsonl")) != summary[split]:
            raise ValueError(f"MLX dataset row count mismatch: {split}")
    result["input_sha256"] = {
        name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in INPUTS
    }
    result["source_sha256"] = result["input_sha256"]["source/source.jsonl"]
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--check", action="store_true", help="Verify the saved gate and require eligibility; never write.")
    args = parser.parse_args()
    try:
        result = build(args.root)
        gate = args.root / "qwen-mass-gate.json"
        if args.check:
            if json.loads(gate.read_text()) != result:
                raise ValueError("Saved Qwen gate is stale; regenerate preparation")
        else:
            temporary = gate.with_suffix(".json.partial")
            temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
            temporary.replace(gate)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 1 if args.check and not result["promotion_training_eligible"] else 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Qwen human gate failed: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
