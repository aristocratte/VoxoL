#!/usr/bin/env python3
"""Compare local ASR latency against the cloud competitor's, on the same clips.

VoxoL runs on the machine; Wispr Flow sends the audio to a server. That is a
structural difference no amount of model work changes, and it has never been
quantified here — every comparison so far has been about word error.

This times the cloud round trip a user actually waits through: upload the
audio, run the model, receive the text. The local figure comes from the
benchmark suite's own inference timings, so both sides measure the same thing,
the wall clock between "audio is ready" and "text exists".

Usage:
    HF unrelated; needs the signed-in Wispr Flow desktop session.

    ./measure-asr-latency.py --audio-dir <clips> --count 40 \\
        --local-report <benchmark report.json> --output <latency.json>
"""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request


SESSION_PATH = (
    Path.home()
    / "Library/Application Support/Wispr Flow/session.json"
)
SESSION_KEY = "sb-dodjkfqhwrzqjwkfnthl-auth-token"
API_BASE = "https://api.wisprflow.ai"


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--audio-dir", type=Path, required=True)
    result.add_argument("--count", type=int, default=40)
    result.add_argument("--language", default="fr")
    result.add_argument("--local-report", type=Path)
    result.add_argument("--output", type=Path, required=True)
    return result


def access_token() -> str:
    payload = json.loads(SESSION_PATH.read_text(encoding="utf-8"))
    raw = payload.get(SESSION_KEY)
    session = raw if isinstance(raw, dict) else json.loads(raw)
    token = session.get("access_token")
    if not token:
        raise SystemExit("No access token in the Wispr Flow session.")
    return str(token)


def wav_bytes(path: Path) -> bytes:
    """Convert to the 16 kHz mono PCM the endpoint expects."""
    completed = subprocess.run(
        [
            "ffmpeg", "-v", "error", "-i", str(path),
            "-ac", "1", "-ar", "16000", "-f", "wav", "-",
        ],
        capture_output=True,
        check=True,
    )
    return completed.stdout


def time_request(token: str, audio: bytes, language: str) -> tuple[int, float]:
    body = json.dumps(
        {
            "audio": base64.b64encode(audio).decode("ascii"),
            "language": language,
            "prompt": "",
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        f"{API_BASE}/llm/asr",
        data=body,
        headers={"Content-Type": "application/json", "Authorization": token},
    )
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            response.read()
            status = response.status
    except urllib.error.HTTPError as error:
        status = error.code
    except OSError:
        status = 0
    return status, (time.perf_counter() - start) * 1000


def percentiles(values: list[float]) -> dict[str, float]:
    ordered = sorted(values)
    if not ordered:
        return {}

    def at(fraction: float) -> float:
        index = min(len(ordered) - 1, int(len(ordered) * fraction))
        return ordered[index]

    return {
        "mean": statistics.mean(ordered),
        "p50": at(0.50),
        "p95": at(0.95),
        "p99": at(0.99),
        "min": ordered[0],
        "max": ordered[-1],
    }


def local_latency(report: Path | None) -> dict[str, float] | None:
    if report is None or not report.is_file():
        return None
    payload = json.loads(report.read_text(encoding="utf-8"))
    inference = (payload.get("latency") or {}).get("inference") or {}
    mapping = {
        "mean": "meanMilliseconds",
        "p50": "p50Milliseconds",
        "p95": "p95Milliseconds",
        "p99": "p99Milliseconds",
        "min": "minimumMilliseconds",
        "max": "maximumMilliseconds",
    }
    values = {
        name: float(inference[key]) for name, key in mapping.items() if key in inference
    }
    return values or None


def main() -> int:
    arguments = parser().parse_args()
    clips = sorted(
        path
        for path in arguments.audio_dir.rglob("*")
        if path.is_file()
        and path.suffix.lower() in {".wav", ".flac", ".mp3", ".m4a"}
        and not path.name.startswith("._")
    )[: arguments.count]
    if not clips:
        raise SystemExit(f"No audio under {arguments.audio_dir}")

    token = access_token()
    samples: list[float] = []
    failures = 0
    for index, clip in enumerate(clips, 1):
        status, elapsed = time_request(token, wav_bytes(clip), arguments.language)
        if status == 200:
            samples.append(elapsed)
        else:
            failures += 1
        print(f"  [{index}/{len(clips)}] {status} {elapsed:8.1f} ms", flush=True)
        # Stay inside the collector's own pacing so this probe measures latency
        # rather than provoking throttling.
        time.sleep(0.35)

    report = {
        "schemaVersion": "voxol-latency-comparison-v1",
        "clipCount": len(clips),
        "successCount": len(samples),
        "failureCount": failures,
        "cloudMilliseconds": percentiles(samples),
        "localMilliseconds": local_latency(arguments.local_report),
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
