#!/usr/bin/env python3
"""Audit duplicate, split and target-length risks in a diagnostic JSONL corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path


ROLE = "diagnostic-ai-labeled-v1"
GATE_LANGUAGES = {"fr", "en"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=Path("Data/corpus/human-v1.jsonl"))
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def assigned_split(identifier: str) -> str:
    bucket = int.from_bytes(hashlib.sha256(identifier.encode()).digest()[:8], "big") % 100
    if bucket < 80:
        return "train"
    if bucket < 90:
        return "validation"
    return "test"


def grouped_ids(rows: list[dict[str, object]], key) -> list[list[str]]:
    groups: dict[str, list[str]] = defaultdict(list)
    for row in rows:
        groups[str(key(row))].append(str(row["id"]))
    return sorted(
        (sorted(ids) for ids in groups.values() if len(ids) > 1),
        key=lambda ids: (ids[0], len(ids)),
    )


def build_audit(rows: list[dict[str, object]], corpus_sha256: str) -> dict[str, object]:
    group_splits: dict[str, set[str]] = defaultdict(set)
    naive_group_splits: dict[str, set[str]] = defaultdict(set)
    split_counts: Counter[str] = Counter()
    for row in rows:
        group = str(row.get("split_group") or row["id"])
        split = assigned_split(group)
        split_counts[split] += 1
        group_splits[group].add(split)
        naive_group_splits[group].add(assigned_split(str(row["id"])))

    suspicious = []
    for row in rows:
        raw_words = str(row["raw_transcript"]).split()
        target_words = str(row["target_text"]).split()
        ratio = len(target_words) / max(len(raw_words), 1)
        if len(raw_words) >= 8 and (len(target_words) <= 3 or ratio < 0.45):
            suspicious.append(
                {
                    "id": row["id"],
                    "rawWords": len(raw_words),
                    "targetWords": len(target_words),
                    "targetToRawRatio": round(ratio, 4),
                }
            )

    ids = [str(row["id"]) for row in rows]
    excluded = sorted(
        str(row["id"]) for row in rows if row.get("language") not in GATE_LANGUAGES
    )
    return {
        "schemaVersion": 1,
        "role": ROLE,
        "promotionEligible": False,
        "corpusSHA256": corpus_sha256,
        "rowCount": len(rows),
        "independentSourceCount": len(
            {str(row.get("split_group") or row["raw_transcript"]) for row in rows}
        ),
        "languageCounts": dict(sorted(Counter(str(row.get("language")) for row in rows).items())),
        "modeCounts": dict(sorted(Counter(str(row.get("mode")) for row in rows).items())),
        "frEnGate": {
            "includedRowCount": len(rows) - len(excluded),
            "excludedRowCount": len(excluded),
            "excludedIDs": excluded,
        },
        "duplicates": {
            "duplicateIDs": sorted(
                identifier for identifier, count in Counter(ids).items() if count > 1
            ),
            "exactPairGroups": grouped_ids(
                rows,
                lambda row: (
                    row.get("language"),
                    row.get("raw_transcript"),
                    row.get("target_text"),
                ),
            ),
            "sharedRawTranscriptGroups": grouped_ids(
                rows, lambda row: row.get("raw_transcript")
            ),
        },
        "groupAwareSplits": {
            "counts": dict(sorted(split_counts.items())),
            "leakingSplitGroups": sorted(
                group for group, splits in group_splits.items() if len(splits) > 1
            ),
        },
        "naiveRowIDSplitWouldLeakGroups": sorted(
            group for group, splits in naive_group_splits.items() if len(splits) > 1
        ),
        "suspiciouslyShortTargets": suspicious,
    }


def main() -> None:
    args = parse_args()
    payload = args.corpus.read_bytes()
    rows = [json.loads(line) for line in payload.decode("utf-8").splitlines() if line.strip()]
    audit = build_audit(rows, hashlib.sha256(payload).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(audit, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(args.output)


if __name__ == "__main__":
    main()
