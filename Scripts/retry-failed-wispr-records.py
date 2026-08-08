#!/usr/bin/env python3
"""Delete Wispr records whose request never completed, so they are retried.

A chunk with HTTP status `000` is curl reporting that the connection failed —
no response ever arrived. Scoring that as an empty transcript would blame the
recogniser for a dropped socket, and on a benchmark meant to be published that
is not a defensible number.

The collector treats any directory containing a record.json as finished, so a
failed request is never retried on its own. Removing those directories makes
the next run request them again. Records that did complete are untouched, so
nothing already paid for is re-requested.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sys


def failed(record: Path) -> bool:
    try:
        payload = json.loads(record.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return True
    chunks = payload.get("results") or []
    if not chunks:
        return True
    # An empty transcript behind a clean 200 is a real result — Wispr heard
    # nothing worth transcribing — and is kept. Only a request that never
    # landed is retried.
    return any(chunk.get("raw_http_status") != "200" for chunk in chunks)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Delete the failed records. Without it, only report.",
    )
    parser.add_argument(
        "--benchmark",
        help="Limit to one benchmark directory name, such as fleurs-it.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Print only the number removed, for use inside the runner.",
    )
    arguments = parser.parse_args()

    pattern = f"wispr/{arguments.benchmark or '*'}/dataset/records/*/record.json"
    total = removed = 0
    per_benchmark: dict[str, int] = {}
    for record in sorted(arguments.root.glob(pattern)):
        total += 1
        if not failed(record):
            continue
        benchmark = record.parents[3].name
        per_benchmark[benchmark] = per_benchmark.get(benchmark, 0) + 1
        removed += 1
        if arguments.apply:
            shutil.rmtree(record.parent, ignore_errors=True)

    if arguments.quiet:
        print(removed)
    else:
        for benchmark, count in sorted(per_benchmark.items()):
            print(f"  {benchmark:20s} {count} failed request(s)")
        verb = "removed" if arguments.apply else "would remove"
        print(f"{verb} {removed} of {total} records")

    if arguments.apply:
        # Their scores were computed from incomplete data.
        for benchmark in per_benchmark:
            directory = arguments.root / "benchmarks" / benchmark
            for stale in (
                "wispr-report.json",
                "wispr-items.jsonl",
                "wispr-predictions.jsonl",
                "wispr-coverage.json",
            ):
                (directory / stale).unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
