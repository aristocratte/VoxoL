#!/usr/bin/env python3
"""Create one comparable summary from VoxoL ASR benchmark reports."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def word_error_rate(section: dict[str, object]) -> float:
    counts = section.get("wordErrors") or {}
    reference_count = int(counts.get("referenceUnitCount") or 0)
    if reference_count == 0:
        return 0.0
    errors = sum(int(counts.get(key) or 0) for key in ("substitutions", "deletions", "insertions"))
    return errors / reference_count


def summarize(name: str, report: dict[str, object]) -> dict[str, object]:
    raw = report["rawVerbatim"]
    final = report["finalClean"]
    return {
        "name": name,
        "item_count": raw["itemCount"],
        "raw_wer": word_error_rate(raw),
        "raw_exact_match_rate": raw["exactMatchRate"],
        "raw_critical_span_error_rate": raw["criticalSpanErrorRate"],
        "final_wer": word_error_rate(final),
        "final_exact_match_rate": final["exactMatchRate"],
        "final_critical_span_error_rate": final["criticalSpanErrorRate"],
    }


def markdown(rows: list[dict[str, object]]) -> str:
    lines = [
        "# Transcriber head-to-head",
        "",
        "| System | Items | Raw WER | Final WER | Raw critical errors | Final critical errors |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append(
            "| {name} | {item_count} | {raw_wer:.2%} | {final_wer:.2%} | "
            "{raw_critical_span_error_rate:.2%} | {final_critical_span_error_rate:.2%} |".format(**row)
        )
    lines.append("")
    return "\n".join(lines)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument(
        "--report",
        action="append",
        required=True,
        metavar="NAME=PATH",
        help="Repeat once per system.",
    )
    result.add_argument("--output", type=Path, required=True)
    result.add_argument("--markdown", type=Path, required=True)
    return result


def main() -> int:
    arguments = parser().parse_args()
    rows = []
    for value in arguments.report:
        if "=" not in value:
            raise SystemExit("--report must use NAME=PATH")
        name, path = value.split("=", 1)
        rows.append(summarize(name, json.loads(Path(path).read_text(encoding="utf-8"))))
    item_counts = {row["item_count"] for row in rows}
    if len(item_counts) != 1:
        raise SystemExit("Reports do not cover the same number of benchmark items")
    rows.sort(key=lambda row: (row["raw_wer"], row["final_wer"], row["name"]))
    result = {"schema_version": 1, "systems": rows}
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    arguments.markdown.parent.mkdir(parents=True, exist_ok=True)
    arguments.markdown.write_text(markdown(rows), encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
