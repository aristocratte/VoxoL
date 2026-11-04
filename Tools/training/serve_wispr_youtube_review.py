#!/usr/bin/env python3
"""Local audio review for the frozen YouTube training handoff."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import secrets
import threading
from urllib.parse import parse_qs, unquote, urlsplit
import webbrowser

try:
    from Tools.training.prepare_wispr_youtube_handoff import load_global_approval, read_jsonl, sha256, write_json, write_jsonl
except ModuleNotFoundError:
    from prepare_wispr_youtube_handoff import load_global_approval, read_jsonl, sha256, write_json, write_jsonl


MAX_REQUEST_BYTES = 64 * 1024
MAX_TEXT_LENGTH = 12_000
MAX_NOTES_LENGTH = 2_000


def validate_review(item: dict[str, object], payload: dict[str, object], timestamp: str) -> dict[str, object]:
    status = payload.get("status")
    if status not in {"verified", "skipped"}:
        raise ValueError("Status must be verified or skipped")
    notes = str(payload.get("notes", "")).strip()
    if len(notes) > MAX_NOTES_LENGTH:
        raise ValueError("Notes are too long")
    if status == "skipped":
        return {"status": "skipped", "notes": notes, "reviewed_at_utc": timestamp}
    if payload.get("audio_confirmed") is not True:
        raise ValueError("Confirm that you listened to the audio")
    verify_asr = payload.get("verify_asr") is True
    verify_qwen = payload.get("verify_qwen") is True
    if not verify_asr and not verify_qwen:
        raise ValueError("Select at least one label to verify")
    asr_text = " ".join(str(payload.get("asr_text", "")).split()) if verify_asr else ""
    qwen_target = " ".join(str(payload.get("qwen_target", "")).split()) if verify_qwen else ""
    if verify_asr and not asr_text:
        raise ValueError("A verified ASR transcript cannot be empty")
    if verify_qwen and (not qwen_target or not str(item.get("voxol_raw", "")).strip()):
        raise ValueError("A Qwen label needs a target and the matching VoxoL raw output")
    if max(len(asr_text), len(qwen_target)) > MAX_TEXT_LENGTH:
        raise ValueError("A label is too long")
    return {
        "status": "verified",
        "verify_asr": verify_asr,
        "verify_qwen": verify_qwen,
        "asr_text": asr_text,
        "qwen_target": qwen_target,
        "audio_confirmed": True,
        "notes": notes,
        "reviewed_at_utc": timestamp,
    }


def export_reviews(queue: list[dict[str, object]], state: dict[str, object], root: Path) -> dict[str, object]:
    reviews = state.get("reviews", {})
    if not isinstance(reviews, dict):
        raise ValueError("Invalid review state")
    rows: list[dict[str, object]] = []
    counts = Counter()
    by_split = Counter()
    for item in queue:
        review = reviews.get(str(item["id"]))
        if not isinstance(review, dict):
            continue
        counts[str(review.get("status", "unknown"))] += 1
        if review.get("status") != "verified":
            continue
        by_split[str(item["split"])] += 1
        rows.append({
            "id": item["id"],
            "audio_path": item["audio_path"],
            "audio_sha256": item["audio_sha256"],
            "recording_id": item["recording_id"],
            "source_video_id": item["source_video_id"],
            "language": item["language"],
            "split": item["split"],
            "asr_text": review.get("asr_text", "") if review.get("verify_asr") else "",
            "qwen_raw": item["voxol_raw"] if review.get("verify_qwen") else "",
            "qwen_target": review.get("qwen_target", "") if review.get("verify_qwen") else "",
            "verify_asr": review.get("verify_asr") is True,
            "verify_qwen": review.get("verify_qwen") is True,
            "audio_verified": True,
            "humanReviewed": True,
            "approved": False,
            "reviewed_at_utc": review["reviewed_at_utc"],
            "notes": review.get("notes", ""),
            "source": "local-manual-audio-review",
        })
    write_jsonl(root / "human-reviewed.jsonl", rows)
    handoff = json.loads((root / "handoff.json").read_text(encoding="utf-8"))
    approval = load_global_approval(root, handoff)
    summary = {
        "schema": "voxol-youtube-manual-review-summary-v1",
        "queue_sha256": state["queue_sha256"],
        "queue_count": len(queue),
        "globally_approved_count": approval["segment_count"] if approval else 0,
        "verified_count": len(rows),
        "asr_verified_count": sum(row["verify_asr"] for row in rows),
        "qwen_verified_count": sum(row["verify_qwen"] for row in rows),
        "review_statuses": dict(sorted(counts.items())),
        "verified_by_split": dict(sorted(by_split.items())),
        "training_approved_count": 0,
        "updated_at_utc": state.get("updated_at_utc"),
    }
    write_json(root / "human-review-summary.json", summary)
    return summary


class ReviewApplication:
    def __init__(self, root: Path, html_path: Path) -> None:
        self.root = root.resolve()
        self.html_path = html_path
        self.handoff = json.loads((root / "handoff.json").read_text(encoding="utf-8"))
        self.queue_path = root / "review-queue.jsonl"
        if sha256(self.queue_path) != self.handoff["queue_sha256"]:
            raise RuntimeError("The frozen review queue changed")
        self.queue = read_jsonl(self.queue_path)
        self.items = {str(item["id"]): item for item in self.queue}
        self.state_path = root / "review-state.json"
        self.dataset_root = Path(str(self.handoff["dataset_root"])).resolve()
        self.token = secrets.token_urlsafe(24)
        self.lock = threading.Lock()
        self.check_state()
        export_reviews(self.queue, self.state(), self.root)

    def state(self) -> dict[str, object]:
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        if state.get("queue_sha256") != self.handoff["queue_sha256"]:
            raise RuntimeError("Review state does not match the frozen queue")
        return state

    def check_state(self) -> None:
        self.state()

    def index(self) -> dict[str, object]:
        approval = load_global_approval(self.root, self.handoff)
        with self.lock:
            state = self.state()
            reviews = state["reviews"]
        return {
            "items": [{
                "id": item["id"],
                "language": item["language"],
                "split": item["split"],
                "video": item["source_video_id"],
                "chunk": item["chunk"],
                "priority": item["priority"],
                "flags": item["flags"],
                "candidate": item["qwen_candidate_status"],
                "review_status": reviews.get(str(item["id"]), {}).get("status", "pending"),
            } for item in self.queue],
            "summary": {
                "queue_count": len(self.queue),
                "globally_approved_count": approval["segment_count"] if approval else 0,
                "verified_count": sum(row.get("status") == "verified" for row in reviews.values()),
                "skipped_count": sum(row.get("status") == "skipped" for row in reviews.values()),
            },
        }

    def item(self, identifier: str) -> dict[str, object]:
        item = self.items[identifier]
        with self.lock:
            review = self.state()["reviews"].get(identifier)
        return {"item": item, "review": review}

    def audio(self, identifier: str) -> Path:
        item = self.items[identifier]
        relative = Path(str(item["audio_path"]))
        audio = (self.dataset_root / relative).resolve()
        if relative.is_absolute() or not audio.is_relative_to(self.dataset_root) or not audio.is_file():
            raise FileNotFoundError(identifier)
        if sha256(audio) != item["audio_sha256"]:
            raise ValueError("Audio changed since the queue was frozen")
        return audio

    def save(self, identifier: str, payload: dict[str, object]) -> dict[str, object]:
        item = self.items[identifier]
        # A label cannot be marked audio-verified against a changed clip.
        if payload.get("status") == "verified":
            self.audio(identifier)
        timestamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        review = validate_review(item, payload, timestamp)
        with self.lock:
            state = self.state()
            state["reviews"][identifier] = review
            state["updated_at_utc"] = timestamp
            write_json(self.state_path, state)
            summary = export_reviews(self.queue, state, self.root)
        return {"review": review, "summary": summary}

    def html(self) -> bytes:
        return self.html_path.read_text(encoding="utf-8").replace("__REVIEW_TOKEN__", json.dumps(self.token)).encode("utf-8")


def request_handler(app: ReviewApplication) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "VoxoLYouTubeReview/1"

        def security_headers(self) -> None:
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; media-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")

        def respond(self, status: HTTPStatus, content_type: str, data: bytes) -> None:
            self.send_response(status)
            self.security_headers()
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def json_response(self, status: HTTPStatus, payload: object) -> None:
            self.respond(status, "application/json; charset=utf-8", json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

        def authorized(self, query: str) -> bool:
            token = self.headers.get("X-VoxoL-Review-Token") or parse_qs(query).get("token", [""])[0]
            return secrets.compare_digest(token, app.token)

        def do_GET(self) -> None:
            url = urlsplit(self.path)
            if url.path == "/":
                self.respond(HTTPStatus.OK, "text/html; charset=utf-8", app.html())
                return
            if not self.authorized(url.query):
                self.json_response(HTTPStatus.FORBIDDEN, {"error": "Invalid review session"})
                return
            if url.path == "/api/index":
                self.json_response(HTTPStatus.OK, app.index())
                return
            match = re.fullmatch(r"/api/item/([^/]+)", url.path)
            if match:
                try:
                    self.json_response(HTTPStatus.OK, app.item(unquote(match.group(1))))
                except KeyError:
                    self.json_response(HTTPStatus.NOT_FOUND, {"error": "Unknown item"})
                return
            match = re.fullmatch(r"/audio/([^/]+)", url.path)
            if match:
                try:
                    audio = app.audio(unquote(match.group(1)))
                    self.send_audio(audio)
                except KeyError:
                    self.json_response(HTTPStatus.NOT_FOUND, {"error": "Unknown audio"})
                except FileNotFoundError:
                    self.json_response(HTTPStatus.NOT_FOUND, {"error": "Reconnect the dataset SSD"})
                except ValueError as error:
                    self.json_response(HTTPStatus.CONFLICT, {"error": str(error)})
                return
            self.json_response(HTTPStatus.NOT_FOUND, {"error": "Not found"})

        def do_POST(self) -> None:
            url = urlsplit(self.path)
            if not self.authorized(url.query):
                self.json_response(HTTPStatus.FORBIDDEN, {"error": "Invalid review session"})
                return
            match = re.fullmatch(r"/api/review/([^/]+)", url.path)
            if not match:
                self.json_response(HTTPStatus.NOT_FOUND, {"error": "Not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_REQUEST_BYTES:
                    raise ValueError("Invalid request size")
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict):
                    raise ValueError("Expected a JSON object")
                result = app.save(unquote(match.group(1)), payload)
                self.json_response(HTTPStatus.OK, result)
            except KeyError:
                self.json_response(HTTPStatus.NOT_FOUND, {"error": "Unknown item"})
            except (ValueError, json.JSONDecodeError) as error:
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": str(error)})
            except FileNotFoundError:
                self.json_response(HTTPStatus.CONFLICT, {"error": "Reconnect the dataset SSD"})

        def send_audio(self, audio: Path) -> None:
            size = audio.stat().st_size
            start, end = 0, size - 1
            header = self.headers.get("Range")
            if header:
                match = re.fullmatch(r"bytes=(\d*)-(\d*)", header)
                if not match or not (match.group(1) or match.group(2)):
                    self.json_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, {"error": "Invalid audio range"})
                    return
                if match.group(1):
                    start = int(match.group(1))
                if not match.group(1):
                    start = max(0, size - int(match.group(2)))
                elif match.group(2):
                    end = min(int(match.group(2)), end)
                if start > end or start >= size:
                    self.json_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, {"error": "Invalid audio range"})
                    return
            length = end - start + 1
            self.send_response(HTTPStatus.PARTIAL_CONTENT if header else HTTPStatus.OK)
            self.security_headers()
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            if header:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            with audio.open("rb") as source:
                source.seek(start)
                remaining = length
                while remaining:
                    block = source.read(min(64 * 1024, remaining))
                    if not block:
                        break
                    self.wfile.write(block)
                    remaining -= len(block)

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--handoff-root", type=Path, required=True)
    parser.add_argument("--port", type=int, default=62582)
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("Port must be between 1 and 65535")
    app = ReviewApplication(args.handoff_root, Path(__file__).with_name("wispr_youtube_review.html"))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), request_handler(app))
    url = f"http://127.0.0.1:{args.port}/"
    print(f"YouTube audio review: {url}", flush=True)
    print("Progress is saved to the SSD after every review.", flush=True)
    if not args.no_open:
        threading.Timer(0.35, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
