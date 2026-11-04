#!/usr/bin/env python3
"""Small local YouTube → MP3 interface, with a ChatGPT file handoff."""

from __future__ import annotations

import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import threading
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit
import uuid
import webbrowser

from wispr_youtube_batch import sha256, valid_audio, write_json, youtube_source


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_OUT_DIR = Path('/Volumes/0_Oueillez/VoxoL-YouTube')
MAX_REQUEST_BYTES = 128 * 1024
MAX_BATCH_LINKS = 100
MAX_AUDIO_BYTES = 512 * 1024 * 1024
ACTIVE_STATUSES = {'queued', 'downloading', 'converting', 'verifying'}
DOWNLOAD_PREFIX = '__VOXOL_DOWNLOAD__'
CONVERT_PREFIX = '__VOXOL_CONVERT__'


def video_source(value: str) -> dict[str, str]:
    """Select the video even when a copied watch URL also contains a playlist."""
    if not isinstance(value, str) or len(value) > 4096:
        raise ValueError("Colle le lien d’une vidéo YouTube.")
    parsed = urlsplit(value.strip())
    if parsed.username or parsed.password or parsed.port not in {None, 80, 443}:
        raise ValueError("Ce lien YouTube n’est pas valide.")
    query = parse_qs(parsed.query)
    query.pop("list", None)
    normalized = urlunsplit(parsed._replace(query=urlencode(query, doseq=True)))
    try:
        kind, identifier, url = youtube_source(normalized)
    except ValueError as error:
        raise ValueError("Colle le lien d’une vidéo YouTube, pas une playlist.") from error
    if kind != "video":
        raise ValueError("Colle le lien d’une vidéo YouTube, pas une playlist.")
    return {"video_id": identifier, "url": url}


def teacher_prompt(video_id: str) -> str:
    return f"""Écoute le fichier audio joint pour préparer des annotations de dictée VoxoL.
Travaille uniquement à partir du son, sans recherche web ni sous-titres externes.
Crée un vrai fichier téléchargeable UTF-8 nommé youtube-{video_id}.json, contenant un seul objet JSON. Utilise ton outil de création de fichiers si disponible ; si tu ne peux pas créer de fichier, dis-le explicitement.
Le JSON doit contenir ces champs :
- sample_id : "youtube-{video_id}"
- language : code ISO de la langue entendue
- verbatim : transcription mot à mot de tout l’audio, dans sa langue originale ; conserve les hésitations, répétitions, noms, chiffres et négations. Ne complète pas les phrases coupées. Utilise [inaudible] pour les passages incompréhensibles.
- cleaned : correction minimale du verbatim (orthographe, accords, ponctuation et hésitations inutiles), sans reformulation, résumé, traduction ni changement d’information. Si aucune correction n’est nécessaire, recopie le verbatim.
- uncertain_spans : liste d’objets avec text, alternatives (liste) et reason pour les passages incertains ; [] s’il n’y en a pas
- audio_processed : true si le fichier a réellement pu être traité, sinon false
- complete : true seulement si tout l’audio a été traité et que son début et sa fin ont été revérifiés à l’écoute ; sinon false
- unprocessed_ranges : liste d’objets start_seconds, end_seconds et reason pour les portions non traitées ; temps null si inconnus, [] seulement si aucune portion ne manque
- human_gold : false
- training_included : false
- checks : objet avec json_parse, schema, audio_start, audio_end et cleaned_fidelity. Chaque contrôle contient status ("passed", "failed" ou "not_checked") et detail.

Avant de livrer :
1. Réécoute le début et la fin du fichier joint, compare-les au verbatim et recherche une coupure ou un oubli. Si une partie n’a pas pu être traitée, signale-la ; n’invente aucun passage ni minutage.
2. Compare cleaned au verbatim : aucun nom, chiffre, négation ni information ne doit être ajouté, supprimé ou modifié. Marque les hésitations sur les noms et chiffres dans uncertain_spans au lieu de deviner.
3. Enregistre le JSON, puis rouvre le fichier créé avec un parseur JSON pour contrôler sa syntaxe et les champs/types demandés. Corrige les erreurs et vérifie de nouveau. Un verbatim vide alors que de la parole est audible est un échec.
4. N’annonce pas un contrôle comme réussi sans l’avoir effectué ; utilise "not_checked" si tu ne peux pas le faire. Ces contrôles sont automatiques et ne constituent pas une validation humaine.

Dans ta réponse finale, donne le lien de téléchargement du fichier et un bref bilan des contrôles et incertitudes. Ne recopie pas tout le JSON dans le chat."""


def video_sources(values: str | list[str]) -> list[dict[str, str]]:
    if isinstance(values, str):
        values = [value for value in re.split(r'[\s,;]+', values.strip()) if value]
    if not isinstance(values, list) or not values or len(values) > MAX_BATCH_LINKS:
        raise ValueError(f'Colle entre 1 et {MAX_BATCH_LINKS} liens YouTube, un par ligne.')
    items = []
    for number, value in enumerate(values, 1):
        try:
            items.append(video_source(value))
        except ValueError as error:
            raise ValueError(f'Lien {number} : {error}') from error
    return items


def finite_number(value: object) -> float | None:
    try:
        number = float(value)
        return number if math.isfinite(number) and number >= 0 else None
    except (ValueError, TypeError):
        return None


def progress_update(line: str) -> dict[str, object] | None:
    """Read yt-dlp's actual byte counts; conversion never has a made-up percent."""
    prefix = next((prefix for prefix in (DOWNLOAD_PREFIX, CONVERT_PREFIX) if line.startswith(prefix)), None)
    if prefix is None:
        return None
    try:
        data = json.loads(line[len(prefix):])
        if not isinstance(data, dict):
            return None
    except (ValueError, TypeError):
        return None
    if prefix == CONVERT_PREFIX:
        return {'status': 'converting', 'phase': 'Conversion en MP3', 'eta_seconds': None, 'speed_bytes': None}
    downloaded = finite_number(data.get('downloaded_bytes'))
    total = finite_number(data.get('total_bytes')) or finite_number(data.get('total_bytes_estimate'))
    percent = min(100.0, downloaded / total * 100) if downloaded is not None and total else None
    return {
        'status': 'downloading', 'phase': 'Téléchargement de l’audio', 'progress': percent,
        'downloaded_bytes': downloaded, 'total_bytes': total,
        'estimated_total': not bool(data.get('total_bytes')),
        'speed_bytes': finite_number(data.get('speed')), 'eta_seconds': finite_number(data.get('eta')),
    }


def download_audio(item, cache_dir: Path, temp_dir: Path, cache_home: Path, update, check_storage) -> Path:
    identifier = item['video_id']
    target = cache_dir / f'youtube-{identifier}.mp3'
    check_storage()
    if valid_audio(target):
        update({'phase': 'MP3 déjà présent · vérification', 'status': 'verifying', 'cached': True})
        return target
    if target.exists():
        target.rename(target.with_name(f'{target.name}.invalid-{uuid.uuid4().hex[:8]}'))
    for folder in (cache_dir, temp_dir, cache_home):
        folder.mkdir(parents=True, exist_ok=True)
    command = [
        'yt-dlp', '--ignore-config', '--no-playlist', '--continue', '--retries', '3',
        '--fragment-retries', '3', '--socket-timeout', '30', '-f', 'bestaudio/best',
        '--extract-audio', '--audio-format', 'mp3', '--audio-quality', '0',
        '--paths', f'home:{cache_dir}', '--paths', f'temp:{temp_dir}',
        '--output', f'youtube-{identifier}.%(ext)s', '--cache-dir', str(cache_home),
        '--newline', '--no-colors', '--progress', '--progress-delta', '0.3',
        '--progress-template', f'download:{DOWNLOAD_PREFIX}%(progress)j',
        '--progress-template', f'postprocess:{CONVERT_PREFIX}%(progress)j', item['url'],
    ]
    environment = dict(os.environ, TMPDIR=str(temp_dir), XDG_CACHE_HOME=str(cache_home))
    tail = deque(maxlen=8)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, encoding='utf-8', errors='replace', env=environment,
                               cwd=cache_dir, start_new_session=True)
    try:
        assert process.stdout is not None
        for line in process.stdout:
            check_storage()
            event = progress_update(line.strip())
            if event:
                update(event)
            else:
                tail.append(line.strip())
        code = process.wait()
        check_storage()
        if code or not valid_audio(target):
            raise RuntimeError(f'Le téléchargement a échoué. {" ".join(tail)[-350:]}')
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        if process.stdout is not None:
            process.stdout.close()
    return target


class Downloader:
    def __init__(self, out_dir: Path, workers: int = 3) -> None:
        self.out_dir = out_dir.expanduser().absolute()
        self.cache_dir = self.out_dir / "mp3"
        self.temp_dir = self.out_dir / 'temp'
        self.cache_home = self.out_dir / 'cache'
        self.volume = Path(*self.out_dir.parts[:3]) if self.out_dir.parts[:2] == ('/', 'Volumes') and len(self.out_dir.parts) >= 3 else None
        self.volume_device: int | None = None
        self.token = secrets.token_urlsafe(32)
        self.lock = threading.Lock()
        self.jobs: dict[str, dict[str, object]] = {}
        self.files: dict[str, Path] = {}
        self.workers = max(1, min(4, workers))
        self.executor = ThreadPoolExecutor(max_workers=self.workers, thread_name_prefix='youtube-mp3')
        self.stopping = threading.Event()
        self._restore()

    def check_storage(self) -> None:
        if self.stopping.is_set():
            raise ValueError('Le lanceur a été arrêté. Relance le téléchargement pour reprendre.')
        if self.volume:
            if not self.volume.is_mount():
                raise ValueError(f'Branche le SSD {self.volume.name}. Aucun fichier ne sera enregistré sur le Mac.')
            device = self.volume.stat().st_dev
            if self.volume_device is not None and device != self.volume_device:
                raise ValueError('Le SSD a changé. Relance le lanceur pour utiliser ce disque.')
            self.volume_device = device
            if any(not folder.resolve().is_relative_to(self.volume.resolve())
                   for folder in (self.out_dir, self.cache_dir, self.temp_dir, self.cache_home)):
                raise ValueError('Le dossier de sortie doit rester sur le SSD.')
        if self.out_dir.exists() and not os.access(self.out_dir, os.W_OK):
            raise ValueError('Le dossier du SSD est en lecture seule.')

    def storage(self) -> dict[str, object]:
        try:
            self.check_storage()
            available, error = True, None
        except (ValueError, OSError) as failure:
            available, error = False, str(failure)
        return {'path': str(self.out_dir), 'external': self.volume is not None,
                'name': self.volume.name if self.volume else self.out_dir.name,
                'available': available, 'error': error}

    def _restore(self) -> None:
        try:
            self.check_storage()
            manifest = self.out_dir / 'jobs.json'
            if not manifest.is_file():
                return
            saved = json.loads(manifest.read_text(encoding='utf-8'))
            changed = False
            for job in saved.get('jobs', []):
                if not isinstance(job, dict) or not re.fullmatch(r'[a-f0-9]{32}', str(job.get('id', ''))):
                    continue
                source = video_source(job.get('url', ''))
                if job.get('video_id') != source['video_id']:
                    continue
                previous = deepcopy(job)
                if job.get('status') == 'ready':
                    audio = self.cache_dir / f"youtube-{job['video_id']}.mp3"
                    if audio.is_file() and audio.stat().st_size == job.get('bytes'):
                        prompt = teacher_prompt(job['video_id'])
                        prompt_file = audio.with_suffix('.prompt.txt')
                        if not prompt_file.is_file() or prompt_file.read_text(encoding='utf-8') != prompt + '\n':
                            self.check_storage()
                            prompt_file.write_text(prompt + '\n', encoding='utf-8')
                        job['prompt'] = prompt
                        job.update(path=str(audio), filename=audio.name, download_url=f"/files/{job['id']}.mp3")
                        self.files[job['id']] = audio
                    else:
                        job.update(status='error', error='Le MP3 est absent ou a changé. Relance ce lien.')
                elif job.get('status') in ACTIVE_STATUSES:
                    job.update(status='error', error='Téléchargement interrompu. Relance ce lien pour reprendre.')
                self.jobs[job['id']] = job
                changed = changed or job != previous
            if changed:
                self.check_storage()
                write_json(manifest, {'jobs': list(self.jobs.values())})
        except (ValueError, OSError, AttributeError, KeyError, TypeError):
            return

    def close(self) -> None:
        self.stopping.set()
        self.executor.shutdown(wait=True, cancel_futures=True)

    def status(self) -> dict[str, object]:
        storage = self.storage()
        with self.lock:
            jobs = deepcopy(list(self.jobs.values()))
        return {'jobs': jobs, 'workers': self.workers, 'storage': storage,
                'counts': {state: sum(job['status'] == state for job in jobs)
                           for state in (*ACTIVE_STATUSES, 'ready', 'error')}}

    def start(self, values: str | list[str]) -> dict[str, int]:
        items = video_sources(values)
        self.check_storage()
        for executable in ("yt-dlp", "ffmpeg", "ffprobe"):
            if not shutil.which(executable):
                raise ValueError(f"{executable} est nécessaire. Consulte la documentation de l’outil.")
        with self.lock:
            for job in self.jobs.values():
                if job['status'] == 'ready' and not Path(str(job['path'])).is_file():
                    job.update(status='error', error='Le MP3 est absent. Relance ce lien.')
            seen = {job['video_id'] for job in self.jobs.values() if job['status'] != 'error'}
            additions = []
            for item in items:
                if item['video_id'] in seen:
                    continue
                seen.add(item['video_id'])
                additions.append(dict(item, id=uuid.uuid4().hex, status='queued', phase='En attente',
                                      progress=None, created_at=datetime.now(timezone.utc).isoformat()))
            pending = sum(job['status'] in ACTIVE_STATUSES for job in self.jobs.values())
            if pending + len(additions) > MAX_BATCH_LINKS:
                raise ValueError(f'Au maximum {MAX_BATCH_LINKS} vidéos dans la file. Attends la fin du lot en cours.')
            if additions:
                try:
                    write_json(self.out_dir / 'jobs.json', {'jobs': list(self.jobs.values()) + additions})
                except OSError as error:
                    raise ValueError('Impossible d’enregistrer la file sur le SSD.') from error
                for job in additions:
                    self.jobs[job['id']] = job
                    self.executor.submit(self._download, job['id'])
        return {'added': len(additions), 'duplicates': len(items) - len(additions)}

    def _update(self, identifier: str, values: dict[str, object]) -> None:
        with self.lock:
            self.jobs[identifier].update(values)

    def _download(self, identifier: str) -> None:
        self._update(identifier, {'status': 'downloading', 'phase': 'Connexion à YouTube',
                                  'started_at': datetime.now(timezone.utc).isoformat()})
        with self.lock:
            result = deepcopy(self.jobs[identifier])
        item = {'video_id': str(result['video_id']), 'url': str(result['url'])}
        audio: Path | None = None
        try:
            self.check_storage()
            audio = download_audio(item, self.cache_dir, self.temp_dir / item['video_id'], self.cache_home,
                                   lambda event: self._update(identifier, event), self.check_storage)
            self._update(identifier, {'status': 'verifying', 'phase': 'Vérification du MP3',
                                      'eta_seconds': None, 'speed_bytes': None})
            self.check_storage()
            probe = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                 "-of", "json", str(audio)],
                capture_output=True, text=True, check=True, timeout=30,
            )
            duration = float(json.loads(probe.stdout)["format"]["duration"])
            if not math.isfinite(duration) or duration <= 0:
                raise ValueError('La durée du MP3 est invalide.')
            if audio.stat().st_size > MAX_AUDIO_BYTES:
                raise ValueError("Le MP3 dépasse 512 Mo. Choisis une vidéo plus courte pour ChatGPT.")
            prompt = teacher_prompt(item["video_id"])
            audio.with_suffix(".prompt.txt").write_text(prompt + "\n", encoding="utf-8")
            audio_hash = sha256(audio)
            self.check_storage()
            write_json(audio.with_suffix('.source.json'), {
                'provider': 'YouTube', **item, 'audio_sha256': audio_hash,
            })
            result.update({
                "status": "ready", "filename": audio.name, "path": str(audio),
                "bytes": audio.stat().st_size, "duration_seconds": duration,
                "sha256": audio_hash, "prompt": prompt, 'progress': 100,
                'phase': 'Enregistré sur le SSD' if self.volume else 'MP3 enregistré',
                "download_url": f"/files/{result['id']}.mp3",
                "completed_at": datetime.now(timezone.utc).isoformat(),
            })
        except Exception as error:
            # Provider errors can contain transient media URLs; keep them out of the UI.
            detail = re.sub(r"https?://\S+", "[lien]", str(error))[-350:]
            result.update({"status": "error", "error": detail})
        # Serialize every manifest write so simultaneous completions cannot overwrite each other.
        with self.lock:
            result = {**self.jobs[identifier], **result}
            try:
                self.check_storage()
                write_json(self.out_dir / 'jobs.json', {'jobs': [result if job['id'] == identifier else job
                                                               for job in self.jobs.values()]})
            except (OSError, ValueError):
                result.update(status='error', error=result.get('error') or 'Impossible d’enregistrer le résultat dans le dossier de sortie.')
            if result["status"] == "ready" and audio is not None:
                self.files[str(result["id"])] = audio
            self.jobs[identifier] = result


def make_handler(application: Downloader) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format: str, *_args: object) -> None:
            pass

        def local_request(self) -> bool:
            expected = f"127.0.0.1:{self.server.server_port}"
            return self.headers.get("Host") == expected and self.headers.get(
                "Origin", f"http://{expected}"
            ) == f"http://{expected}"

        def authorized(self) -> bool:
            return self.local_request() and secrets.compare_digest(
                self.headers.get("X-Downloader-Session", ""), application.token
            )

        def send_payload(self, status: HTTPStatus, data: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(data)

        def json_response(self, status: HTTPStatus, value: object) -> None:
            self.send_payload(status, json.dumps(value, ensure_ascii=False).encode(), "application/json; charset=utf-8")

        def do_GET(self) -> None:
            if not self.local_request():
                self.json_response(HTTPStatus.FORBIDDEN, {"error": "Requête locale requise."})
                return
            if self.path == "/":
                html = (SCRIPT_DIR / "youtube_mp3_ui.html").read_text(encoding="utf-8")
                self.send_payload(HTTPStatus.OK, html.replace("__SESSION_TOKEN__", json.dumps(application.token)).encode(), "text/html; charset=utf-8")
            elif self.path == "/api/status" and self.authorized():
                self.json_response(HTTPStatus.OK, application.status())
            elif re.fullmatch(r"/files/[a-f0-9]{32}\.mp3", self.path):
                identifier = self.path.removeprefix("/files/").removesuffix(".mp3")
                with application.lock:
                    audio = application.files.get(identifier)
                if audio is None or not audio.is_file():
                    self.json_response(HTTPStatus.NOT_FOUND, {"error": "MP3 introuvable."})
                    return
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "audio/mpeg")
                self.send_header("Content-Length", str(audio.stat().st_size))
                self.send_header("Content-Disposition", f'attachment; filename="{audio.name}"')
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                try:
                    with audio.open("rb") as stream:
                        shutil.copyfileobj(stream, self.wfile)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            else:
                self.json_response(HTTPStatus.NOT_FOUND, {"error": "Introuvable."})

        def do_POST(self) -> None:
            if not self.authorized():
                self.json_response(HTTPStatus.FORBIDDEN, {"error": "Session invalide."})
                return
            if self.path != "/api/download":
                self.json_response(HTTPStatus.NOT_FOUND, {"error": "Introuvable."})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= MAX_REQUEST_BYTES:
                    raise ValueError("Le lien est trop long ou vide.")
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict):
                    raise ValueError('Colle des liens YouTube.')
                added = application.start(body.get('urls', body.get('url')))
                self.json_response(HTTPStatus.ACCEPTED, {**application.status(), **added})
            except (ValueError, TypeError) as error:
                self.json_response(HTTPStatus.BAD_REQUEST, {"error": str(error)})

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument('--workers', type=int, choices=range(1, 5), default=3)
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    application = Downloader(args.out_dir, args.workers)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(application))
    url = f"http://127.0.0.1:{server.server_port}/"
    try:
        application.check_storage()
        write_json(application.out_dir / "server.json", {"url": url, "pid": os.getpid()})
    except (ValueError, OSError) as error:
        print(f'SSD indisponible : {error}', flush=True)
    print(f"YouTube → MP3 : {url}", flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        application.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
