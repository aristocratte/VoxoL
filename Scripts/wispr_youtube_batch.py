#!/usr/bin/env python3
"""Resumable YouTube/local-audio batch for the existing Wispr collector."""

from __future__ import annotations

import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import parse_qs, urlsplit


SCRIPT_DIR = Path(__file__).resolve().parent
VIDEO_ID = re.compile(r"[A-Za-z0-9_-]{6,32}\Z")
PLAYLIST_ID = re.compile(r"[A-Za-z0-9_-]{6,128}\Z")
YOUTUBE_HOSTS = {"youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "youtube-nocookie.com"}
URL_IN_LINE = re.compile(r"https?://[^\s<>()[\]|\"']+")


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def read_json(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected JSON object: {path}")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def youtube_source(value: str) -> tuple[str, str, str]:
    """Return (kind, id, canonical URL), rejecting lookalike domains."""
    parsed = urlsplit(value)
    host = (parsed.hostname or "").lower().removeprefix("www.")
    if parsed.scheme not in {"http", "https"} or host not in YOUTUBE_HOSTS:
        raise ValueError("expected a YouTube video or playlist URL")
    path = [part for part in parsed.path.split("/") if part]
    query = parse_qs(parsed.query)
    identifier = ""
    if host == "youtu.be" and path:
        identifier = path[0]
    elif path and path[0] in {"shorts", "live", "embed", "v"} and len(path) > 1:
        identifier = path[1]
    elif path and path[0] == "watch":
        identifier = query.get("v", [""])[0]
    playlist = query.get("list", [""])[0]
    if PLAYLIST_ID.fullmatch(playlist) and path and path[0] in {"playlist", "watch"}:
        return "playlist", playlist, f"https://www.youtube.com/playlist?list={playlist}"
    if VIDEO_ID.fullmatch(identifier):
        return "video", identifier, f"https://www.youtube.com/watch?v={identifier}"
    raise ValueError("no valid video or playlist ID in YouTube URL")


def expand_playlist(url: str, executable: str) -> tuple[list[tuple[str, str]], list[str]]:
    print(f"Listing playlist: {url}", flush=True)
    result = subprocess.run(
        [executable, "--flat-playlist", "--yes-playlist", "--no-warnings", "--print", "id", url],
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
    )
    identifiers = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    valid = [identifier for identifier in identifiers if VIDEO_ID.fullmatch(identifier)]
    if not valid:
        raise RuntimeError("playlist listing returned no valid video IDs")
    warnings = []
    if result.returncode:
        warnings.append(f"playlist listing was partial (yt-dlp exit {result.returncode})")
    if len(valid) != len(identifiers):
        warnings.append(f"{len(identifiers) - len(valid)} playlist entry/entries had no valid video ID")
    return [(identifier, f"https://www.youtube.com/watch?v={identifier}") for identifier in valid], warnings


def valid_audio(path: Path, ffprobe: str = "ffprobe") -> bool:
    if not path.is_file() or path.stat().st_size == 0:
        return False
    result = subprocess.run(
        [ffprobe, "-v", "error", "-show_entries", "format=duration:stream=codec_type", "-of", "json", str(path)],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode:
        return False
    try:
        probe = json.loads(result.stdout)
        duration = float(probe.get("format", {}).get("duration", 0))
        return math.isfinite(duration) and duration > 0 and any(
            stream.get("codec_type") == "audio" for stream in probe.get("streams", [])
        )
    except (ValueError, TypeError, AttributeError):
        return False


def download_video(item: dict[str, object], cache_dir: Path, executable: str, ffprobe: str) -> Path:
    identifier = str(item["video_id"])
    target = cache_dir / f"youtube-{identifier}.mp3"
    if not valid_audio(target, ffprobe):
        if target.exists():
            target.rename(target.with_name(f"{target.name}.invalid-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}"))
        cache_dir.mkdir(parents=True, exist_ok=True)
        template = cache_dir / f"youtube-{identifier}.%(ext)s"
        print(f"  downloading audio for {identifier}", flush=True)
        result = subprocess.run(
            [executable, "--no-playlist", "--continue", "--retries", "10", "--fragment-retries", "10",
             "--socket-timeout", "30", "--extract-audio", "--audio-format", "mp3", "--audio-quality", "0",
             "--output", str(template), str(item["url"])],
            capture_output=True,
            text=True,
            check=False,
        )
        if not valid_audio(target, ffprobe):
            raise RuntimeError(f"audio download failed (yt-dlp exit {result.returncode}); {result.stderr[-300:].strip()}")
    else:
        print(f"  cached audio verified for {identifier}", flush=True)
    write_json(
        cache_dir / f"youtube-{identifier}.source.json",
        {"provider": "YouTube", "video_id": identifier, "url": item["url"], "audio_sha256": sha256(target)},
    )
    return target


def source_lines(arguments: argparse.Namespace) -> list[str]:
    if arguments.resume:
        if arguments.sources or arguments.urls_file or arguments.urls_stdin:
            raise ValueError("--resume cannot be combined with new sources")
        return []
    values = [(source, True) for source in arguments.sources]
    if arguments.urls_file:
        values.extend((line, False) for line in arguments.urls_file.read_text(encoding="utf-8").splitlines())
    if arguments.urls_stdin:
        values.extend((line, False) for line in sys.stdin.read().splitlines())
    result = []
    for value, direct in values:
        for line in value.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            links = [match.group(0).rstrip(".,;") for match in URL_IN_LINE.finditer(line)]
            if links:
                youtube_links = []
                for link in links:
                    try:
                        youtube_source(link)
                        youtube_links.append(link)
                    except ValueError:
                        pass
                result.extend(youtube_links or links)
            elif direct or Path(line).expanduser().exists():
                result.append(line)
    return result


def resolve_items(sources: list[str], previous: list[dict[str, object]], executable: str) -> tuple[list[dict[str, object]], list[str]]:
    prior = {str(item["key"]): item for item in previous}
    result: list[dict[str, object]] = []
    seen: set[str] = set()
    errors: list[str] = []
    for source in sources:
        path = Path(source).expanduser()
        if path.exists():
            entries = [("local", str(path.resolve()), "")]
        else:
            try:
                kind, identifier, url = youtube_source(source)
                if kind == "video":
                    entries = [("video", identifier, url)]
                else:
                    videos, warnings = expand_playlist(url, executable)
                    errors.extend(f"{source}: {warning}" for warning in warnings)
                    entries = [("video", video_id, video_url) for video_id, video_url in videos]
            except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                errors.append(f"{source}: {error}")
                # A playlist may be temporarily unreachable during resume.
                # Continue its already discovered videos from the saved job.
                entries = [
                    (str(item["kind"]), str(item["video_id"]), str(item["url"]))
                    for item in previous
                    if item.get("origin_source") == source and item.get("kind") == "video"
                ]
        for kind, identifier, url in entries:
            key = f"{kind}:{identifier}"
            if key in seen:
                continue
            seen.add(key)
            item = dict(prior.get(key, {}))
            item.update({"key": key, "kind": kind, "video_id": identifier if kind == "video" else None, "url": url or None, "path": identifier if kind == "local" else None, "origin_source": source})
            result.append(item)
    return result, errors


def obtain_token(collector: Path) -> str:
    supplied = os.environ.get("WISPR_ACCESS_TOKEN", "")
    if supplied:
        return supplied
    result = subprocess.run(
        ["bash", str(collector), "--token-only"], capture_output=True, text=True, check=False,
    )
    token = result.stdout.strip()
    if result.returncode != 0 or not token:
        raise RuntimeError(result.stderr.strip() or "could not obtain a Wispr Flow access token")
    return token


def transcribe_item(
    index: int, total: int, item: dict[str, object], cache_dir: Path,
    yt_dlp: str, ffprobe: str, collector: Path, rate_file: Path, token: str,
) -> tuple[str, str | None, bool]:
    label = str(item["url"] or item["path"])
    video_id = str(item["video_id"] or index)
    print(f"[{index}/{total}] {label}", flush=True)
    try:
        audio = download_video(item, cache_dir, yt_dlp, ffprobe) if item["kind"] == "video" else Path(str(item["path"]))
        env = dict(
            os.environ,
            WISPR_DEFER_MANIFEST_REBUILD="1",
            WISPR_RATE_FILE=str(rate_file),
            WISPR_ACCESS_TOKEN=token,
            WISPR_LOG_PREFIX=f"[{index}/{total} {video_id}]",
        )
        if item["kind"] == "video":
            env.update(WISPR_SOURCE_URL=str(item["url"]), WISPR_SOURCE_VIDEO_ID=video_id)
        completed = subprocess.run(["bash", str(collector), str(audio)], env=env, check=False)
        if completed.returncode == 0:
            return "done", None, False
        return "transcription_failed", f"collector exit {completed.returncode}", completed.returncode == 42
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        return "download_failed", str(error), False


def run(arguments: argparse.Namespace) -> int:
    out_dir = Path(os.environ.get("WISPR_OUT_DIR", "~/Documents/wispr/transcripts")).expanduser()
    dataset_dir = Path(os.environ.get("WISPR_DATASET_DIR", str(out_dir / "dataset"))).expanduser()
    jobs_dir = out_dir / "youtube-jobs"
    latest_path = jobs_dir / "latest.json"
    if arguments.resume:
        latest = read_json(latest_path)
        job_path = jobs_dir / str(latest["job_file"])
        job = read_json(job_path)
        sources = [str(source) for source in job["sources"]]
    else:
        sources = source_lines(arguments)
        if not sources:
            raise ValueError("no YouTube URLs or audio paths supplied")
        job_id = hashlib.sha256("\n".join(sources).encode()).hexdigest()[:16]
        job_path = jobs_dir / f"job-{job_id}.json"
        job = read_json(job_path) if job_path.exists() else {"schema_version": 1, "sources": sources, "items": []}
        write_json(job_path, job)
        write_json(latest_path, {"job_file": job_path.name})

    yt_dlp = os.environ.get("WISPR_YTDLP", "yt-dlp")
    ffprobe = os.environ.get("WISPR_FFPROBE", "ffprobe")
    if any(source.startswith(("https://", "http://")) for source in sources) and not shutil.which(yt_dlp):
        raise RuntimeError("yt-dlp is required for YouTube URLs")
    if not shutil.which(ffprobe):
        raise RuntimeError("ffprobe is required to verify downloaded audio")
    items, errors = resolve_items(sources, list(job.get("items", [])), yt_dlp)
    for error in errors:
        print(f"source error: {error}", file=sys.stderr, flush=True)
    job["items"] = items
    job["source_errors"] = errors
    write_json(job_path, job)
    cache_dir = out_dir / "youtube-audio"
    collector = SCRIPT_DIR / "wispr-transcribe.sh"
    requested_parallel = getattr(arguments, "parallel", None)
    setting = requested_parallel if requested_parallel is not None else (
        os.environ.get("WISPR_PARALLEL_VIDEOS") or job.get("parallel_videos") or 3
    )
    parallel = int(setting)
    if not 1 <= parallel <= 8:
        raise ValueError("parallel video count must be between 1 and 8")
    job["parallel_videos"] = parallel
    job["complete"] = False
    write_json(job_path, job)
    pending = iter((index, item) for index, item in enumerate(items, 1) if item.get("status") != "done")
    # Refresh once for the batch. Concurrent workers must not race over the
    # desktop session's rotating refresh token.
    token = obtain_token(collector) if any(item.get("status") != "done" for item in items) else ""
    rate_file = jobs_dir / "request-rate.txt"
    with ThreadPoolExecutor(max_workers=parallel) as pool:
        active = {}

        def schedule_next() -> bool:
            try:
                index, item = next(pending)
            except StopIteration:
                return False
            item["status"] = "running"
            item["error"] = None
            job["updated_at_utc"] = datetime.now(timezone.utc).isoformat()
            write_json(job_path, job)
            future = pool.submit(
                transcribe_item, index, len(items), item, cache_dir,
                yt_dlp, ffprobe, collector, rate_file, token,
            )
            active[future] = item
            return True

        for _ in range(parallel):
            if not schedule_next():
                break
        auth_failed = False
        while active:
            completed, _ = wait(active, return_when=FIRST_COMPLETED)
            for future in completed:
                item = active.pop(future)
                try:
                    status, error, unauthorized = future.result()
                except Exception as failure:
                    status, error, unauthorized = "transcription_failed", f"worker failed: {failure}", False
                item["status"] = status
                item["error"] = error
                if error:
                    print(f"  {item['video_id'] or item['path']}: {status}: {error}", file=sys.stderr, flush=True)
                if unauthorized:
                    auth_failed = True
                    errors.append(f"{item['url'] or item['path']}: authentication failed; no new video started")
                job["updated_at_utc"] = datetime.now(timezone.utc).isoformat()
                write_json(job_path, job)
            if not auth_failed:
                for _ in range(parallel - len(active)):
                    if not schedule_next():
                        break
    rebuilt = subprocess.run(
        [sys.executable, str(SCRIPT_DIR / "wispr_rebuild_manifests.py"), "--dataset-dir", str(dataset_dir)],
        check=False,
    )
    failed = [item for item in items if item.get("status") != "done"]
    job["source_errors"] = errors
    job["complete"] = not errors and not failed and rebuilt.returncode == 0
    write_json(job_path, job)
    print(f"Batch: {len(items) - len(failed)}/{len(items)} complete; {len(errors)} source error(s); job {job_path}")
    return 0 if job["complete"] else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--urls-file", type=Path, help="Text file with one YouTube URL per line")
    parser.add_argument("--urls-stdin", action="store_true", help="Read pasted URLs, one per line, until EOF")
    parser.add_argument("--resume", action="store_true", help="Resume the latest persisted batch")
    parser.add_argument("--parallel", type=int, help="Videos to process concurrently (default: 3, max: 8)")
    parser.add_argument("sources", nargs="*", help="YouTube video/playlist URLs or local audio files/folders")
    arguments = parser.parse_args()
    try:
        out_dir = Path(os.environ.get("WISPR_OUT_DIR", "~/Documents/wispr/transcripts")).expanduser()
        jobs_dir = out_dir / "youtube-jobs"
        jobs_dir.mkdir(parents=True, exist_ok=True)
        with (jobs_dir / "collector.lock").open("a+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise RuntimeError("another Wispr YouTube batch is already running") from error
            return run(arguments)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"Wispr batch: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
