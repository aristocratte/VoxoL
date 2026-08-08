#!/usr/bin/env python3
"""Serve the VoxoL Wispr teacher review workflow on localhost."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import threading
from urllib.parse import unquote, urlsplit
import webbrowser

try:
    from Tools.training.prepare_wispr_teacher_review import write_json, write_jsonl
except ModuleNotFoundError:
    from prepare_wispr_teacher_review import write_json, write_jsonl


REVIEW_STATUSES = {"accepted", "corrected", "skipped"}
MAX_REQUEST_BYTES = 128 * 1024
MAX_TRANSCRIPT_CHARACTERS = 12_000
MAX_NOTES_CHARACTERS = 2_000


def read_json(path: Path) -> dict[str, object]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError(f"Expected a JSON object: {path}")
    return payload


def public_queue(queue: dict[str, object]) -> dict[str, object]:
    return {
        **queue,
        "items": [
            {
                key: value
                for key, value in dict(item).items()
                if key != "audioPath"
            }
            for item in list(queue["items"])
        ],
    }


def validated_review(
    item: dict[str, object],
    payload: dict[str, object],
    timestamp: str,
) -> dict[str, object]:
    status = str(payload.get("status", ""))
    if status not in REVIEW_STATUSES:
        raise ValueError(f"Unsupported review status: {status}")
    notes = " ".join(str(payload.get("notes", "")).split())
    if len(notes) > MAX_NOTES_CHARACTERS:
        raise ValueError("Review notes are too long.")
    if status == "accepted":
        transcript = str(item["rawTranscript"])
    elif status == "corrected":
        transcript = " ".join(str(payload.get("transcript", "")).split())
        if not transcript:
            raise ValueError("A corrected transcript cannot be empty.")
    else:
        transcript = ""
    if len(transcript) > MAX_TRANSCRIPT_CHARACTERS:
        raise ValueError("The reviewed transcript is too long.")
    return {
        "notes": notes,
        "reviewedAt": timestamp,
        "status": status,
        "transcript": transcript,
    }


def export_reviews(
    queue: dict[str, object],
    state: dict[str, object],
    review_root: Path,
) -> dict[str, object]:
    reviews = dict(state.get("reviews", {}))
    rows = []
    counts = Counter()
    language_counts = Counter()
    split_counts = Counter()
    for item_value in list(queue["items"]):
        item = dict(item_value)
        review = reviews.get(str(item["id"]))
        if not isinstance(review, dict):
            continue
        status = str(review.get("status", ""))
        counts[status] += 1
        if status not in {"accepted", "corrected"}:
            continue
        language_counts[str(item["language"])] += 1
        split_counts[str(item["split"])] += 1
        rows.append(
            {
                "audio_filepath": item["audioPath"],
                "audio_sha256": item["audioSHA256"],
                "duration": item["durationSeconds"],
                "id": item["id"],
                "language": item["language"],
                "notes": review.get("notes", ""),
                "recording_id": item["recordingID"],
                "review_status": status,
                "reviewed_at": review["reviewedAt"],
                "speaker_id": item["speakerID"],
                "split": item["split"],
                "teacher_edited": item["editedTranscript"],
                "teacher_raw": item["rawTranscript"],
                "text": review["transcript"],
            }
        )
    summary = {
        "acceptedForTraining": len(rows),
        "byLanguage": dict(sorted(language_counts.items())),
        "bySplit": dict(sorted(split_counts.items())),
        "queueContentSHA256": queue["queueContentSHA256"],
        "queueItemCount": len(list(queue["items"])),
        "reviewCounts": dict(sorted(counts.items())),
        "schemaVersion": "voxol-teacher-audit-summary-v1",
        "updatedAt": state.get("updatedAt"),
    }
    write_jsonl(review_root / "reviewed.jsonl", rows)
    write_json(review_root / "review-summary.json", summary)
    return summary


class ReviewApplication:
    def __init__(self, review_root: Path, html_path: Path) -> None:
        self.review_root = review_root
        self.html_path = html_path
        self.queue_path = review_root / "queue.json"
        self.state_path = review_root / "review-state.json"
        self.queue = read_json(self.queue_path)
        self.items = {
            str(item["id"]): dict(item)
            for item in list(self.queue["items"])
        }
        self.token = secrets.token_urlsafe(24)
        self.lock = threading.Lock()
        state = read_json(self.state_path)
        if state.get("queueContentSHA256") != self.queue.get(
            "queueContentSHA256"
        ):
            raise RuntimeError("Review state and queue do not match.")
        export_reviews(self.queue, state, self.review_root)

    def session(self) -> dict[str, object]:
        with self.lock:
            state = read_json(self.state_path)
        return {
            "queue": public_queue(self.queue),
            "state": state,
        }

    def save_review(
        self,
        identifier: str,
        payload: dict[str, object],
    ) -> dict[str, object]:
        item = self.items.get(identifier)
        if item is None:
            raise KeyError(identifier)
        timestamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        review = validated_review(item, payload, timestamp)
        with self.lock:
            state = read_json(self.state_path)
            reviews = dict(state.get("reviews", {}))
            reviews[identifier] = review
            state["reviews"] = reviews
            state["updatedAt"] = timestamp
            write_json(self.state_path, state)
            summary = export_reviews(self.queue, state, self.review_root)
        return {"review": review, "summary": summary}

    def html(self) -> bytes:
        template = self.html_path.read_text(encoding="utf-8")
        return template.replace(
            "__VOXOL_REVIEW_TOKEN__",
            json.dumps(self.token),
        ).encode()


def request_handler(application: ReviewApplication) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "VoxoLTeacherReview/1"

        def log_message(self, format_string: str, *arguments: object) -> None:
            print(
                f"[review] {self.address_string()} "
                + format_string % arguments,
                flush=True,
            )

        def security_headers(self) -> None:
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; style-src 'self' 'unsafe-inline'; "
                "script-src 'self' 'unsafe-inline'; media-src 'self'; "
                "connect-src 'self'; img-src 'self' data:; "
                "frame-ancestors 'none'; base-uri 'none'",
            )

        def json_response(
            self,
            payload: object,
            status: HTTPStatus = HTTPStatus.OK,
        ) -> None:
            body = json.dumps(
                payload,
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode()
            self.send_response(status)
            self.security_headers()
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def error_response(
            self,
            status: HTTPStatus,
            message: str,
        ) -> None:
            self.json_response({"error": message}, status)

        def authorized(self, query: str = "") -> bool:
            header_token = self.headers.get("X-VoxoL-Review-Token")
            query_token = ""
            for part in query.split("&"):
                if part.startswith("token="):
                    query_token = unquote(part[6:])
                    break
            return secrets.compare_digest(
                str(header_token or query_token),
                application.token,
            )

        def do_GET(self) -> None:
            parsed = urlsplit(self.path)
            if parsed.path == "/":
                body = application.html()
                self.send_response(HTTPStatus.OK)
                self.security_headers()
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if not self.authorized(parsed.query):
                self.error_response(HTTPStatus.FORBIDDEN, "Invalid session.")
                return
            if parsed.path == "/api/session":
                self.json_response(application.session())
                return
            audio_match = re.fullmatch(r"/audio/(.+)", parsed.path)
            if audio_match:
                identifier = unquote(audio_match.group(1))
                item = application.items.get(identifier)
                if item is None:
                    self.error_response(HTTPStatus.NOT_FOUND, "Unknown audio.")
                    return
                self.send_audio(Path(str(item["audioPath"])))
                return
            self.error_response(HTTPStatus.NOT_FOUND, "Not found.")

        def do_POST(self) -> None:
            parsed = urlsplit(self.path)
            if not self.authorized(parsed.query):
                self.error_response(HTTPStatus.FORBIDDEN, "Invalid session.")
                return
            match = re.fullmatch(r"/api/reviews/(.+)", parsed.path)
            if not match:
                self.error_response(HTTPStatus.NOT_FOUND, "Not found.")
                return
            try:
                content_length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self.error_response(
                    HTTPStatus.BAD_REQUEST,
                    "Invalid request size.",
                )
                return
            if not 0 < content_length <= MAX_REQUEST_BYTES:
                self.error_response(
                    HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                    "Invalid request size.",
                )
                return
            try:
                payload = json.loads(self.rfile.read(content_length))
                if not isinstance(payload, dict):
                    raise ValueError("Expected a JSON object.")
                result = application.save_review(
                    unquote(match.group(1)),
                    payload,
                )
            except KeyError:
                self.error_response(HTTPStatus.NOT_FOUND, "Unknown item.")
                return
            except (json.JSONDecodeError, ValueError) as error:
                self.error_response(HTTPStatus.BAD_REQUEST, str(error))
                return
            self.json_response(result)

        def send_audio(self, audio_path: Path) -> None:
            if not audio_path.is_file():
                self.error_response(
                    HTTPStatus.NOT_FOUND,
                    "Audio file is unavailable. Reconnect the dataset drive.",
                )
                return
            size = audio_path.stat().st_size
            start = 0
            end = size - 1
            status = HTTPStatus.OK
            range_header = self.headers.get("Range")
            if range_header:
                match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header)
                if not match:
                    self.error_response(
                        HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE,
                        "Invalid audio range.",
                    )
                    return
                if match.group(1):
                    start = int(match.group(1))
                if match.group(2):
                    end = min(int(match.group(2)), end)
                if start > end or start >= size:
                    self.error_response(
                        HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE,
                        "Invalid audio range.",
                    )
                    return
                status = HTTPStatus.PARTIAL_CONTENT
            length = end - start + 1
            self.send_response(status)
            self.security_headers()
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(length))
            if status == HTTPStatus.PARTIAL_CONTENT:
                self.send_header(
                    "Content-Range",
                    f"bytes {start}-{end}/{size}",
                )
            self.end_headers()
            with audio_path.open("rb") as stream:
                stream.seek(start)
                remaining = length
                while remaining:
                    chunk = stream.read(min(64 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--review-root", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-open", action="store_true")
    arguments = parser.parse_args()
    if not 1 <= arguments.port <= 65_535:
        raise SystemExit("--port must be between 1 and 65535.")
    html_path = Path(__file__).with_name("wispr_teacher_review.html")
    application = ReviewApplication(arguments.review_root, html_path)
    server = ThreadingHTTPServer(
        ("127.0.0.1", arguments.port),
        request_handler(application),
    )
    url = f"http://127.0.0.1:{arguments.port}/"
    print(f"VoxoL teacher review: {url}", flush=True)
    print("Press Control-C to stop. Progress is saved after every action.", flush=True)
    if not arguments.no_open:
        threading.Timer(0.35, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
