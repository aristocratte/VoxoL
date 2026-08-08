#!/usr/bin/env python3
"""Characterise where VoxoL's ASR and the Wispr teacher disagree.

Distilling a teacher converges toward it. The only way past is a label that is
better than the teacher on the chunks where the teacher is wrong, and the only
affordable way to find those chunks is to look at where the student already
disagrees. Agreement is close to free gold: two independent systems producing
the same words are rarely both wrong the same way. Disagreement is where every
remaining point of word error lives, and it is small enough to adjudicate.

This tool partitions the corpus into those two sets and describes the
disagreements, so an adjudication budget can be aimed rather than spread.

Usage:
    ./analyze_teacher_disagreement.py \\
        --teacher-manifest <polisher-manifest.jsonl> \\
        --predictions <runtime-predictions.jsonl> \\
        --report <report.json> \\
        [--queue <queue.jsonl>] [--queue-limit 2000]
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys
import unicodedata


# A disagreement confined to these is a normalisation artefact, not an error
# either system needs adjudicating.
PUNCTUATION = re.compile(r"[^\w\s']", re.UNICODE)
DIGIT = re.compile(r"\d")


def read_jsonl(path: Path) -> list[dict[str, object]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


def normalize(text: str) -> str:
    folded = unicodedata.normalize("NFC", str(text or "")).casefold()
    return " ".join(PUNCTUATION.sub(" ", folded).split())


def word_alignment(reference: list[str], hypothesis: list[str]) -> list[tuple]:
    """Levenshtein backtrace over words, as (operation, reference, hypothesis)."""
    rows, columns = len(reference) + 1, len(hypothesis) + 1
    costs = [[0] * columns for _ in range(rows)]
    for row in range(rows):
        costs[row][0] = row
    for column in range(columns):
        costs[0][column] = column
    for row in range(1, rows):
        for column in range(1, columns):
            substitution = costs[row - 1][column - 1] + (
                reference[row - 1] != hypothesis[column - 1]
            )
            costs[row][column] = min(
                substitution,
                costs[row - 1][column] + 1,
                costs[row][column - 1] + 1,
            )
    operations: list[tuple] = []
    row, column = len(reference), len(hypothesis)
    while row > 0 or column > 0:
        if (
            row > 0
            and column > 0
            and costs[row][column]
            == costs[row - 1][column - 1] + (reference[row - 1] != hypothesis[column - 1])
        ):
            same = reference[row - 1] == hypothesis[column - 1]
            operations.append(
                ("match" if same else "substitution", reference[row - 1], hypothesis[column - 1])
            )
            row, column = row - 1, column - 1
        elif row > 0 and costs[row][column] == costs[row - 1][column] + 1:
            operations.append(("deletion", reference[row - 1], ""))
            row -= 1
        else:
            operations.append(("insertion", "", hypothesis[column - 1]))
            column -= 1
    operations.reverse()
    return operations


def classify(reference_word: str, hypothesis_word: str) -> str:
    """Name the kind of disagreement, to separate signal from normalisation."""
    if DIGIT.search(reference_word) or DIGIT.search(hypothesis_word):
        return "numeric"
    stripped_reference = "".join(
        c for c in unicodedata.normalize("NFD", reference_word) if not unicodedata.combining(c)
    )
    stripped_hypothesis = "".join(
        c for c in unicodedata.normalize("NFD", hypothesis_word) if not unicodedata.combining(c)
    )
    if reference_word != hypothesis_word and stripped_reference == stripped_hypothesis:
        return "accent"
    if reference_word.replace("'", "") == hypothesis_word.replace("'", ""):
        return "elision"
    if not reference_word or not hypothesis_word:
        return "missing_word"
    if reference_word[0] == hypothesis_word[0]:
        return "same_onset"
    return "lexical"


def analyze(
    teacher_rows: list[dict[str, object]],
    prediction_rows: list[dict[str, object]],
) -> tuple[dict[str, object], list[dict[str, object]]]:
    predictions = {
        str(row.get("id", "")): str(row.get("rawText", "")) for row in prediction_rows
    }
    agreed = 0
    disagreed = 0
    skipped = 0
    total_words = 0
    total_errors = 0
    kinds: Counter[str] = Counter()
    pairs: Counter[tuple[str, str]] = Counter()
    by_language: Counter[str] = Counter()
    queue: list[dict[str, object]] = []
    for row in teacher_rows:
        identifier = str(row.get("id", ""))
        hypothesis_text = predictions.get(identifier)
        if hypothesis_text is None:
            skipped += 1
            continue
        reference = normalize(row.get("raw", "")).split()
        hypothesis = normalize(hypothesis_text).split()
        if not reference:
            skipped += 1
            continue
        total_words += len(reference)
        if reference == hypothesis:
            agreed += 1
            continue
        disagreed += 1
        language = str(row.get("requested_language", "?"))
        by_language[language] += 1
        operations = word_alignment(reference, hypothesis)
        differences = [op for op in operations if op[0] != "match"]
        total_errors += len(differences)
        for operation, reference_word, hypothesis_word in differences:
            kind = (
                "missing_word"
                if operation in ("deletion", "insertion")
                else classify(reference_word, hypothesis_word)
            )
            kinds[kind] += 1
            if operation == "substitution":
                pairs[(reference_word, hypothesis_word)] += 1
        queue.append(
            {
                "id": identifier,
                "language": language,
                "errorCount": len(differences),
                "referenceWordCount": len(reference),
                "errorRate": len(differences) / len(reference),
                "teacherText": str(row.get("raw", "")),
                "voxolText": hypothesis_text,
            }
        )
    queue.sort(key=lambda item: (-item["errorCount"], item["id"]))
    report = {
        "schemaVersion": "voxol-teacher-disagreement-v1",
        "chunks": {
            "compared": agreed + disagreed,
            "agreed": agreed,
            "disagreed": disagreed,
            "skipped": skipped,
            "agreementRate": (
                0.0 if agreed + disagreed == 0 else agreed / (agreed + disagreed)
            ),
        },
        "words": {
            "reference": total_words,
            "disagreeing": total_errors,
            "disagreementRate": 0.0 if total_words == 0 else total_errors / total_words,
        },
        "disagreementKinds": dict(kinds.most_common()),
        "disagreementsByLanguage": dict(by_language.most_common()),
        "mostFrequentSubstitutions": [
            {"teacher": teacher, "voxol": voxol, "count": count}
            for (teacher, voxol), count in pairs.most_common(30)
        ],
    }
    return report, queue


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--teacher-manifest", type=Path, required=True)
    result.add_argument("--predictions", type=Path, required=True)
    result.add_argument("--report", type=Path, required=True)
    result.add_argument("--queue", type=Path)
    result.add_argument("--queue-limit", type=int, default=2000)
    return result


def main() -> int:
    arguments = parser().parse_args()
    teacher_rows = read_jsonl(arguments.teacher_manifest)
    prediction_rows = read_jsonl(arguments.predictions)
    report, queue = analyze(teacher_rows, prediction_rows)
    arguments.report.parent.mkdir(parents=True, exist_ok=True)
    arguments.report.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    if arguments.queue is not None:
        selected = queue[: arguments.queue_limit]
        arguments.queue.parent.mkdir(parents=True, exist_ok=True)
        arguments.queue.write_text(
            "".join(
                json.dumps(item, ensure_ascii=False, sort_keys=True) + "\n"
                for item in selected
            ),
            encoding="utf-8",
        )
        report["queue"] = {
            "path": str(arguments.queue),
            "written": len(selected),
            "available": len(queue),
        }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
