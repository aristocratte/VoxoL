#!/usr/bin/env python3
"""The audio-only runner reuses only complete, provenance-matched shards."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from run_wispr_youtube_qwen_runtime import run
from test_prepare_wispr_youtube_qwen import PrepareWisprYoutubeQwenTests


class RunWisprYoutubeQwenRuntimeTests(unittest.TestCase):
    def test_audio_only_manifest_and_safe_resume(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = PrepareWisprYoutubeQwenTests().fixture(root)
            model = root / "model"
            model.mkdir()
            (model / "quantization-report.json").write_text('{"model":"fake"}')
            binary = root / "fake-asr"
            binary.write_text('''#!/usr/bin/env python3
import json, pathlib, sys
args = sys.argv
manifest = json.loads(pathlib.Path(args[args.index('--manifest') + 1]).read_text())
output = pathlib.Path(args[args.index('--output') + 1])
with output.open('w') as stream:
    for item in manifest['items']:
        stream.write(json.dumps({'id': item['id'], 'rawText': 'A bright red light'}) + '\\n')
''')
            binary.chmod(0o700)
            args = (
                paths["teacher.jsonl"], paths["review.jsonl"], paths["audit.json"],
                paths["split.json"], paths["dataset"], model, binary,
                root / "runtime", 1,
            )
            first = run(*args)
            self.assertEqual(first["prediction_count"], 2)
            for manifest in (root / "runtime/manifests").glob("*.json"):
                data = manifest.read_text()
                self.assertNotIn("raw_original", data)
                self.assertNotIn("edited_original", data)
                self.assertNotIn("proposed_text", data)
            second = run(*args)
            self.assertEqual(first["predictions_sha256"], second["predictions_sha256"])
            (model / "quantization-report.json").write_text('{"model":"changed"}')
            with self.assertRaisesRegex(ValueError, "provenance changed"):
                run(*args)


if __name__ == "__main__":
    unittest.main()
