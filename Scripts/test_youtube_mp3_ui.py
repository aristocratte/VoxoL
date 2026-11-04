"""Downloader handoff tests; synthetic audio is only a transport fixture."""

from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import youtube_mp3_ui as ui


class YouTubeMP3Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture_dir = tempfile.TemporaryDirectory()
        cls.fixture = Path(cls.fixture_dir.name) / "transport.mp3"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
            "-i", "anullsrc=r=16000:cl=mono", "-t", "0.25", str(cls.fixture),
        ], check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.fixture_dir.cleanup()

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = ui.Downloader(Path(self.temporary.name))
        self.addCleanup(self.app.close)

    def completed_job(self) -> dict[str, object]:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            jobs = self.app.status()['jobs']
            if jobs and all(job['status'] not in ui.ACTIVE_STATUSES for job in jobs):
                return jobs[-1]
            time.sleep(0.01)
        self.fail("The worker did not complete")

    def download_fixture(self, item, cache_dir, temp_dir, cache_home, update, check_storage):
        check_storage()
        update({'status': 'downloading', 'progress': 50, 'downloaded_bytes': 100, 'total_bytes': 200})
        cache_dir.mkdir(parents=True, exist_ok=True)
        target = cache_dir / f"youtube-{item['video_id']}.mp3"
        shutil.copy2(self.fixture, target)
        return target

    def test_single_video_urls_keep_video_when_playlist_is_present(self) -> None:
        for url in [
            "https://youtu.be/abc123def45?t=3",
            "https://www.youtube.com/watch?v=abc123def45&list=PLabc123def45",
            "https://www.youtube.com/shorts/abc123def45",
        ]:
            self.assertEqual(ui.video_source(url), {
                "video_id": "abc123def45", "url": "https://www.youtube.com/watch?v=abc123def45",
            })

    def test_rejects_playlist_lookalike_domain_and_non_youtube_input(self) -> None:
        for url in [
            "https://www.youtube.com/playlist?list=PLabc123def45",
            "https://youtube.com.evil.example/watch?v=abc123def45",
            "http://127.0.0.1/private", "file:///etc/passwd",
            "https://user:password@youtube.com/watch?v=abc123def45", "not a link",
        ]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                ui.video_source(url)

    def test_ready_file_has_valid_duration_hash_and_teacher_prompt(self) -> None:
        with patch.object(ui, 'download_audio', side_effect=self.download_fixture):
            self.app.start("https://youtu.be/abc123def45")
            job = self.completed_job()
        self.assertEqual(job["status"], "ready")
        self.assertGreater(job["duration_seconds"], 0)
        self.assertEqual(job["sha256"], ui.sha256(self.fixture))
        self.assertEqual(Path(job["path"]).read_bytes(), self.fixture.read_bytes())
        self.assertIn("youtube-abc123def45", job["prompt"])
        self.assertTrue(Path(job["path"]).with_suffix(".prompt.txt").is_file())
        self.assertEqual(self.app.files[job["id"]], Path(job["path"]))

    def test_download_failure_never_exposes_ready_file_or_media_url(self) -> None:
        with patch.object(ui, 'download_audio', side_effect=RuntimeError("refused https://media.example/signed")):
            self.app.start("https://youtu.be/abc123def45")
            job = self.completed_job()
        self.assertEqual(job["status"], "error")
        self.assertNotIn("https://", job["error"])
        self.assertFalse(self.app.files)

    def test_oversized_audio_is_kept_but_not_offered_for_chatgpt(self) -> None:
        with patch.object(ui, "MAX_AUDIO_BYTES", 1), patch.object(ui, 'download_audio', side_effect=self.download_fixture):
            self.app.start("https://youtu.be/abc123def45")
            job = self.completed_job()
        self.assertEqual(job["status"], "error")
        self.assertIn("512 Mo", job["error"])
        self.assertTrue((self.app.cache_dir / "youtube-abc123def45.mp3").is_file())
        self.assertFalse(self.app.files)

    def test_failed_result_save_does_not_claim_ready(self) -> None:
        original = ui.write_json
        writes = 0

        def fail_completion(path, value):
            nonlocal writes
            if path.name == 'jobs.json':
                writes += 1
                if writes > 1:
                    raise PermissionError('read-only output')
            original(path, value)

        with patch.object(ui, 'download_audio', side_effect=self.download_fixture), patch.object(ui, 'write_json', side_effect=fail_completion):
            self.app.start("https://youtu.be/abc123def45")
            job = self.completed_job()
        self.assertEqual(job["status"], "error")
        self.assertIn("enregistrer", job["error"])
        self.assertFalse(self.app.files)

    def test_three_workers_run_together_and_fourth_stays_queued(self) -> None:
        release = threading.Event()
        three_started = threading.Event()
        guard = threading.Lock()
        active = 0
        maximum = 0

        def blocked(*args):
            nonlocal active, maximum
            with guard:
                active += 1
                maximum = max(maximum, active)
                if active == 3:
                    three_started.set()
            release.wait(3)
            try:
                return self.download_fixture(*args)
            finally:
                with guard:
                    active -= 1

        with patch.object(ui, 'download_audio', side_effect=blocked):
            self.app.start([f'https://youtu.be/{identifier}' for identifier in ['abc123def45', 'bbb123def45', 'ccc123def45', 'ddd123def45']])
            self.assertTrue(three_started.wait(2))
            jobs = self.app.status()['jobs']
            self.assertEqual(sum(job['status'] == 'downloading' for job in jobs), 3)
            self.assertEqual(sum(job['status'] == 'queued' for job in jobs), 1)
            duplicate = self.app.start('https://youtu.be/abc123def45')
            self.assertEqual(duplicate, {'added': 0, 'duplicates': 1})
            release.set()
            self.completed_job()
        self.assertEqual(maximum, 3)
        self.assertEqual(len(self.app.files), 4)
        saved = json.loads((self.app.out_dir / 'jobs.json').read_text())
        self.assertEqual(len(saved['jobs']), 4)
        self.assertTrue(all(job['status'] == 'ready' for job in saved['jobs']))

    def test_batch_validation_is_atomic_and_duplicates_are_canonical(self) -> None:
        with self.assertRaisesRegex(ValueError, 'Lien 2'):
            self.app.start('https://youtu.be/abc123def45\nnot-a-url')
        self.assertFalse(self.app.jobs)
        with patch.object(ui, 'download_audio', side_effect=self.download_fixture):
            result = self.app.start('https://youtu.be/abc123def45\nhttps://youtube.com/watch?v=abc123def45&list=PL123456')
            self.completed_job()
        self.assertEqual(result, {'added': 1, 'duplicates': 1})

    def test_progress_uses_bytes_and_conversion_is_indeterminate(self) -> None:
        update = ui.progress_update(ui.DOWNLOAD_PREFIX + json.dumps({
            'downloaded_bytes': 250, 'total_bytes': 1000, 'speed': 50, 'eta': 15,
        }))
        self.assertEqual(update['progress'], 25)
        self.assertEqual(update['speed_bytes'], 50)
        self.assertEqual(update['eta_seconds'], 15)
        estimate = ui.progress_update(ui.DOWNLOAD_PREFIX + '{"downloaded_bytes": 400, "total_bytes_estimate": 800}')
        self.assertEqual(estimate['progress'], 50)
        self.assertTrue(estimate['estimated_total'])
        unknown = ui.progress_update(ui.DOWNLOAD_PREFIX + '{"downloaded_bytes": 100, "speed": "NA"}')
        self.assertIsNone(unknown['progress'])
        conversion = ui.progress_update(ui.CONVERT_PREFIX + '{"status":"started"}')
        self.assertEqual(conversion['status'], 'converting')
        self.assertNotIn('progress', conversion)
        for line in ['not progress', ui.DOWNLOAD_PREFIX + 'broken', ui.DOWNLOAD_PREFIX + '[]']:
            self.assertIsNone(ui.progress_update(line))

    def test_one_failed_video_does_not_stop_other_videos_and_can_retry(self) -> None:
        def fail_one(item, *args):
            if item['video_id'] == 'bbb123def45':
                raise RuntimeError('Unavailable video')
            return self.download_fixture(item, *args)

        with patch.object(ui, 'download_audio', side_effect=fail_one):
            self.app.start(['https://youtu.be/abc123def45', 'https://youtu.be/bbb123def45'])
            self.completed_job()
        self.assertEqual(sorted(job['status'] for job in self.app.status()['jobs']), ['error', 'ready'])
        with patch.object(ui, 'download_audio', side_effect=self.download_fixture):
            self.assertEqual(self.app.start('https://youtu.be/bbb123def45')['added'], 1)
            self.assertEqual(self.completed_job()['status'], 'ready')

    def test_missing_ssd_never_creates_a_local_fallback_directory(self) -> None:
        output = Path('/Volumes/VoxoL-Missing-Test-Volume/VoxoL-YouTube')
        with patch.object(Path, 'is_mount', return_value=False):
            app = ui.Downloader(output)
            try:
                self.assertFalse(app.storage()['available'])
                with self.assertRaisesRegex(ValueError, 'Branche le SSD'):
                    app.start('https://youtu.be/abc123def45')
                self.assertFalse(output.exists())
                self.assertFalse(app.jobs)
            finally:
                app.close()

    def test_disconnected_ssd_during_download_never_claims_ready(self) -> None:
        original = self.app.check_storage
        detached = False

        def storage():
            if detached:
                raise ValueError('SSD débranché')
            original()

        def disconnect(*args):
            nonlocal detached
            target = self.download_fixture(*args)
            detached = True
            return target

        with patch.object(self.app, 'check_storage', side_effect=storage), patch.object(ui, 'download_audio', side_effect=disconnect):
            self.app.start('https://youtu.be/abc123def45')
            self.assertEqual(self.completed_job()['status'], 'error')
            self.assertFalse(self.app.files)

    def test_relaunch_restores_completed_files_and_marks_interrupted_jobs(self) -> None:
        with patch.object(ui, 'download_audio', side_effect=self.download_fixture):
            self.app.start('https://youtu.be/abc123def45')
            self.completed_job()
        manifest = self.app.out_dir / 'jobs.json'
        saved = json.loads(manifest.read_text())
        # Completed downloads must receive the new handoff without downloading again.
        saved['jobs'][0]['prompt'] = 'ancienne consigne'
        prompt_file = Path(saved['jobs'][0]['path']).with_suffix('.prompt.txt')
        prompt_file.write_text('ancienne consigne\n', encoding='utf-8')
        saved['jobs'].append({'id': '0' * 32, 'video_id': 'bbb123def45', 'url': 'https://youtu.be/bbb123def45', 'status': 'queued'})
        ui.write_json(manifest, saved)
        restored = ui.Downloader(self.app.out_dir)
        try:
            self.assertEqual([job['status'] for job in restored.status()['jobs']], ['ready', 'error'])
            self.assertEqual(len(restored.files), 1)
            current_prompt = ui.teacher_prompt('abc123def45')
            self.assertEqual(restored.status()['jobs'][0]['prompt'], current_prompt)
            self.assertEqual(prompt_file.read_text(encoding='utf-8'), current_prompt + '\n')
            self.assertEqual(json.loads(manifest.read_text())['jobs'][0]['prompt'], current_prompt)
        finally:
            restored.close()

    def test_ytdlp_writes_media_temp_and_cache_in_selected_directory(self) -> None:
        command_seen = {}
        target = self.app.cache_dir / 'youtube-abc123def45.mp3'

        class Process:
            pid = 123
            def __init__(self, command, **kwargs):
                import io
                command_seen.update(command=command, options=kwargs)
                shutil.copy2(self.fixture, target)
                self.stdout = io.StringIO(ui.DOWNLOAD_PREFIX + '{"downloaded_bytes":100,"total_bytes":200}\n' + ui.CONVERT_PREFIX + '{"status":"started"}\n')
            def poll(self): return 0
            def wait(self, **kwargs): return 0

        fixture = self.fixture
        Process.fixture = fixture
        events = []
        with patch.object(ui.subprocess, 'Popen', Process):
            # Audio validation uses subprocess.run internally; leave those ffprobe calls real.
            with patch.object(ui, 'valid_audio', side_effect=[False, True]):
                audio = ui.download_audio({'video_id': 'abc123def45', 'url': 'https://youtu.be/abc123def45'},
                    self.app.cache_dir, self.app.temp_dir, self.app.cache_home, events.append, self.app.check_storage)
        self.assertEqual(audio, target)
        command = command_seen['command']
        self.assertIn(f'home:{self.app.cache_dir}', command)
        self.assertIn(f'temp:{self.app.temp_dir}', command)
        self.assertIn(str(self.app.cache_home), command)
        self.assertIn('--ignore-config', command)
        self.assertEqual(command_seen['options']['env']['TMPDIR'], str(self.app.temp_dir))
        self.assertEqual(events[0]['progress'], 50)
        self.assertEqual(events[1]['status'], 'converting')

    def test_http_download_requires_session_and_only_serves_produced_files(self) -> None:
        server = ThreadingHTTPServer(("127.0.0.1", 0), ui.make_handler(self.app))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = f"http://127.0.0.1:{server.server_port}"
        body = json.dumps({'urls': ['https://youtu.be/abc123def45', 'https://youtu.be/bbb123def45']}).encode()
        headers = {"X-Downloader-Session": self.app.token, "Content-Type": "application/json"}
        for bad_headers in [
            {}, dict(headers, Origin="https://example.org"), dict(headers, Host="evil.example"),
        ]:
            with self.subTest(headers=bad_headers), self.assertRaises(HTTPError) as error:
                urlopen(Request(base + "/api/download", data=body, headers=bad_headers), timeout=3)
            self.assertEqual(error.exception.code, 403)
        with patch.object(ui, 'download_audio', side_effect=self.download_fixture):
            with urlopen(Request(base + "/api/download", data=body, headers=headers), timeout=3) as response:
                self.assertEqual(response.status, 202)
            job = self.completed_job()
        with urlopen(base + job["download_url"], timeout=3) as response:
            self.assertEqual(response.headers["Content-Type"], "audio/mpeg")
            self.assertIn(job["filename"], response.headers["Content-Disposition"])
            self.assertEqual(response.read(), self.fixture.read_bytes())
        with urlopen(Request(base + "/api/status", headers=headers), timeout=3) as response:
            self.assertEqual([job['status'] for job in json.load(response)['jobs']], ['ready', 'ready'])
        for path in ["/files/" + "0" * 32 + ".mp3", "/files/../../etc/passwd"]:
            with self.assertRaises(HTTPError) as error:
                urlopen(base + path, timeout=3)
            self.assertEqual(error.exception.code, 404)


if __name__ == "__main__":
    unittest.main()
