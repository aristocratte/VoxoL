#!/usr/bin/env python3
"""Re-decide every benchmark with the speaker as the resampling unit.

The published intervals resampled clips. Clips are not independent: MLS Dutch
draws its three hundred from six narrators and one of them supplies forty-six
percent of them, so a clip-level bootstrap counts one voice as a hundred and
thirty-eight separate pieces of evidence and reports an interval far narrower
than the data supports. That is the largest single loss in the suite.

This resamples speakers, then takes every clip belonging to the drawn speakers,
which is what the sampling actually looked like. It also applies a
Benjamini-Hochberg correction across the cells, because thirty-one independent
tests at ninety-five percent produce false winners on their own.

FLEURS carries a caveat that cannot be fixed here: the corpus publishes no
speaker identifier in the transcript file this suite reads, so every FLEURS cell
looks like a single speaker and its interval cannot be clustered. Those cells
are reported unclustered and flagged, not silently mixed in.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import numpy

RESAMPLES = 10_000
SEED = 20260807
FALSE_DISCOVERY_RATE = 0.05

FLEURS_LOCALES = {
    "en": "en_us", "fr": "fr_fr", "de": "de_de", "es": "es_419",
    "it": "it_it", "pt": "pt_br", "nl": "nl_nl", "pl": "pl_pl",
}


def fleurs_sentence_clusters(root: Path, language: str) -> dict[str, str]:
    """Clip id to sentence cluster, rebuilt exactly as the sampler hashed it."""
    import csv
    import hashlib

    locale = FLEURS_LOCALES.get(language)
    if locale is None:
        return {}
    tsv = root / "cache" / "fleurs" / f"{locale}-test.tsv"
    if not tsv.exists():
        return {}
    mapping = {}
    with tsv.open(encoding="utf-8", newline="") as stream:
        for row in csv.reader(stream, delimiter="\t", quoting=csv.QUOTE_NONE):
            if len(row) != 7:
                continue
            identity = hashlib.sha256(
                f"fleurs\0{locale}\0{row[1]}".encode()
            ).hexdigest()[:12]
            mapping[f"fleurs-{language}-{identity}"] = f"sentence-{row[0]}"
    return mapping


def load_cell(directory: Path, root: Path) -> dict | None:
    manifest = directory / "manifest-numeric-frozen.json"
    ours = directory / "voxol-numeric-items.jsonl"
    theirs = directory / "wispr-numeric-items.jsonl"
    if not (manifest.is_file() and ours.is_file() and theirs.is_file()):
        return None

    speakers = {
        item["id"]: item["speakerID"]
        for item in json.loads(manifest.read_text())["items"]
    }
    # FLEURS publishes no speaker id in the transcript file, so every clip
    # carries the same placeholder and the cell would degenerate to a single
    # cluster — which makes the bootstrap interval collapse to a point and
    # every FLEURS cell spuriously decisive. It does publish a sentence id,
    # and it records the same sentence up to three times, so the sentence is
    # the dependency unit. Derived here from the cached TSVs rather than a
    # temp file: an earlier version read /tmp and would have silently
    # produced those degenerate verdicts after any reboot.
    corpus = directory.name.rpartition("-")[0]
    if corpus == "fleurs":
        language = directory.name.rpartition("-")[2]
        table = fleurs_sentence_clusters(root, language)
        if not table:
            return None
        for identifier in list(speakers):
            if identifier in table:
                speakers[identifier] = table[identifier]

    def counts(path: Path) -> dict[str, tuple[float, float]]:
        result = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            errors = row["finalWordErrors"]
            result[row["id"]] = (
                errors["substitutions"] + errors["deletions"] + errors["insertions"],
                errors["referenceUnitCount"],
            )
        return result

    ours_counts, theirs_counts = counts(ours), counts(theirs)
    shared = [i for i in speakers if i in ours_counts and i in theirs_counts]
    if not shared:
        return None

    groups: dict[str, list[str]] = {}
    for identifier in shared:
        groups.setdefault(speakers[identifier], []).append(identifier)

    return {
        "ids": shared,
        "groups": list(groups.values()),
        "ours": ours_counts,
        "theirs": theirs_counts,
    }


def micro(errors: float, words: float) -> float:
    return errors / words if words else float("nan")


def differences(
    cell: dict, generator: numpy.random.Generator
) -> numpy.ndarray:
    """Bootstrap distribution of the micro-WER difference, resampling clusters."""
    groups = cell["groups"]
    ours = numpy.array(
        [[sum(cell["ours"][i][k] for i in g) for g in groups] for k in (0, 1)],
        dtype=float,
    )
    theirs = numpy.array(
        [[sum(cell["theirs"][i][k] for i in g) for g in groups] for k in (0, 1)],
        dtype=float,
    )
    count = len(groups)
    draws = generator.integers(0, count, size=(RESAMPLES, count))
    a = ours[0][draws].sum(axis=1) / numpy.maximum(ours[1][draws].sum(axis=1), 1)
    b = theirs[0][draws].sum(axis=1) / numpy.maximum(theirs[1][draws].sum(axis=1), 1)
    return a - b


def two_sided_p(sample: numpy.ndarray) -> float:
    """Share of resamples on the wrong side of zero, doubled.

    Replaces an earlier approximation that inverted the interval width — a
    fabricated number that made the multiple-comparison correction inert.
    """
    if len(sample) == 0:
        return 1.0
    wrong = min((sample >= 0).mean(), (sample <= 0).mean())
    return float(min(1.0, 2 * max(wrong, 1 / len(sample))))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("/Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual"),
    )
    parser.add_argument(
        "--extended",
        type=Path,
        default=Path("/Volumes/0_Oueillez/VoxoL-Benchmarks-Extended"),
        help="Cells re-run at a larger sample; they supersede their "
        "same-name originals, because more data from the same corpus is "
        "strictly better evidence.",
    )
    parser.add_argument("--json-output", type=Path)
    arguments = parser.parse_args()

    generator = numpy.random.default_rng(SEED)
    directories: dict[str, tuple[Path, Path, str]] = {}
    for directory in sorted((arguments.root / "benchmarks").iterdir()):
        if not directory.name.startswith("."):
            directories[directory.name] = (directory, arguments.root, "original")
    superseded = 0
    if arguments.extended and (arguments.extended / "benchmarks").is_dir():
        for directory in sorted((arguments.extended / "benchmarks").iterdir()):
            if directory.name.startswith("."):
                continue
            if directory.name in directories:
                superseded += 1
            directories[directory.name] = (
                directory,
                arguments.extended,
                "extended",
            )

    rows = []
    for name in sorted(directories):
        directory, cell_root, source = directories[name]
        cell = load_cell(directory, cell_root)
        if cell is None:
            continue
        corpus, _, language = directory.name.rpartition("-")
        clustered = len(cell["groups"]) > 1
        sample = differences(cell, generator)
        low = float(numpy.percentile(sample, 2.5))
        high = float(numpy.percentile(sample, 97.5))
        ours = micro(
            sum(v[0] for v in cell["ours"].values()),
            sum(v[1] for v in cell["ours"].values()),
        )
        theirs = micro(
            sum(v[0] for v in cell["theirs"].values()),
            sum(v[1] for v in cell["theirs"].values()),
        )
        rows.append(
            {
                "name": directory.name,
                "corpus": corpus,
                "clusters": len(cell["groups"]),
                "clustered": clustered,
                "delta": ours - theirs,
                "low": low,
                "high": high,
                "p": two_sided_p(sample),
                "source": source,
            }
        )

    # Benjamini-Hochberg across the cells that produced a decision.
    tested = sorted([r for r in rows], key=lambda r: r["p"])
    for rank, row in enumerate(tested, 1):
        row["threshold"] = FALSE_DISCOVERY_RATE * rank / len(tested)
    passing = [r for r in tested if r["p"] <= r["threshold"]]
    cutoff = max((r["p"] for r in passing), default=0.0)
    print(f"correction BH : seuil de p retenu {cutoff:.4f}\n")

    print(f"{'cellule':18s} {'grappes':>8s} {'delta':>7s} {'IC 95% par locuteur':>22s}  verdict")
    changed = 0
    for row in sorted(rows, key=lambda r: r["name"]):
        naive = "VoxoL" if row["high"] < 0 else "Wispr" if row["low"] > 0 else "tie"
        survives = row["p"] <= cutoff and naive != "tie"
        verdict = naive if survives else "tie"
        if not row["clustered"]:
            verdict = "indecidable"
        flag = "" if row["clustered"] else "  (aucune grappe)"
        mark = "" if verdict == naive else "  <- degrade"
        if verdict != naive:
            changed += 1
        print(
            f"{row['name']:18s} {row['clusters']:8d} {100*row['delta']:+7.2f} "
            f"[{100*row['low']:+7.2f},{100*row['high']:+7.2f}]  {verdict}{mark}{flag}"
        )

    decidable = [r for r in rows if r["clustered"]]
    wins = sum(1 for r in decidable if r["high"] < 0 and r["p"] <= cutoff)
    losses = sum(1 for r in decidable if r["low"] > 0 and r["p"] <= cutoff)
    ties = len(decidable) - wins - losses
    excluded = len(rows) - len(decidable)
    print(
        f"\napres regroupement par grappe et correction BH : "
        f"{wins} victoires / {losses} defaites / {ties} egalites"
        + (f"  ({excluded} indecidable(s) exclue(s))" if excluded else "")
        + f"  [{superseded} cellules remplacees par leur version etendue]"
    )
    print(f"{changed} cellule(s) declassee(s) en egalite")

    if arguments.json_output:
        payload = {
            "method": (
                "paired bootstrap resampling speakers (sentence for FLEURS), "
                f"{RESAMPLES} resamples, seed {SEED}, "
                f"Benjamini-Hochberg q={FALSE_DISCOVERY_RATE}"
            ),
            "summary": {"wins": wins, "losses": losses, "ties": ties},
            "cells": [
                {
                    "name": r["name"],
                    "source": r["source"],
                    "clusters": r["clusters"],
                    "delta": r["delta"],
                    "interval": [r["low"], r["high"]],
                    "p": r["p"],
                    "verdict": (
                        "VoxoL"
                        if r["high"] < 0 and r["p"] <= cutoff
                        else "Wispr"
                        if r["low"] > 0 and r["p"] <= cutoff
                        else "tie"
                    )
                    if r["clustered"]
                    else "indecidable",
                }
                for r in sorted(rows, key=lambda r: r["name"])
            ],
        }
        arguments.json_output.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n"
        )
        print(f"verdicts ecrits: {arguments.json_output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
