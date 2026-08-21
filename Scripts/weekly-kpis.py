#!/usr/bin/env python3
"""The five numbers that say whether VoxoL is getting better.

Reads the content-free metrics log the app appends per dictation and prints:
no-retouch rate, weighted correction load, critical semantic errors, p95
release-to-text latency, and D7 retention — overall and cut by mode and
language. Everything else (WER, validator acceptance, distance to a
reference) is a diagnostic, not a KPI.

A dictation with no outcome event (destination app without Accessibility
text) counts toward volume and latency but not toward the retouch rate: its
verdict is unknown, and counting unknowns as wins would inflate exactly the
number this exists to keep honest.
"""

from __future__ import annotations

import argparse
import datetime
import json
from collections import defaultdict
from pathlib import Path

DEFAULT_LOG = (
    Path.home() / "Library/Application Support/VoxoL/Metrics/dictations.jsonl"
)


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))
    return ordered[index]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, default=DEFAULT_LOG)
    parser.add_argument("--days", type=int, default=7, help="Fenêtre d'analyse.")
    arguments = parser.parse_args()

    if not arguments.log.is_file():
        print(f"Aucune métrique : {arguments.log}")
        print("Le fichier se remplit à chaque dictée insérée (hors mode privé).")
        return 0

    dictations: dict[str, dict] = {}
    outcomes: dict[str, dict] = {}
    for line in arguments.log.read_text(encoding="utf-8").splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("type") == "dictation":
            dictations[record["id"]] = record
        elif record.get("type") == "outcome":
            outcomes[record["id"]] = record

    now = datetime.datetime.now().timestamp()
    cutoff = now - arguments.days * 86_400
    window = {i: d for i, d in dictations.items() if d.get("ts", 0) >= cutoff}
    if not window:
        print(f"Aucune dictée dans les {arguments.days} derniers jours.")
        return 0

    def summarize(ids: list[str], label: str) -> None:
        judged = [i for i in ids if i in outcomes]
        untouched = [
            i for i in judged if outcomes[i].get("outcome") in ("unchanged", "continued")
        ]
        corrected = [i for i in judged if outcomes[i].get("outcome") == "corrected"]
        words = sum(window[i].get("words", 0) for i in ids)
        edits = sum(outcomes[i].get("wordEdits", 0) for i in judged)
        critical = sum(
            1 for i in judged if outcomes[i].get("criticalTouched") is True
        )
        latencies = [
            float(window[i]["latencyMs"])
            for i in ids
            if isinstance(window[i].get("latencyMs"), (int, float))
        ]
        p95 = percentile(latencies, 0.95)
        no_retouch = (
            f"{len(untouched) / len(judged) * 100:5.1f} %" if judged else "   n/a"
        )
        load = f"{edits / words * 100:5.2f}" if words else "  n/a"
        p95_text = f"{p95:6.0f} ms" if p95 is not None else "    n/a"
        print(
            f"{label:<22s} {len(ids):4d} dictées  sans-retouche {no_retouch}"
            f"  charge {load}/100 mots  critiques {critical}"
            f"  p95 {p95_text}  (jugées {len(judged)}, corrigées {len(corrected)})"
        )

    print(f"Fenêtre : {arguments.days} jours, {len(window)} dictées\n")
    summarize(list(window), "TOTAL")
    for dimension in ("mode", "language"):
        groups: dict[str, list[str]] = defaultdict(list)
        for identifier, dictation in window.items():
            groups[str(dictation.get(dimension, "?"))].append(identifier)
        for value, ids in sorted(groups.items()):
            summarize(ids, f"  {dimension}={value}")

    # Rétention D7 : parmi les personnes actives il y a 8-14 jours (ici, la
    # machine), y a-t-il encore de l'activité cette semaine ?
    previous = [
        d for d in dictations.values() if cutoff - 7 * 86_400 <= d.get("ts", 0) < cutoff
    ]
    if previous:
        retained = "oui" if window else "non"
        print(f"\nActivité semaine précédente : {len(previous)} dictées ; retenue : {retained}")
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main())
