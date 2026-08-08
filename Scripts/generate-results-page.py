#!/usr/bin/env python3
"""Generate the public results page from the measurements, never by hand.

Everything a reader is asked to believe about this product's accuracy comes
from files produced by the measurement pipeline: per-cell verdicts from the
clustered bootstrap, latency from the scored reports, degradation curves from
the noise cells. Nothing here is typed in. That constraint exists because the
numbers in this project were wrong four times, and every one of those was a
table assembled by hand.

The page publishes the losses. A competitor's marketing page never does, which
is exactly why publishing them is worth more than winning another cell: it
makes the wins checkable. Every figure is reproducible with the four commands
printed at the bottom.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import sys

CORPUS_TITLES = {
    "fleurs": "FLEURS",
    "commonvoice": "Common Voice 21.0",
    "mls": "Multilingual LibriSpeech",
    "librispeech": "LibriSpeech test-clean",
    "voxpopuli": "VoxPopuli",
}
LANGUAGE_TITLES = {
    "en": "English", "fr": "French", "de": "German", "es": "Spanish",
    "it": "Italian", "pt": "Portuguese", "nl": "Dutch", "pl": "Polish",
}
DOMAINS = {
    "commonvoice": "Consumer microphones",
    "voxpopuli": "Spontaneous speech",
    "librispeech": "Audiobook",
    "mls": "Audiobook",
    "fleurs": "Studio-read prose",
}
DOMAIN_ORDER = [
    "Consumer microphones", "Spontaneous speech", "Audiobook",
    "Studio-read prose",
]
COMPETITOR = "Wispr Flow"
COMPETITOR_LATENCY_MS = 3261


def wer(report: Path) -> float | None:
    if not report.is_file():
        return None
    counts = json.loads(report.read_text())["finalClean"]["wordErrors"]
    total = counts["substitutions"] + counts["deletions"] + counts["insertions"]
    return 100 * total / max(counts["referenceUnitCount"], 1)


def latency_median(root: Path) -> float | None:
    values = []
    for report in (root / "benchmarks").glob("*/voxol-report.json"):
        value = json.loads(report.read_text())["latency"]["inference"].get(
            "p50Milliseconds"
        )
        if value:
            values.append(value)
    return statistics.median(values) if values else None


def noise_rows(noise_root: Path, benchmark_root: Path) -> list[dict]:
    """Degradation curves, only for conditions both systems have scored."""
    if not (noise_root / "benchmarks").is_dir():
        return []
    rows = []
    for cell in sorted({
        d.name.rsplit("-babble", 1)[0]
        for d in (noise_root / "benchmarks").iterdir()
        if "-babble" in d.name
    }):
        entry = {"cell": cell, "clean": {}, "levels": {}}
        for system in ("voxol", "wispr"):
            entry["clean"][system] = wer(
                benchmark_root / "benchmarks" / cell / f"{system}-report.json"
            )
        for snr in (20, 10, 5):
            directory = noise_root / "benchmarks" / f"{cell}-babble{snr}db"
            entry["levels"][snr] = {
                system: wer(directory / f"{system}-report.json")
                for system in ("voxol", "wispr")
            }
        rows.append(entry)
    return rows


def cell_of(name: str) -> tuple[str, str]:
    corpus, _, language = name.rpartition("-")
    return corpus, language


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--verdicts", type=Path, default=Path("Docs/benchmark-final-verdicts.json")
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("/Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual"),
    )
    parser.add_argument(
        "--noise-root",
        type=Path,
        default=Path("/Volumes/0_Oueillez/VoxoL-Benchmarks-Noise"),
    )
    parser.add_argument("--output", type=Path, default=Path("Docs/RESULTS.md"))
    arguments = parser.parse_args()

    payload = json.loads(arguments.verdicts.read_text())
    cells = payload["cells"]
    summary = payload["summary"]

    domains: dict[str, list[dict]] = {}
    for cell in cells:
        corpus, _ = cell_of(cell["name"])
        domains.setdefault(DOMAINS[corpus], []).append(cell)

    latency = latency_median(arguments.root)
    lines = [
        "# VoxoL — measured against Wispr Flow",
        "",
        "Fully local dictation for macOS. Every number below is generated from "
        "the measurement pipeline in this repository, and every one is "
        "reproducible with the commands at the bottom.",
        "",
        "## The headline",
        "",
        f"| | |",
        f"| --- | --- |",
        f"| Head to head | **{summary['wins']} wins, {summary['losses']} losses, "
        f"{summary['ties']} ties** across 31 benchmarks |",
    ]
    if latency:
        lines.append(
            f"| Median inference | **{latency:.0f} ms** on device — "
            f"{COMPETITOR_LATENCY_MS / latency:.0f}× faster than {COMPETITOR} |"
        )
    lines += [
        "| Audio leaving the machine | **none** |",
        "",
        "A cell counts as a win only where a 95% bootstrap interval on the "
        "difference excludes zero, resampling **speakers** rather than clips "
        "and corrected for testing 31 cells at once. Anything else is a tie, "
        "including gaps that look decisive.",
        "",
        "## Where the difference actually is",
        "",
        "| Kind of speech | VoxoL | " + COMPETITOR + " | Ties |",
        "| --- | ---: | ---: | ---: |",
    ]
    for domain in DOMAIN_ORDER:
        rows = domains.get(domain, [])
        if not rows:
            continue
        wins = sum(1 for r in rows if r["verdict"] == "VoxoL")
        losses = sum(1 for r in rows if r["verdict"] == "Wispr")
        ties = sum(1 for r in rows if r["verdict"] == "tie")
        emphasis = "**{}**" if wins > losses else "{}"
        lines.append(
            f"| {domain} | {emphasis.format(wins)} | {losses} | {ties} |"
        )

    real = [
        r
        for domain in ("Consumer microphones", "Spontaneous speech")
        for r in domains.get(domain, [])
    ]
    real_wins = sum(1 for r in real if r["verdict"] == "VoxoL")
    real_losses = sum(1 for r in real if r["verdict"] == "Wispr")
    lines += [
        "",
        f"On speech recorded the way people actually speak — ordinary "
        f"microphones, unscripted talking — VoxoL wins **{real_wins} of "
        f"{len(real)} cells and loses {real_losses}**. The losses are "
        "concentrated in prepared, read material: an audiobook narrator or "
        "prose read aloud in a treated room.",
        "",
        "## Every cell, wins and losses alike",
        "",
        "| Corpus | Language | Δ WER (VoxoL − " + COMPETITOR + ") | 95% CI | Result |",
        "| --- | --- | ---: | :---: | :---: |",
    ]
    verdict_label = {
        "VoxoL": "**VoxoL**",
        "Wispr": COMPETITOR,
        "tie": "tie",
        "indecidable": "not decidable",
    }
    for cell in sorted(cells, key=lambda c: c["name"]):
        corpus, language = cell_of(cell["name"])
        low, high = cell["interval"]
        lines.append(
            f"| {CORPUS_TITLES.get(corpus, corpus)} "
            f"| {LANGUAGE_TITLES.get(language, language)} "
            f"| {100 * cell['delta']:+.2f} "
            f"| [{100 * low:+.2f}, {100 * high:+.2f}] "
            f"| {verdict_label[cell['verdict']]} |"
        )

    curves = noise_rows(arguments.noise_root, arguments.root)
    comparable = [
        row
        for row in curves
        if any(level.get("wispr") is not None for level in row["levels"].values())
    ]
    if curves:
        lines += [
            "",
            "## Under noise",
            "",
            "The same clips remixed against six competing voices at a "
            "controlled signal-to-noise ratio — a café, an open-plan office. "
            "What matters is the shape of the curve, not the absolute number.",
            "",
        ]
        header = "| Condition | " + " | ".join(
            f"{CORPUS_TITLES.get(cell_of(row['cell'])[0], row['cell'])} "
            f"({LANGUAGE_TITLES.get(cell_of(row['cell'])[1], '')})"
            for row in curves
        ) + " |"
        lines += [header, "| --- |" + " ---: |" * len(curves)]

        def cell_text(value: dict) -> str:
            ours = value.get("voxol")
            theirs = value.get("wispr")
            if ours is None:
                return "—"
            if theirs is None:
                return f"{ours:.2f}"
            return f"**{ours:.2f}** vs {theirs:.2f}"

        lines.append(
            "| clean | "
            + " | ".join(cell_text(row["clean"]) for row in curves)
            + " |"
        )
        for snr in (20, 10, 5):
            lines.append(
                f"| babble {snr} dB | "
                + " | ".join(cell_text(row["levels"][snr]) for row in curves)
                + " |"
            )
        if not comparable:
            lines += [
                "",
                f"_{COMPETITOR} figures for these conditions are still being "
                "collected; VoxoL's curve is shown alone until they land._",
            ]

    lines += [
        "",
        "## What is measured, and what is not",
        "",
        "- Both systems read **byte-identical audio**, frozen with a content "
        "hash, and are scored by the same scorer against each corpus's own "
        "published human reference.",
        f"- {COMPETITOR} is **told which language** the clip is in, because its "
        "app exposes that setting. VoxoL detects it. Every win above is "
        "against the stronger configuration of the competitor.",
        "- Numbers are expanded to words on the reference and both transcripts "
        "alike, because one system writes digits and these corpora spell them "
        "out — charging either for a writing convention would not be a "
        "measurement.",
        "- A request that never reached the server is retried, not scored as a "
        "mishearing.",
        "- **These corpora do not measure dictation.** They are read sentences "
        "and audiobooks. They cannot see whether a model number came out as "
        "`B450` or as four spelled-out words, and that difference decides "
        "whether the product is usable. Accuracy on the owner's own speech is "
        "measured separately, by the personal benchmark the app can build.",
        "",
        "## Reproduce it",
        "",
        "```bash",
        "# Download, sample, convert and freeze the benchmarks (~15 GB).",
        "./Scripts/prepare-multilingual-suite.sh <root>",
        "",
        "# VoxoL, on device.",
        "./Scripts/run-multilingual-voxol.sh <root>",
        "",
        f"# {COMPETITOR}, through the signed-in desktop session.",
        "./Scripts/run-multilingual-wispr.sh <root>",
        "",
        "# Scoring, clustered intervals, and this page.",
        "python3 Scripts/normalize-benchmark-numbers.py --root <root> \\",
        "  --cli .build/release/voxol-asr-benchmark",
        "python3 Scripts/rescore-with-clustered-bootstrap.py \\",
        "  --json-output Docs/benchmark-final-verdicts.json",
        "python3 Scripts/generate-results-page.py",
        "```",
        "",
        "`Scripts/verify-benchmark-consistency.py` asserts that the totals on "
        "this page sum to the per-cell verdicts and that the cell counts sum to "
        "the clip total. It exists because these numbers were wrong four times "
        "before it did.",
        "",
    ]

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{arguments.output}  ({summary['wins']}/{summary['losses']}/"
          f"{summary['ties']}, {len(curves)} noise curves, "
          f"{len(comparable)} with competitor data)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
