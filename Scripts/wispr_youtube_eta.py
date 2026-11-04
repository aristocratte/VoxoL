#!/usr/bin/env python3
"""Estimate the end of a Wispr YouTube batch from durable chunk results."""

from __future__ import annotations

from datetime import datetime, timezone
import json
import math
from pathlib import Path
from statistics import median
import time


def estimate(job: dict[str, object] | None, records_dir: Path, *, running: bool, now: float | None = None) -> dict[str, object]:
    now = time.time() if now is None else now
    items = job.get("items", []) if isinstance(job, dict) else []
    if not isinstance(items, list):
        items = []
    known_counts: list[int] = []
    completed_chunks = failed_chunks = 0
    recent_successes: list[float] = []
    unknown_remaining = 0

    for item in items:
        if not isinstance(item, dict):
            continue
        video_id = item.get("video_id")
        candidates = list(records_dir.glob(f"youtube-{video_id}-*/segmentation.json")) if video_id else []
        if not candidates:
            if item.get("status") != "done":
                unknown_remaining += 1
            continue
        segmentation_path = max(candidates, key=lambda path: path.stat().st_mtime)
        try:
            chunks = json.loads(segmentation_path.read_text(encoding="utf-8"))["chunks"]
            if not isinstance(chunks, list) or not chunks:
                raise ValueError("missing chunks")
        except (OSError, ValueError, KeyError, TypeError):
            if item.get("status") != "done":
                unknown_remaining += 1
            continue
        known_counts.append(len(chunks))
        if item.get("status") == "done":
            completed_chunks += len(chunks)
            continue
        results_dir = segmentation_path.parent / "results"
        for chunk in chunks:
            try:
                state_file = results_dir / f"chunk_{int(chunk['chunk']):04d}.state.json"
                state = json.loads(state_file.read_text(encoding="utf-8"))
                raw, edited = state.get("raw_http_status"), state.get("edited_http_status")
                if raw == "200" and edited == "200":
                    completed_chunks += 1
                    modified = state_file.stat().st_mtime
                    if now - 600 <= modified <= now + 5:
                        recent_successes.append(modified)
                elif raw not in (None, "pending", "200") or edited not in (None, "pending", "200"):
                    failed_chunks += 1
            except (OSError, ValueError, TypeError, KeyError, AttributeError):
                continue

    known_total = sum(known_counts)
    typical_chunks = round(median(known_counts)) if known_counts else 0
    estimated_total = known_total + typical_chunks * unknown_remaining
    remaining = max(0, known_total - completed_chunks) + typical_chunks * unknown_remaining
    at = None
    minutes = None
    if running and remaining > 0 and len(recent_successes) >= 5:
        recent_successes.sort()
        if recent_successes[-1] - recent_successes[0] >= 30:
            observed = max(60.0, now - recent_successes[0])
            seconds_per_chunk = observed / len(recent_successes)
            remaining_seconds = remaining * seconds_per_chunk
            if math.isfinite(remaining_seconds) and 0 < remaining_seconds < 30 * 86400:
                at = datetime.fromtimestamp(now + remaining_seconds, timezone.utc).isoformat()
                minutes = math.ceil(remaining_seconds / 60)

    return {
        "at": at,
        "minutesRemaining": minutes,
        "completedChunks": completed_chunks,
        "estimatedTotalChunks": estimated_total or None,
        "knownVideos": len(known_counts),
        "totalVideos": len(items),
        "unknownVideos": unknown_remaining,
        "failedChunks": failed_chunks,
        "recentCompletedChunks": len(recent_successes),
        "provisional": unknown_remaining > 0 or failed_chunks > 0,
    }
