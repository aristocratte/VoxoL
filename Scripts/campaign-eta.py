#!/usr/bin/env python3
"""Estimate when the VoxoL Wispr transcription campaign will finish.

Why this is not a one-liner
---------------------------
The obvious estimate — count finished recordings, divide by elapsed time — is
wrong here, for two reasons:

1. A resumed run re-walks recordings it already collected. Those finish in
   seconds because every chunk is reused, so the recording rate during a
   re-walk is many times the rate of genuine collection. Extrapolating from it
   produces a wildly optimistic answer.
2. File modification times are rewritten during that re-walk, so the chunk and
   record timestamps on disk do not reconstruct the true collection history.

The one uncontaminated signal is the run log: it is append-only, and a line
reading "collected" means a chunk actually went to the API, while "reused"
means it did not. This tool samples that counter over time, persists the
samples, and derives the rate from the difference between them.

Remaining work is measured exactly, not estimated: the campaign manifest lists
every source with its duration, and a source is done when its record.json
exists. Everything else is arithmetic on those two facts.

Usage:
    ./campaign-eta.py                 # one sample, print the current estimate
    ./campaign-eta.py --watch 60      # resample every 60 s until interrupted
    ./campaign-eta.py --reset         # discard stored samples and start over

Reading is non-destructive: the only file written is the sample log under
<campaign-root>/logs/eta-samples.jsonl.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


DEFAULT_CAMPAIGN_ROOT = Path("/Volumes/0_Oueillez/VoxoL-Data-Campaign-v2")
DEFAULT_WINDOW_MINUTES = 30.0
WORKER_PATTERN = "/Users/aris/Documents/wispr/wispr-transcribe.sh"
# Two requests per chunk (raw + edited) at the collector's minimum spacing.
REQUESTS_PER_CHUNK = 2
DEFAULT_MIN_REQUEST_INTERVAL = 0.35
CHUNK_PATTERN = re.compile(r"^\s*chunk \d+/\d+ (collected|reused)\s*$")
# Below this share of genuinely collected chunks, the sampled window is a
# re-walk and its rate must not be projected onto the remaining fresh work.
FRESH_SHARE_FOR_ETA = 0.20
# A run log needs this many genuine collections before its rate means anything.
MINIMUM_HISTORICAL_CHUNKS = 200
WORKER_PATTERN_RE = re.compile(r"\[worker-(\d+) (\d+)/(\d+)\]")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Estimate the remaining time for the VoxoL transcription campaign.",
    )
    result.add_argument("--campaign-root", type=Path, default=DEFAULT_CAMPAIGN_ROOT)
    result.add_argument(
        "--watch",
        type=float,
        metavar="SECONDS",
        help="Resample on this interval until interrupted (Ctrl+C is safe).",
    )
    result.add_argument(
        "--window",
        type=float,
        default=DEFAULT_WINDOW_MINUTES,
        metavar="MINUTES",
        help=f"Trailing window for the rate (default: {DEFAULT_WINDOW_MINUTES:g}).",
    )
    result.add_argument(
        "--samples-path",
        type=Path,
        help="Override the sample log (default: <campaign-root>/logs/eta-samples.jsonl).",
    )
    result.add_argument(
        "--reset",
        action="store_true",
        help="Discard stored samples before measuring.",
    )
    result.add_argument("--json", action="store_true", help="Emit JSON, not a report.")
    return result


def read_manifest(campaign_root: Path) -> dict[str, float]:
    """Map every planned source's file name to its audio duration in seconds."""
    path = campaign_root / "corpus" / "manifest.jsonl"
    if not path.is_file():
        raise SystemExit(f"Campaign manifest not found: {path}")
    planned: dict[str, float] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        original = row.get("original_path")
        if not original:
            continue
        duration = row.get("duration_seconds") or row.get("expected_duration_seconds")
        planned[os.path.basename(original)] = float(duration or 0.0)
    if not planned:
        raise SystemExit(f"Campaign manifest lists no usable source: {path}")
    return planned


def read_finished(campaign_root: Path) -> tuple[set[str], float, int]:
    """Return finished source names, their audio seconds and their chunk count.

    A recording counts as finished once its record.json is readable; the
    collector writes that file last, after every chunk of the recording.
    """
    records = campaign_root / "corpus" / "transcripts" / "dataset" / "records"
    finished: set[str] = set()
    seconds = 0.0
    chunks = 0
    if not records.is_dir():
        return finished, seconds, chunks
    for record_path in records.glob("*/record.json"):
        try:
            record = json.loads(record_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue  # Being written right now; it counts on the next sample.
        source = record.get("source") or {}
        name = source.get("name")
        if not name:
            continue
        finished.add(name)
        seconds += float(source.get("duration_seconds") or 0.0)
        chunks += len(record.get("results") or [])
    return finished, seconds, chunks


def active_log(campaign_root: Path) -> Path | None:
    logs = sorted(
        (campaign_root / "logs").glob("reserve-and-finalize-*.log"),
        key=lambda path: path.stat().st_mtime,
    )
    return logs[-1] if logs else None


def log_counters(path: Path | None) -> dict[str, object]:
    """Count genuine collections and reuses in the active run log."""
    if path is None or not path.is_file():
        return {"log": None, "collected": 0, "reused": 0, "identity": None}
    collected = 0
    reused = 0
    queue_total = 0
    queue_done = 0
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            # Only the per-chunk lines count. The run header also prints
            # "... collected chunks", and a per-file line prints "collected
            # <source>"; counting either would corrupt the differential.
            if match := CHUNK_PATTERN.match(line):
                if match.group(1) == "collected":
                    collected += 1
                else:
                    reused += 1
            elif match := WORKER_PATTERN_RE.search(line):
                queue_done = max(queue_done, int(match.group(2)))
                queue_total = max(queue_total, int(match.group(3)))
    stat = path.stat()
    return {
        "log": str(path),
        "collected": collected,
        "reused": reused,
        "queueDone": queue_done,
        "queueTotal": queue_total,
        # The counter restarts at zero in a new log; identity detects that.
        "identity": f"{stat.st_dev}:{stat.st_ino}",
    }


def historical_rate(campaign_root: Path) -> tuple[float | None, int, float]:
    """Sustained fresh-collection rate from finished run logs.

    A completed run log is a clean measurement: its file name carries the start
    time, its last write marks the end, and its `collected` count is genuine
    fetching. Runs dominated by reuse are skipped — they measure a re-walk, not
    collection. This is what lets the tool answer "how long" while the current
    run is still re-walking and has nothing representative to sample.
    """
    logs = campaign_root / "logs"
    if not logs.is_dir():
        return None, 0, 0.0
    collected = 0
    minutes = 0.0
    for path in sorted(logs.glob("*.log")):
        match = re.search(r"(\d{8}-\d{6})", path.name)
        if not match:
            continue
        try:
            started = datetime.strptime(match.group(1), "%Y%m%d-%H%M%S").timestamp()
        except ValueError:
            continue
        counters = log_counters(path)
        fetched = counters["collected"]
        reused = counters["reused"]
        if fetched < MINIMUM_HISTORICAL_CHUNKS:
            continue
        if fetched + reused > 0 and fetched / (fetched + reused) < FRESH_SHARE_FOR_ETA:
            continue
        span = (path.stat().st_mtime - started) / 60
        if span <= 0:
            continue
        collected += fetched
        minutes += span
    if minutes <= 0 or collected == 0:
        return None, 0, 0.0
    return collected / minutes, collected, minutes


def worker_count() -> int:
    try:
        completed = subprocess.run(
            ["pgrep", "-f", WORKER_PATTERN],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return -1
    return len([line for line in completed.stdout.splitlines() if line.strip()])


def load_samples(path: Path) -> list[dict[str, object]]:
    if not path.is_file():
        return []
    samples = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            try:
                samples.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return samples


def append_sample(path: Path, sample: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(sample, sort_keys=True) + "\n")


def fresh_rate(
    samples: list[dict[str, object]],
    window_minutes: float,
) -> tuple[float | None, float, int, float | None]:
    """Chunks genuinely collected per minute over the trailing window.

    Only consecutive pairs from the same log contribute: a rotated log restarts
    its counter, and the drop across that boundary is not negative progress.

    The fourth value is the share of chunks in the window that were genuinely
    collected rather than reused. A rate measured while the workers are mostly
    re-walking says nothing about how fast the remaining fresh sources will go,
    so the caller uses this share to decide whether the rate can be projected.
    """
    if len(samples) < 2:
        return None, 0.0, len(samples), None
    horizon = samples[-1]["timestamp"] - window_minutes * 60
    recent = [s for s in samples if s["timestamp"] >= horizon]
    if len(recent) < 2:
        recent = samples[-2:]
    collected = 0
    reused = 0
    elapsed = 0.0
    used = 0
    for earlier, later in zip(recent, recent[1:]):
        if earlier.get("logIdentity") != later.get("logIdentity"):
            continue
        delta = later["collected"] - earlier["collected"]
        if delta < 0:
            continue
        collected += delta
        reused += max(0, later.get("reused", 0) - earlier.get("reused", 0))
        elapsed += later["timestamp"] - earlier["timestamp"]
        used += 1
    if used == 0 or elapsed <= 0:
        return None, 0.0, len(recent), None
    handled = collected + reused
    share = collected / handled if handled else None
    return collected / (elapsed / 60), elapsed, len(recent), share


def format_duration(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.0f} s"
    minutes = int(seconds // 60)
    if minutes < 60:
        return f"{minutes} min"
    hours, minutes = divmod(minutes, 60)
    return f"{hours} h {minutes:02d} min"


def measure(campaign_root: Path, window_minutes: float, samples_path: Path) -> dict:
    planned = read_manifest(campaign_root)
    finished, finished_seconds, finished_chunks = read_finished(campaign_root)
    log_path = active_log(campaign_root)
    counters = log_counters(log_path)

    remaining_names = [name for name in planned if name not in finished]
    remaining_seconds = sum(planned[name] for name in remaining_names)
    mean_chunk_seconds = (
        finished_seconds / finished_chunks if finished_chunks else 19.75
    )
    remaining_chunks = (
        remaining_seconds / mean_chunk_seconds if mean_chunk_seconds > 0 else 0.0
    )

    now = time.time()
    sample = {
        "timestamp": now,
        "collected": counters["collected"],
        "reused": counters["reused"],
        "logIdentity": counters["identity"],
        "finishedSources": len(finished),
        "finishedChunks": finished_chunks,
        "remainingSources": len(remaining_names),
    }
    append_sample(samples_path, sample)
    samples = load_samples(samples_path)
    rate, elapsed, sample_count, share = fresh_rate(samples, window_minutes)

    floor_seconds = remaining_chunks * REQUESTS_PER_CHUNK * float(
        os.environ.get("WISPR_MIN_REQUEST_INTERVAL", DEFAULT_MIN_REQUEST_INTERVAL)
    )
    # A rate measured while the workers are mostly re-walking already-collected
    # chunks does not describe the fresh collection still to come. Projecting it
    # produces a confident number that is simply wrong, so the ETA is withheld
    # until the sampled window is genuinely doing fresh work.
    representative = share is not None and share >= FRESH_SHARE_FOR_ETA
    history_rate, history_chunks, history_minutes = historical_rate(campaign_root)
    eta_seconds = None
    eta_basis = None
    if rate and rate > 0 and representative:
        eta_seconds = remaining_chunks / rate * 60
        eta_basis = "live"
    elif history_rate and history_rate > 0:
        # Fall back on the sustained rate of completed runs. It is the right
        # answer while the current run re-walks: the remaining sources will be
        # fetched at the same speed the earlier ones were.
        eta_seconds = remaining_chunks / history_rate * 60
        eta_basis = "historique"

    return {
        "generatedAt": datetime.now().isoformat(timespec="seconds"),
        "campaignRoot": str(campaign_root),
        "plannedSources": len(planned),
        "finishedSources": len(finished),
        "remainingSources": len(remaining_names),
        "finishedHours": finished_seconds / 3600,
        "remainingHours": remaining_seconds / 3600,
        "finishedChunks": finished_chunks,
        "remainingChunks": remaining_chunks,
        "meanChunkSeconds": mean_chunk_seconds,
        "activeLog": counters["log"],
        "collectedThisRun": counters["collected"],
        "reusedThisRun": counters["reused"],
        "queueDone": counters.get("queueDone", 0),
        "queueTotal": counters.get("queueTotal", 0),
        "workers": worker_count(),
        "freshChunksPerMinute": rate,
        "freshShareInWindow": share,
        "rateIsRepresentative": representative,
        "rateWindowSeconds": elapsed,
        "sampleCount": sample_count,
        "totalSamples": len(samples),
        "etaSeconds": eta_seconds,
        "etaBasis": eta_basis,
        "historicalChunksPerMinute": history_rate,
        "historicalChunks": history_chunks,
        "historicalMinutes": history_minutes,
        "rateLimitFloorSeconds": floor_seconds,
        "samplesPath": str(samples_path),
    }


def render(state: dict) -> str:
    lines = [
        "",
        f"VoxoL — campagne de transcription   {state['generatedAt'].replace('T', ' ')}",
        "=" * 68,
        f"  Sources    {state['finishedSources']}/{state['plannedSources']} terminées"
        f"   ({state['remainingSources']} restantes)",
        f"  Audio      {state['finishedHours']:.2f} h collectées"
        f"   |   {state['remainingHours']:.2f} h restantes",
        f"  Chunks     {state['finishedChunks']} collectés"
        f"   |   ~{state['remainingChunks']:.0f} restants"
        f" (à {state['meanChunkSeconds']:.1f} s/chunk)",
    ]

    workers = state["workers"]
    worker_text = "indisponible" if workers < 0 else f"{workers} actifs"
    lines.append(f"  Workers    {worker_text}")

    if state["queueTotal"]:
        lines.append(
            f"  File       ~{state['queueDone']}/{state['queueTotal']} par worker"
            f" sur le run courant"
        )

    collected = state["collectedThisRun"]
    reused = state["reusedThisRun"]
    if collected + reused > 0:
        share = collected / (collected + reused) * 100
        phase = "collecte fraîche" if share > 20 else "re-parcours (chunks déjà collectés)"
        lines.append(
            f"  Phase      {phase} — {collected} collectés / {reused} réutilisés"
            f" ({share:.1f}% frais)"
        )

    lines.append("-" * 68)

    if state["remainingSources"] == 0:
        lines.extend(
            [
                "  TERMINÉ — toutes les sources du manifeste ont un record.",
                "=" * 68,
                "",
            ]
        )
        return "\n".join(lines)

    rate = state["freshChunksPerMinute"]
    if rate is None:
        lines.append(
            f"  Débit      pas encore mesurable ({state['totalSamples']} échantillon(s))"
        )
        lines.append("             relancer dans quelques minutes pour un différentiel")
    elif rate <= 0:
        lines.append("  Débit      0 chunk frais sur la fenêtre observée")
        lines.append(
            "             les workers re-parcourent des fichiers déjà collectés ;"
        )
        lines.append(
            "             l'ETA arrivera quand ils atteindront les sources neuves"
        )
    else:
        lines.append(
            f"  Débit      {rate:.1f} chunks frais/min"
            f"  (mesuré sur {format_duration(state['rateWindowSeconds'])},"
            f" {state['sampleCount']} échantillons)"
        )

    history = state["historicalChunksPerMinute"]
    if history:
        lines.append(
            f"  Historique {history:.1f} chunks frais/min soutenus"
            f"  ({state['historicalChunks']} chunks"
            f" sur {format_duration(state['historicalMinutes'] * 60)} de runs terminés)"
        )

    eta = state["etaSeconds"]
    if eta:
        finish = datetime.now() + timedelta(seconds=eta)
        basis = state["etaBasis"]
        lines.append(
            f"  ETA        {format_duration(eta)}"
            f"   →   fin estimée vers {finish.strftime('%H:%M')}"
            f" le {finish.strftime('%d/%m')}"
        )
        if basis == "historique":
            share_text = (
                f"{state['freshShareInWindow'] * 100:.1f}%"
                if state["freshShareInWindow"] is not None
                else "0%"
            )
            lines.append(
                f"             basé sur le débit historique — la fenêtre courante"
                f" n'a que {share_text} de collecte fraîche"
            )
            lines.append(
                "             s'ajoute le temps de re-parcours avant d'atteindre"
                " les sources neuves"
            )
    elif rate and rate > 0 and not state["rateIsRepresentative"]:
        share = state["freshShareInWindow"]
        lines.append(
            f"  ETA        non projetable — seulement {share * 100:.1f}% de collecte"
            " fraîche, et aucun run terminé à comparer"
        )
    lines.append(
        f"  Plancher   {format_duration(state['rateLimitFloorSeconds'])}"
        " au débit maximal autorisé par le limiteur"
    )
    lines.extend(["=" * 68, f"  échantillons : {state['samplesPath']}", ""])
    return "\n".join(lines)


def main() -> int:
    arguments = parser().parse_args()
    campaign_root = arguments.campaign_root.resolve()
    if not campaign_root.is_dir():
        raise SystemExit(f"Campaign root not found: {campaign_root}")
    samples_path = (
        arguments.samples_path or campaign_root / "logs" / "eta-samples.jsonl"
    ).resolve()
    if arguments.reset:
        samples_path.unlink(missing_ok=True)

    try:
        while True:
            state = measure(campaign_root, arguments.window, samples_path)
            if arguments.json:
                print(json.dumps(state, indent=2, sort_keys=True), flush=True)
            else:
                if arguments.watch:
                    print("\033[2J\033[H", end="")
                print(render(state), flush=True)
            if not arguments.watch:
                return 0
            time.sleep(max(5.0, arguments.watch))
    except KeyboardInterrupt:
        print("\nArrêt de l'affichage. La collecte continue en arrière-plan.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
