"""Offline recovery tests for YouTube intake and the Wispr chunk collector."""

from __future__ import annotations

import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import wave


SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import wispr_youtube_batch as batch  # noqa: E402
import wispr_youtube_eta as eta  # noqa: E402
import wispr_youtube_ui as ui  # noqa: E402


class URLBatchTests(unittest.TestCase):
    def test_video_playlist_and_lookalike_urls(self) -> None:
        self.assertEqual(
            batch.youtube_source("https://youtu.be/abc123def45?t=3"),
            ("video", "abc123def45", "https://www.youtube.com/watch?v=abc123def45"),
        )
        self.assertEqual(
            batch.youtube_source("https://www.youtube.com/playlist?list=PLabc123def45"),
            ("playlist", "PLabc123def45", "https://www.youtube.com/playlist?list=PLabc123def45"),
        )
        self.assertEqual(
            batch.youtube_source("https://www.youtube.com/watch?v=abc123def45&list=PLabc123def45"),
            ("playlist", "PLabc123def45", "https://www.youtube.com/playlist?list=PLabc123def45"),
        )
        with self.assertRaises(ValueError):
            batch.youtube_source("https://youtube.com.evil.example/watch?v=abc123def45")

    def test_playlist_outage_keeps_previous_discovered_videos(self) -> None:
        source = "https://www.youtube.com/playlist?list=PLabc123def45"
        old = [{
            "key": "video:abc123def45", "kind": "video", "video_id": "abc123def45",
            "url": "https://www.youtube.com/watch?v=abc123def45",
            "origin_source": source, "status": "transcription_failed",
        }]
        with patch.object(batch, "expand_playlist", side_effect=RuntimeError("network down")):
            items, errors = batch.resolve_items([source], old, "yt-dlp")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["video_id"], "abc123def45")
        self.assertEqual(items[0]["status"], "transcription_failed")
        self.assertEqual(len(errors), 1)

    def test_partial_playlist_keeps_valid_videos_and_reports_gap(self) -> None:
        source = "https://www.youtube.com/playlist?list=PLabc123def45"
        completed = subprocess.CompletedProcess(
            ["yt-dlp"], 1, "abc123def45\nNA\nzzz123def45\n", "one entry unavailable",
        )
        with patch.object(batch.subprocess, "run", return_value=completed):
            items, errors = batch.resolve_items([source], [], "yt-dlp")
        self.assertEqual([item["video_id"] for item in items], ["abc123def45", "zzz123def45"])
        self.assertEqual(len(errors), 2)

    def test_pasted_markdown_extracts_youtube_links(self) -> None:
        args = argparse.Namespace(
            resume=False, urls_file=None, urls_stdin=False,
            sources=["- [Interview](https://youtu.be/abc123def45) | [notes](https://example.org/read)",
                     "https://www.youtube.com/watch?v=zzz123def45"],
        )
        self.assertEqual(batch.source_lines(args), [
            "https://youtu.be/abc123def45",
            "https://www.youtube.com/watch?v=zzz123def45",
        ])
        with tempfile.TemporaryDirectory() as temporary:
            pasted = Path(temporary) / "links.txt"
            pasted.write_text("Vidéos françaises\n- https://youtu.be/abc123def45\n\nVidéos anglaises\n")
            args.sources = []
            args.urls_file = pasted
            self.assertEqual(batch.source_lines(args), ["https://youtu.be/abc123def45"])

    def test_download_retries_after_failure_and_reuses_verified_audio(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / "fixture.mp3"
            subprocess.run([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                "-i", "anullsrc=r=16000:cl=mono", "-t", "0.25", str(fixture),
            ], check=True)
            calls = root / "calls.txt"
            fake = root / "fake-yt-dlp"
            fake.write_text(
                "#!/usr/bin/env python3\n"
                "import os,pathlib,shutil,sys\n"
                "counter=pathlib.Path(os.environ['FAKE_YTDLP_CALLS'])\n"
                "number=int(counter.read_text())+1 if counter.exists() else 1\n"
                "counter.write_text(str(number))\n"
                "if number == 1: sys.exit(1)\n"
                "template=pathlib.Path(sys.argv[sys.argv.index('--output')+1])\n"
                "shutil.copy(os.environ['FAKE_YTDLP_AUDIO'],str(template).replace('%(ext)s','mp3'))\n"
            )
            fake.chmod(0o755)
            item = {"video_id": "abc123def45", "url": "https://www.youtube.com/watch?v=abc123def45"}
            with patch.dict(os.environ, {"FAKE_YTDLP_CALLS": str(calls), "FAKE_YTDLP_AUDIO": str(fixture)}):
                with self.assertRaises(RuntimeError):
                    batch.download_video(item, root / "cache", str(fake), "ffprobe")
                path = batch.download_video(item, root / "cache", str(fake), "ffprobe")
                self.assertTrue(batch.valid_audio(path))
                self.assertEqual(batch.download_video(item, root / "cache", str(fake), "ffprobe"), path)
            self.assertEqual(calls.read_text(), "2")

    def test_batch_job_persists_and_resumes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "cached.mp3"
            audio.write_bytes(b"fixture")
            calls = []

            def run_command(command, **_kwargs):
                calls.append(command)
                if command[0] == "bash" and sum(call[0] == "bash" for call in calls) == 1:
                    return subprocess.CompletedProcess(command, 1)
                return subprocess.CompletedProcess(command, 0)

            args = argparse.Namespace(
                resume=False, urls_file=None, urls_stdin=False,
                sources=["https://youtu.be/abc123def45", "https://youtu.be/zzz123def45"],
                parallel=1,
            )
            with patch.dict(os.environ, {"WISPR_OUT_DIR": str(root)}, clear=False), \
                 patch.object(batch, "download_video", return_value=audio), \
                 patch.object(batch, "obtain_token", return_value="fixture-token"), \
                 patch.object(batch.subprocess, "run", side_effect=run_command):
                self.assertEqual(batch.run(args), 1)
                latest = batch.read_json(root / "youtube-jobs/latest.json")
                job_path = root / "youtube-jobs" / latest["job_file"]
                self.assertFalse(batch.read_json(job_path)["complete"])
                self.assertEqual(batch.run(argparse.Namespace(
                    resume=True, urls_file=None, urls_stdin=False, sources=[], parallel=1,
                )), 0)
                self.assertTrue(batch.read_json(job_path)["complete"])

    def test_batch_processes_three_videos_concurrently(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "cached.mp3"
            audio.write_bytes(b"fixture")
            gate = threading.Lock()
            active = maximum = 0

            def run_command(command, **_kwargs):
                nonlocal active, maximum
                if command[0] == "bash":
                    with gate:
                        active += 1
                        maximum = max(maximum, active)
                    time.sleep(0.08)
                    with gate:
                        active -= 1
                return subprocess.CompletedProcess(command, 0)

            args = argparse.Namespace(
                resume=False, urls_file=None, urls_stdin=False, parallel=3,
                sources=[f"https://youtu.be/test{index:07d}" for index in range(4)],
            )
            with patch.dict(os.environ, {"WISPR_OUT_DIR": str(root)}, clear=False), \
                 patch.object(batch, "download_video", return_value=audio), \
                 patch.object(batch, "obtain_token", return_value="fixture-token"), \
                 patch.object(batch.subprocess, "run", side_effect=run_command):
                self.assertEqual(batch.run(args), 0)
            job_dir = root / "youtube-jobs"
            latest = batch.read_json(job_dir / "latest.json")
            job = batch.read_json(job_dir / str(latest["job_file"]))
            self.assertEqual(maximum, 3)
            self.assertEqual(job["parallel_videos"], 3)
            self.assertTrue(all(item["status"] == "done" for item in job["items"]))

    def test_collector_exit_two_does_not_stop_other_videos_as_auth_failure(self) -> None:
        item = {"kind": "audio", "path": "/tmp/fixture.wav", "url": None, "video_id": None}
        collector = SCRIPTS / "wispr-transcribe.sh"
        with patch.object(batch.subprocess, "run", return_value=subprocess.CompletedProcess([], 2)):
            status, error, unauthorized = batch.transcribe_item(
                1, 2, item, Path("/tmp"), "yt-dlp", "ffprobe", collector, Path("/tmp/rate"), "fixture",
            )
        self.assertEqual((status, error, unauthorized), ("transcription_failed", "collector exit 2", False))
        with patch.object(batch.subprocess, "run", return_value=subprocess.CompletedProcess([], 42)):
            _, _, unauthorized = batch.transcribe_item(
                1, 2, item, Path("/tmp"), "yt-dlp", "ffprobe", collector, Path("/tmp/rate"), "fixture",
            )
        self.assertTrue(unauthorized)


class CollectorRecoveryTests(unittest.TestCase):
    def test_parallel_collectors_share_request_throttle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_curl = fake_bin / "curl"
            fake_curl.write_text(
                "#!/usr/bin/env python3\n"
                "import json,os,sys,time\n"
                "with open(os.environ['WISPR_FAKE_TIMES'],'a') as log: log.write(str(time.time())+'\\n')\n"
                "raw=any('/llm/asr' in part for part in sys.argv)\n"
                "body={'content':'Bonjour','detected_language':'fr'} if raw else {'text':'Bonjour.'}\n"
                "sys.stdout.write(json.dumps(body)+'\\n200')\n"
            )
            fake_curl.chmod(0o755)
            env = dict(
                os.environ,
                PATH=f"{fake_bin}:{os.environ['PATH']}",
                WISPR_OUT_DIR=str(root / "wispr"),
                WISPR_ACCESS_TOKEN="fixture-token",
                WISPR_RATE_FILE=str(root / "shared-rate.txt"),
                WISPR_DEFER_MANIFEST_REBUILD="1",
                WISPR_MIN_REQUEST_INTERVAL="0.6",
                WISPR_MAX_RETRIES="1",
                WISPR_FAKE_TIMES=str(root / "times.txt"),
            )
            token = subprocess.run(
                ["bash", str(SCRIPTS / "wispr-transcribe.sh"), "--token-only"],
                env=env, capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(token.returncode, 0, token.stderr)
            self.assertEqual(token.stdout, "fixture-token")
            commands = []
            for index in range(2):
                audio = root / f"speech-{index}.wav"
                with wave.open(str(audio), "wb") as destination:
                    destination.setnchannels(1)
                    destination.setsampwidth(2)
                    destination.setframerate(16000)
                    destination.writeframes(b"\0\0" * 4800)
                commands.append(["bash", str(SCRIPTS / "wispr-transcribe.sh"), str(audio)])
            processes = [subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for command in commands]
            for process in processes:
                stdout, stderr = process.communicate(timeout=25)
                self.assertEqual(process.returncode, 0, stdout + stderr)
            times = sorted(float(value) for value in (root / "times.txt").read_text().splitlines())
            self.assertEqual(len(times), 4)
            # Four shared requests require three global intervals. Compare
            # the whole span to avoid fake curl process-startup jitter.
            self.assertGreaterEqual(times[-1] - times[0], 1.4)

    def test_failed_edited_request_resumes_without_repeating_raw(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "speech.wav"
            with wave.open(str(audio), "wb") as destination:
                destination.setnchannels(1)
                destination.setsampwidth(2)
                destination.setframerate(16000)
                destination.writeframes(b"\0\0" * (16000 * 2 + 8000))
            session = root / "session.json"
            session.write_text(json.dumps({"session": {"access_token": "fixture-token"}}))
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_curl = fake_bin / "curl"
            fake_curl.write_text(
                "#!/usr/bin/env python3\n"
                "import json,os,sys\n"
                "p=os.environ['WISPR_FAKE_COUNTS']\n"
                "try: c=json.load(open(p))\n"
                "except FileNotFoundError: c={'raw':0,'edited':0}\n"
                "raw=any('/llm/asr' in x for x in sys.argv)\n"
                "key='raw' if raw else 'edited'\n"
                "c[key]+=1\n"
                "json.dump(c,open(p,'w'))\n"
                "fail=os.environ.get('WISPR_FAKE_FAIL_EDITED_ONCE')=='1' and key=='edited' and c[key]==2\n"
                "body={'content':'Bonjour','detected_language':'fr'} if raw else {'text':'Bonjour.'}\n"
                "sys.stdout.write(json.dumps(body)+'\\n'+('503' if fail else '200'))\n"
            )
            fake_curl.chmod(0o755)
            env = dict(
                os.environ,
                PATH=f"{fake_bin}:{os.environ['PATH']}",
                WISPR_OUT_DIR=str(root / "wispr"),
                WISPR_SESSION_FILE=str(session),
                WISPR_ASAR=str(root / "missing.asar"),
                WISPR_LANG="fr",
                WISPR_MAX_CHUNK_SEC="1",
                WISPR_MIN_REQUEST_INTERVAL="0",
                WISPR_MAX_RETRIES="1",
                WISPR_FAKE_COUNTS=str(root / "counts.json"),
                WISPR_FAKE_FAIL_EDITED_ONCE="1",
            )
            command = ["bash", str(SCRIPTS / "wispr-transcribe.sh"), str(audio)]
            first = subprocess.run(command, env=env, capture_output=True, text=True, timeout=40)
            self.assertEqual(first.returncode, 1, first.stdout + first.stderr)
            record_path = next((root / "wispr/dataset/records").glob("*/record.json"))
            self.assertFalse(json.loads(record_path.read_text())["summary"]["complete"])
            counts = json.loads((root / "counts.json").read_text())
            self.assertEqual(counts, {"raw": 3, "edited": 3})

            # Simulate a record written before per-chunk state was introduced.
            (record_path.parent / "results/chunk_0002.state.json").unlink()
            env["WISPR_FAKE_FAIL_EDITED_ONCE"] = "0"
            second = subprocess.run(command, env=env, capture_output=True, text=True, timeout=40)
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertTrue(json.loads(record_path.read_text())["summary"]["complete"])
            self.assertEqual(json.loads((root / "counts.json").read_text()), {"raw": 3, "edited": 4})

            env["WISPR_SESSION_FILE"] = str(root / "missing-session.json")
            third = subprocess.run(command, env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(third.returncode, 0, third.stdout + third.stderr)
            self.assertEqual(json.loads((root / "counts.json").read_text()), {"raw": 3, "edited": 4})


class UITests(unittest.TestCase):
    def test_eta_uses_completed_chunks_and_marks_unknown_videos_provisional(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = root / "records/youtube-abc123def45-fixture"
            results = record / "results"
            results.mkdir(parents=True)
            chunks = [{"chunk": index} for index in range(1, 11)]
            (record / "segmentation.json").write_text(json.dumps({"chunks": chunks}))
            now = time.time()
            for index in range(1, 7):
                path = results / f"chunk_{index:04d}.state.json"
                path.write_text(json.dumps({"raw_http_status": "200", "edited_http_status": "200"}))
                os.utime(path, (now - 130 + index * 10, now - 130 + index * 10))
            (results / "chunk_0007.state.json").write_text(json.dumps({
                "raw_http_status": "200", "edited_http_status": "500",
            }))
            job = {"items": [
                {"video_id": "abc123def45", "status": "running"},
                {"video_id": "zzz123def45", "status": "pending"},
            ]}
            result = eta.estimate(job, root / "records", running=True, now=now)
            self.assertEqual(result["completedChunks"], 6)
            self.assertEqual(result["estimatedTotalChunks"], 20)
            self.assertEqual(result["knownVideos"], 1)
            self.assertEqual(result["failedChunks"], 1)
            self.assertTrue(result["provisional"])
            self.assertIsNotNone(result["at"])
            self.assertEqual(result["minutesRemaining"], 5)
            self.assertIsNone(eta.estimate(job, root / "records", running=False, now=now)["at"])

    def test_restarted_interface_can_find_its_batch_process(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            application = ui.CollectionUI(Path(temporary))
            application.save_process_reference(12345)
            command = subprocess.CompletedProcess(
                ["ps"], 0, f"Python -u {ui.SCRIPT_DIR / 'wispr_youtube_batch.py'} --resume", "",
            )
            with patch.object(application, "batch_lock_held", return_value=True), \
                 patch.object(ui.os, "getpgid", return_value=12345), \
                 patch.object(ui.subprocess, "run", return_value=command), \
                 patch.object(ui.os, "killpg") as kill:
                self.assertEqual(application.attached_batch_pid(), 12345)
                application.stop()
                kill.assert_called_once()

    def test_local_interface_requires_session_and_rejects_empty_batch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            application = ui.CollectionUI(Path(temporary))
            server = ThreadingHTTPServer(("127.0.0.1", 0), ui.make_handler(application))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            try:
                with urlopen(base + "/", timeout=3) as response:
                    html = response.read().decode()
                self.assertIn("Démarrer la collecte", html)
                self.assertIn("Heure de fin", html)
                self.assertNotIn("__SESSION_TOKEN__", html)
                with self.assertRaises(HTTPError) as denied:
                    urlopen(base + "/api/status", timeout=3)
                self.assertEqual(denied.exception.code, 404)
                status = Request(base + "/api/status", headers={"X-Wispr-Session": application.token})
                with urlopen(status, timeout=3) as response:
                    self.assertFalse(json.load(response)["hasJob"])
                start = Request(
                    base + "/api/start", data=b'{"links":""}', method="POST",
                    headers={"X-Wispr-Session": application.token, "Content-Type": "application/json"},
                )
                with self.assertRaises(HTTPError) as invalid:
                    urlopen(start, timeout=3)
                self.assertEqual(invalid.exception.code, 400)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)

if __name__ == "__main__":
    unittest.main()
