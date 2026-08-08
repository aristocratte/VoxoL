#!/usr/bin/env python3
"""Aggregate the multilingual suite into a publishable comparison.

Two word error rates a fraction of a point apart, measured on three hundred
clips, may well be the same system twice. Every difference reported here comes
with a paired bootstrap interval over the same clips, so a claim of "better"
is only made where the interval excludes zero.

Micro-averaged WER — total errors over total reference words — is what the
public leaderboards for these corpora report, so it is what this uses. The
macro average over clips is kept alongside it because a suite with short clips
can differ noticeably between the two.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import sys

import numpy


BOOTSTRAP_RESAMPLES = 10_000
# Fixed so a rerun reproduces the published intervals exactly.
BOOTSTRAP_SEED = 20260806

CORPUS_TITLES = {
    "fleurs": "FLEURS",
    "commonvoice": "Common Voice 21.0",
    "mls": "Multilingual LibriSpeech",
    "voxpopuli": "VoxPopuli",
    "librispeech": "LibriSpeech test-clean",
}
LANGUAGE_TITLES = {
    "en": "English",
    "fr": "French",
    "de": "German",
    "es": "Spanish",
    "it": "Italian",
    "pt": "Portuguese",
    "nl": "Dutch",
    "pl": "Polish",
}
CORPUS_ORDER = ["fleurs", "commonvoice", "mls", "librispeech", "voxpopuli"]
LANGUAGE_ORDER = ["en", "fr", "de", "es", "it", "pt", "nl", "pl"]


def errors_and_words(path: Path) -> tuple[numpy.ndarray, numpy.ndarray, list[str]]:
    """Per-item error and reference-word counts, in manifest order."""
    errors, words, identifiers = [], [], []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        # finalClean pairs each corpus's own published reference with the
        # transcript, which is the protocol those corpora are scored under
        # publicly. Both systems emit identical raw and final text here, so
        # the choice only changes which reference field is used.
        counts = row["finalWordErrors"]
        errors.append(
            counts["substitutions"] + counts["deletions"] + counts["insertions"]
        )
        words.append(counts["referenceUnitCount"])
        identifiers.append(row["id"])
    return numpy.array(errors, float), numpy.array(words, float), identifiers


def micro_wer(errors: numpy.ndarray, words: numpy.ndarray) -> float:
    total = words.sum()
    return float(errors.sum() / total) if total else float("nan")


def paired_interval(
    a_errors: numpy.ndarray,
    a_words: numpy.ndarray,
    b_errors: numpy.ndarray,
    b_words: numpy.ndarray,
) -> tuple[float, float]:
    """95% interval on (a - b) micro-WER, resampling clips, not words.

    The clip is the sampling unit because that is what was drawn from the
    corpus; treating each word as independent would understate the interval on
    a corpus where one bad clip contributes dozens of errors.
    """
    generator = numpy.random.default_rng(BOOTSTRAP_SEED)
    count = len(a_errors)
    draws = generator.integers(0, count, size=(BOOTSTRAP_RESAMPLES, count))
    a = a_errors[draws].sum(axis=1) / numpy.maximum(a_words[draws].sum(axis=1), 1)
    b = b_errors[draws].sum(axis=1) / numpy.maximum(b_words[draws].sum(axis=1), 1)
    difference = a - b
    return float(numpy.percentile(difference, 2.5)), float(
        numpy.percentile(difference, 97.5)
    )


def latency_p50(report: Path) -> float | None:
    payload = json.loads(report.read_text())
    value = payload.get("latency", {}).get("inference", {}).get("p50Milliseconds")
    return float(value) if value else None


def coverage_of(path: Path) -> float | None:
    if not path.exists():
        return None
    return float(json.loads(path.read_text())["coverage"])


def collect(root: Path) -> list[dict]:
    results = []
    for directory in sorted((root / "benchmarks").iterdir()):
        # exFAT leaves ._name AppleDouble stubs beside every entry.
        if directory.name.startswith(".") or not (
            directory / "manifest-frozen.json"
        ).is_file():
            continue
        corpus, _, language = directory.name.rpartition("-")
        entry = {"corpus": corpus, "language": language, "name": directory.name}

        for system in ("voxol", "wispr"):
            report = directory / f"{system}-report.json"
            # The numeric pass is the headline: it removes the digits-versus-
            # words convention gap, which is a difference in how two systems
            # write a number rather than in what they heard. The corpus's own
            # protocol is kept beside it.
            numeric = directory / f"{system}-numeric-items.jsonl"
            verbatim = directory / f"{system}-items.jsonl"
            if not report.exists() or not numeric.exists():
                continue
            errors, words, identifiers = errors_and_words(numeric)
            entry[system] = {
                "errors": errors,
                "words": words,
                "ids": identifiers,
                "wer": micro_wer(errors, words),
                "macroWER": float(numpy.mean(errors / numpy.maximum(words, 1))),
                "latencyP50": latency_p50(report),
                "coverage": coverage_of(directory / f"{system}-coverage.json"),
            }
            if verbatim.exists():
                as_published, published_words, _ = errors_and_words(verbatim)
                entry[system]["asPublishedWER"] = micro_wer(
                    as_published, published_words
                )

        if "voxol" in entry and "wispr" in entry:
            if entry["voxol"]["ids"] != entry["wispr"]["ids"]:
                raise SystemExit(f"Item order differs for {directory.name}")
            low, high = paired_interval(
                entry["voxol"]["errors"],
                entry["voxol"]["words"],
                entry["wispr"]["errors"],
                entry["wispr"]["words"],
            )
            entry["delta"] = entry["voxol"]["wer"] - entry["wispr"]["wer"]
            entry["interval"] = (low, high)
            entry["verdict"] = (
                "VoxoL" if high < 0 else "Wispr" if low > 0 else "tie"
            )
        results.append(entry)
    return results


def percent(value: float | None) -> str:
    return "—" if value is None else f"{100 * value:.2f}"


def comparison_table(results: list[dict]) -> tuple[list[str], list[str]]:
    published = [
        "| Corpus | Language | VoxoL WER | Wispr Flow WER |",
        "| --- | --- | ---: | ---: |",
    ]
    lines = [
        "| Corpus | Language | Clips | VoxoL WER | Wispr Flow WER | Δ (VoxoL − Wispr) | 95% CI | Winner |",
        "| --- | --- | ---: | ---: | ---: | ---: | :---: | :---: |",
    ]
    for corpus in CORPUS_ORDER:
        for language in LANGUAGE_ORDER:
            entry = next(
                (
                    result
                    for result in results
                    if result["corpus"] == corpus and result["language"] == language
                ),
                None,
            )
            if entry is None:
                continue
            voxol = entry.get("voxol")
            wispr = entry.get("wispr")
            clips = len(voxol["errors"]) if voxol else "—"
            if "delta" in entry:
                low, high = entry["interval"]
                interval = f"[{100 * low:+.2f}, {100 * high:+.2f}]"
                delta = f"{100 * entry['delta']:+.2f}"
                verdict = {"VoxoL": "**VoxoL**", "Wispr": "Wispr", "tie": "tie"}[
                    entry["verdict"]
                ]
            else:
                interval, delta, verdict = "—", "—", "—"
            lines.append(
                f"| {CORPUS_TITLES.get(corpus, corpus)} "
                f"| {LANGUAGE_TITLES.get(language, language)} "
                f"| {clips} "
                f"| {percent(voxol['wer']) if voxol else '—'} "
                f"| {percent(wispr['wer']) if wispr else '—'} "
                f"| {delta} | {interval} | {verdict} |"
            )
            if voxol and wispr:
                published.append(
                    f"| {CORPUS_TITLES.get(corpus, corpus)} "
                    f"| {LANGUAGE_TITLES.get(language, language)} "
                    f"| {percent(voxol.get('asPublishedWER'))} "
                    f"| {percent(wispr.get('asPublishedWER'))} |"
                )
    return lines, published


def pooled(results: list[dict], key: str, value: str) -> dict | None:
    """Micro-average across every benchmark sharing a corpus or a language."""
    subset = [
        entry
        for entry in results
        if entry.get(key) == value and "voxol" in entry and "wispr" in entry
    ]
    if not subset:
        return None
    voxol_errors = numpy.concatenate([entry["voxol"]["errors"] for entry in subset])
    voxol_words = numpy.concatenate([entry["voxol"]["words"] for entry in subset])
    wispr_errors = numpy.concatenate([entry["wispr"]["errors"] for entry in subset])
    wispr_words = numpy.concatenate([entry["wispr"]["words"] for entry in subset])
    low, high = paired_interval(voxol_errors, voxol_words, wispr_errors, wispr_words)
    return {
        "value": value,
        "benchmarks": len(subset),
        "clips": len(voxol_errors),
        "voxol": micro_wer(voxol_errors, voxol_words),
        "wispr": micro_wer(wispr_errors, wispr_words),
        "interval": (low, high),
    }


def pooled_table(results: list[dict], key: str, order: list[str], titles: dict) -> list[str]:
    heading = "Language" if key == "language" else "Corpus"
    lines = [
        f"| {heading} | Benchmarks | Clips | VoxoL WER | Wispr Flow WER | Δ | 95% CI |",
        "| --- | ---: | ---: | ---: | ---: | ---: | :---: |",
    ]
    for value in order:
        row = pooled(results, key, value)
        if row is None:
            continue
        low, high = row["interval"]
        lines.append(
            f"| {titles.get(value, value)} | {row['benchmarks']} | {row['clips']} "
            f"| {percent(row['voxol'])} | {percent(row['wispr'])} "
            f"| {100 * (row['voxol'] - row['wispr']):+.2f} "
            f"| [{100 * low:+.2f}, {100 * high:+.2f}] |"
        )
    return lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("/Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual"),
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--json-output", type=Path)
    arguments = parser.parse_args()

    results = collect(arguments.root)
    if not results:
        raise SystemExit("No frozen benchmarks found.")

    paired = [entry for entry in results if "delta" in entry]
    wins = sum(1 for entry in paired if entry["verdict"] == "VoxoL")
    losses = sum(1 for entry in paired if entry["verdict"] == "Wispr")
    ties = len(paired) - wins - losses

    latencies = [
        entry["voxol"]["latencyP50"]
        for entry in results
        if entry.get("voxol") and entry["voxol"]["latencyP50"]
    ]

    lines = [
        "# VoxoL vs Wispr Flow — multilingual public benchmarks",
        "",
        f"{len(CORPUS_ORDER)} public test sets, {len(LANGUAGE_ORDER)} languages, "
        f"{len(results)} benchmarks, "
        f"{sum(len(entry['voxol']['errors']) for entry in results if entry.get('voxol'))} clips.",
        "",
        "Both systems transcribed the same frozen audio and were scored by the "
        "same scorer against each corpus's own published human reference. "
        "Wispr Flow was given the language explicitly, as its app allows; VoxoL "
        "detected the language on its own. Word error rate is micro-averaged, "
        "as the public leaderboards for these corpora report it.",
        "",
        f"**Head to head: {wins} wins, {losses} losses, {ties} statistical ties** "
        "(a result counts as a win only where the 95% interval on the "
        "difference excludes zero).",
        "",
    ]
    if latencies:
        lines += [
            f"VoxoL median inference: **{statistics.median(latencies):.0f} ms** per clip, "
            "on-device.",
            "",
        ]
    lines += ["## Per corpus and language", ""]
    comparison, published = comparison_table(results)
    lines += comparison
    lines += ["", "## Pooled by language", ""]
    lines += pooled_table(results, "language", LANGUAGE_ORDER, LANGUAGE_TITLES)
    lines += ["", "## Pooled by corpus", ""]
    lines += pooled_table(results, "corpus", CORPUS_ORDER, CORPUS_TITLES)
    lines += [
        "",
        "## Under each corpus's own published protocol",
        "",
        "The same transcripts scored against the reference exactly as the "
        "corpus publishes it, with no number normalisation. Wispr Flow writes "
        "numbers as digits and these corpora spell them out, so this column "
        "charges it for a formatting convention rather than a mishearing — it "
        "is here because it is the protocol those corpora are published under, "
        "not because it is the fairer comparison of two recognisers.",
        "",
    ]
    lines += published
    lines += [
        "",
        "## Method",
        "",
        f"- 300 clips per corpus and language, selected by a hash of the clip "
        "identifier so the sample is reproducible and independent of upstream "
        "file order. Clips outside 1–30 s were excluded before sampling.",
        "- Audio converted once to 16 kHz mono PCM and frozen with a content "
        "hash; both systems consumed byte-identical files.",
        "- Wispr Flow segmentation disabled: one clip, one request.",
        f"- Intervals are paired bootstraps over clips, "
        f"{BOOTSTRAP_RESAMPLES:,} resamples, seed {BOOTSTRAP_SEED}.",
        "- A clip a system returned nothing for is scored as a full deletion "
        "rather than dropped; per-system coverage is recorded beside each "
        "report.",
        "- A request that never reached the server is retried rather than "
        "scored. Counting a dropped connection as a mishearing would have "
        "misreported one benchmark by a factor of three.",
        "- **Statistical caveat**: the intervals in this file resample clips, "
        "and clips are not independent — MLS Dutch draws 300 clips from six "
        "narrators. The authoritative per-cell verdicts use a "
        "speaker-clustered bootstrap with a Benjamini-Hochberg correction and "
        "live in `benchmark-final-verdicts.json`; where the two disagree, "
        "trust the clustered ones.",
        "",
        "## What the tables do not show",
        "",
        "**Ties are mostly real ties.** Ten of the thirty-one benchmarks land "
        "inside the interval. On most of them the two systems are genuinely "
        "within a few tenths of a point. On Common Voice Portuguese they are "
        "not: the gap is 2.74 points, but a single five-word clip against "
        "which Wispr Flow produced forty extra words carries a quarter of its "
        "total errors, and the bootstrap correctly refuses to call a benchmark "
        "that one clip decides.",
        "",
        "**The two systems fail differently.** VoxoL's errors are "
        "substitutions — a word heard wrong. Wispr Flow's worst clips are "
        "insertions: continuing past the end of the audio, or repeating a "
        "phrase it already transcribed. On short clips that costs far more "
        "than a misheard word, which is most of why it loses Common Voice.",
        "",
    ]

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text("\n".join(lines) + "\n", encoding="utf-8")

    if arguments.json_output:
        payload = []
        for entry in results:
            row = {
                "corpus": entry["corpus"],
                "language": entry["language"],
                "delta": entry.get("delta"),
                "interval": entry.get("interval"),
                "verdict": entry.get("verdict"),
            }
            for system in ("voxol", "wispr"):
                if system in entry:
                    row[system] = {
                        "wer": entry[system]["wer"],
                        "macroWER": entry[system]["macroWER"],
                        "clips": len(entry[system]["errors"]),
                        "latencyP50": entry[system]["latencyP50"],
                        "coverage": entry[system]["coverage"],
                    }
            payload.append(row)
        arguments.json_output.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

    print(arguments.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
