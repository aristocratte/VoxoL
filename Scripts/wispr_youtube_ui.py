#!/usr/bin/env python3
"""Local browser interface for pasting YouTube links into the Wispr collector."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import threading
import time
import webbrowser

from wispr_youtube_eta import estimate


SCRIPT_DIR = Path(__file__).resolve().parent
MAX_REQUEST_BYTES = 2 * 1024 * 1024


class CollectionUI:
    def __init__(self, out_dir: Path) -> None:
        self.out_dir = out_dir
        self.dataset_dir = Path(os.environ.get("WISPR_DATASET_DIR", str(out_dir / "dataset"))).expanduser()
        self.jobs_dir = out_dir / "youtube-jobs"
        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        self.token = secrets.token_urlsafe(32)
        self.process: subprocess.Popen[bytes] | None = None
        self.log_path = self.jobs_dir / "ui-current.log"
        self.process_path = self.jobs_dir / "ui-current-process.json"
        self.lock = threading.Lock()
        self.eta_cache: tuple[float, dict[str, object]] | None = None

    def save_process_reference(self, pid: int) -> None:
        temporary = self.process_path.with_name(f"{self.process_path.name}.tmp.{os.getpid()}")
        temporary.write_text(json.dumps({"pid": pid}) + "\n", encoding="utf-8")
        os.replace(temporary, self.process_path)

    def attached_batch_pid(self) -> int | None:
        try:
            pid = int(json.loads(self.process_path.read_text(encoding="utf-8"))["pid"])
            if pid <= 0 or os.getpgid(pid) != pid or not self.batch_lock_held():
                return None
            command = subprocess.run(
                ["ps", "-p", str(pid), "-o", "command="],
                capture_output=True, text=True, timeout=3, check=False,
            )
            if command.returncode == 0 and str(SCRIPT_DIR / "wispr_youtube_batch.py") in command.stdout:
                return pid
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
            pass
        return None

    def batch_lock_held(self) -> bool:
        with (self.jobs_dir / "collector.lock").open("a+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(lock, fcntl.LOCK_UN)
        return False

    def status(self) -> dict[str, object]:
        with self.lock:
            own_running = self.process is not None and self.process.poll() is None
            exit_code = None if self.process is None or own_running else self.process.returncode
        attached_pid = None if own_running else self.attached_batch_pid()
        running = own_running or attached_pid is not None or self.batch_lock_held()
        job = None
        latest = self.jobs_dir / "latest.json"
        if latest.exists():
            try:
                name = str(json.loads(latest.read_text(encoding="utf-8"))["job_file"])
                if Path(name).name == name:
                    job = json.loads((self.jobs_dir / name).read_text(encoding="utf-8"))
            except (OSError, ValueError, KeyError):
                pass
        items = list(job.get("items", [])) if isinstance(job, dict) else []
        counts: dict[str, int] = {}
        for item in items:
            status = str(item.get("status", "pending"))
            counts[status] = counts.get(status, 0) + 1
        with self.lock:
            if self.eta_cache is None or time.monotonic() - self.eta_cache[0] >= 10:
                self.eta_cache = (
                    time.monotonic(),
                    estimate(job, self.dataset_dir / "records", running=running),
                )
            eta = self.eta_cache[1]
        try:
            with self.log_path.open("rb") as log:
                log.seek(0, os.SEEK_END)
                log.seek(max(0, log.tell() - 20000))
                tail = log.read().decode("utf-8", "replace")
        except OSError:
            tail = ""
        return {
            "running": running,
            "canStop": own_running or attached_pid is not None,
            "exitCode": exit_code,
            "hasJob": job is not None,
            "complete": job.get("complete") if isinstance(job, dict) else None,
            "total": len(items),
            "counts": counts,
            "sourceErrors": list(job.get("source_errors", []))[-10:] if isinstance(job, dict) else [],
            "log": tail,
            "outputDir": str(self.out_dir),
            "eta": eta,
        }

    def start(self, *, links: str | None = None, resume: bool = False) -> None:
        with self.lock:
            if (self.process is not None and self.process.poll() is None) or self.batch_lock_held():
                raise ValueError("Une collecte Wispr est déjà en cours.")
            if resume:
                if not (self.jobs_dir / "latest.json").exists():
                    raise ValueError("Aucune collecte enregistrée à reprendre.")
                command = [sys.executable, "-u", str(SCRIPT_DIR / "wispr_youtube_batch.py"), "--resume"]
            else:
                if not links or not links.strip():
                    raise ValueError("Colle au moins un lien YouTube.")
                digest = hashlib.sha256(links.encode()).hexdigest()[:16]
                input_file = self.jobs_dir / f"ui-input-{digest}.txt"
                temporary = input_file.with_name(f"{input_file.name}.tmp.{os.getpid()}")
                temporary.write_text(links, encoding="utf-8")
                os.replace(temporary, input_file)
                command = [sys.executable, "-u", str(SCRIPT_DIR / "wispr_youtube_batch.py"), "--urls-file", str(input_file)]
            with self.log_path.open("ab") as log:
                log.write(b"\n=== Wispr collection started ===\n")
                log.flush()
                self.process = subprocess.Popen(
                    command,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    env=dict(os.environ, WISPR_OUT_DIR=str(self.out_dir)),
                    start_new_session=True,
                )
                self.save_process_reference(self.process.pid)
                self.eta_cache = None

    def stop(self) -> None:
        with self.lock:
            pid = self.process.pid if self.process is not None and self.process.poll() is None else self.attached_batch_pid()
            if pid is None:
                raise ValueError("Aucune collecte lancée par cette fenêtre n'est en cours.")
            os.killpg(pid, signal.SIGTERM)


def make_handler(application: CollectionUI) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format: str, *_args: object) -> None:
            pass

        def send_payload(self, status: HTTPStatus, payload: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def json_response(self, status: HTTPStatus, payload: object) -> None:
            self.send_payload(status, json.dumps(payload, ensure_ascii=False).encode(), "application/json; charset=utf-8")

        def authorized(self) -> bool:
            return secrets.compare_digest(self.headers.get("X-Wispr-Session", ""), application.token)

        def do_GET(self) -> None:
            if self.path == "/":
                template = (SCRIPT_DIR / "wispr_youtube_ui.html").read_text(encoding="utf-8")
                html = template.replace("__SESSION_TOKEN__", json.dumps(application.token))
                self.send_payload(HTTPStatus.OK, html.encode(), "text/html; charset=utf-8")
            elif self.path == "/api/status" and self.authorized():
                self.json_response(HTTPStatus.OK, application.status())
            else:
                self.json_response(HTTPStatus.NOT_FOUND, {"error": "Introuvable."})

        def do_POST(self) -> None:
            if not self.authorized():
                self.json_response(HTTPStatus.FORBIDDEN, {"error": "Session invalide."})
                return
            if self.path not in {"/api/start", "/api/resume", "/api/stop"}:
                self.json_response(HTTPStatus.NOT_FOUND, {"error": "Introuvable."})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length < 0 or length > MAX_REQUEST_BYTES:
                    raise ValueError("Liste de liens trop longue.")
                body = json.loads(self.rfile.read(length) or b"{}")
                if not isinstance(body, dict):
                    raise ValueError("Requête invalide.")
                if self.path == "/api/start":
                    links = body.get("links")
                    if not isinstance(links, str):
                        raise ValueError("La liste de liens est invalide.")
                    application.start(links=links)
                elif self.path == "/api/resume":
                    application.start(resume=True)
                else:
                    application.stop()
                self.json_response(HTTPStatus.ACCEPTED, application.status())
            except (ValueError, TypeError, json.JSONDecodeError) as error:
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": str(error)})
            except OSError as error:
                self.json_response(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": f"Impossible de démarrer la collecte : {error}"})

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--out-dir", type=Path, default=Path(os.environ.get("WISPR_OUT_DIR", "~/Documents/wispr/transcripts")))
    parser.add_argument("--no-open", action="store_true")
    arguments = parser.parse_args()
    application = CollectionUI(arguments.out_dir.expanduser())
    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), make_handler(application))
    url = f"http://127.0.0.1:{server.server_port}/"
    print(f"Interface Wispr YouTube : {url}", flush=True)
    if not arguments.no_open:
        threading.Timer(0.2, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
