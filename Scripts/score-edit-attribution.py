#!/usr/bin/env python3
"""Count, per processing stage, the words a cleanup fixed and the words it broke.

The source is the deterministic text Qwen received (`normalized`). Each stage — the raw model
`candidate`, the inserted `finalText` and, when present, the v3 gate's `v3Text` — is compared
with the reference. A reference word kept by the source but lost by the stage is broken; a
reference word missing from the source but recovered is fixed. Scores are diagnostics against
whatever reference the suite carries, not human quality judgments. No dictated text is printed
or written: rows hold identifiers and counts only.
"""
import argparse
import collections
import dataclasses
import difflib
import importlib.util
import json
import math
import statistics
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "quality_score", Path(__file__).with_name("score-text-quality-suite.py")
)
_QUALITY = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_QUALITY)
tokens = _QUALITY.tokens

VERDICTS = ("unchanged", "helpful", "harmful", "mixed", "neutral")


@dataclasses.dataclass(frozen=True)
class EditCounts:
    fixed: int
    broken: int
    spurious: int
    removed: int
    verdict: str


def _recovered(words: list[str], reference: list[str]) -> set[int]:
    matcher = difflib.SequenceMatcher(a=reference, b=words, autojunk=False)
    return {block.a + offset for block in matcher.get_matching_blocks() for offset in range(block.size)}


def attribute_edits(source: str, output: str, reference: str) -> EditCounts:
    source_words, output_words, reference_words = tokens(source), tokens(output), tokens(reference)
    source_hits = _recovered(source_words, reference_words)
    output_hits = _recovered(output_words, reference_words)
    fixed = len(output_hits - source_hits)
    broken = len(source_hits - output_hits)
    extra_delta = (len(output_words) - len(output_hits)) - (len(source_words) - len(source_hits))
    spurious, removed = max(0, extra_delta), max(0, -extra_delta)
    good, bad = fixed + removed, broken + spurious
    if output_words == source_words:
        verdict = "unchanged"
    elif good and bad:
        verdict = "mixed"
    elif good:
        verdict = "helpful"
    elif bad:
        verdict = "harmful"
    else:
        verdict = "neutral"
    return EditCounts(fixed, broken, spurious, removed, verdict)


def _percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def score_report(report: dict) -> dict:
    results = report["results"]
    identifiers = [row["id"] for row in results]
    if not results or len(identifiers) != len(set(identifiers)):
        raise ValueError("Report must contain unique, nonempty case results")
    stage_names = ["candidate", "finalText"]
    if any(row.get("v3Text") is not None for row in results):
        stage_names.append("v3Text")
    totals = {name: collections.Counter() for name in stage_names}
    rows = []
    for row in results:
        for field in ("normalized", "finalText", "expected"):
            if not isinstance(row.get(field), str):
                raise ValueError(f"Missing {field} for case {row['id']}")
        source, reference = row["normalized"], row["expected"]
        stages = {}
        for name in stage_names:
            text = row.get(name)
            if name == "candidate" and not text:
                totals[name]["noModelOutputCases"] += 1
                text = source
            elif name == "v3Text" and text is None:
                text = row["finalText"]
            counts = attribute_edits(source, text, reference)
            stages[name] = dataclasses.asdict(counts)
            total = totals[name]
            total[counts.verdict + "Cases"] += 1
            total["fixedTokens"] += counts.fixed
            total["brokenTokens"] += counts.broken
            total["spuriousTokens"] += counts.spurious
            total["removedTokens"] += counts.removed
        rows.append({"id": row["id"], "failure": row.get("failure"), "stages": stages})
    stage_totals = {}
    for name, total in totals.items():
        summary = {verdict + "Cases": total[verdict + "Cases"] for verdict in VERDICTS}
        for key in ("fixedTokens", "brokenTokens", "spuriousTokens", "removedTokens",
                    "noModelOutputCases"):
            summary[key] = total[key]
        stage_totals[name] = summary
    durations = [row["durationMilliseconds"] for row in results]
    return {
        "caseCount": len(results),
        "failedCalls": sum(row.get("failure") is not None for row in results),
        "medianMilliseconds": statistics.median(durations),
        "p95Milliseconds": _percentile(durations, 0.95),
        "stages": stage_totals,
        "rows": rows,
    }


def main(arguments: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args(arguments)
    score = score_report(json.loads(options.report.read_text()))
    options.output.write_text(json.dumps(score, indent=2, sort_keys=True) + "\n")
    for name, summary in score["stages"].items():
        print(f"{name}: helpful={summary['helpfulCases']} harmful={summary['harmfulCases']} "
              f"mixed={summary['mixedCases']} fixed={summary['fixedTokens']} "
              f"broken={summary['brokenTokens']} spurious={summary['spuriousTokens']}")


if __name__ == "__main__":
    main()
