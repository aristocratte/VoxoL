import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from build_wispr_youtube_campaign import build


class BuildWisprYoutubeCampaignTests(unittest.TestCase):
    def test_keeps_failed_and_missing_audio_visible(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            collection = root / "collection"
            records = collection / "dataset" / "records"
            record_dir = records / "youtube-aaaaaaaaaaa-1234567890abcdef"
            (record_dir / "audio").mkdir(parents=True)
            cache = collection / "youtube-audio"
            cache.mkdir()
            source = cache / "youtube-aaaaaaaaaaa.mp3"
            source.write_bytes(b"source audio")
            (cache / "youtube-aaaaaaaaaaa.source.json").write_text(
                json.dumps({"audio_sha256": hashlib.sha256(source.read_bytes()).hexdigest()})
            )
            chunk = record_dir / "audio" / "chunk_0001.wav"
            chunk.write_bytes(b"segment audio")
            (record_dir / "audio" / "source-16k.wav").write_bytes(b"full audio")
            result = {
                "chunk": 1, "audio_path": "audio/chunk_0001.wav",
                "audio_sha256": hashlib.sha256(chunk.read_bytes()).hexdigest(),
                "duration_seconds": 1.5, "raw": "bonjour test",
                "raw_http_status": "200", "edited": "", "edited_http_status": "500",
                "detected_language": "fr",
            }
            (record_dir / "record.json").write_text(json.dumps({
                "recording_id": record_dir.name,
                "source": {"youtube": {"video_id": "aaaaaaaaaaa"},
                           "sha256": hashlib.sha256(source.read_bytes()).hexdigest()},
                "collection": {"requested_language": "auto", "speaker_id": ""},
                "results": [result], "summary": {"complete": False},
            }))
            table = root / "table.md"
            table.write_text(
                "### Français\n"
                "| 1 | [First](https://www.youtube.com/watch?v=aaaaaaaaaaa), A, `aaaaaaaaaaa` | FR | x | **`None`** |\n"
                "### Anglais\n"
                "| 2 | [Second](https://www.youtube.com/watch?v=bbbbbbbbbbb), B, `bbbbbbbbbbb` | EN | x | **`All`** |\n"
            )
            output = root / "prepared"
            report = build(collection, table, output)
            self.assertEqual(report["source_video_count"], 2)
            self.assertEqual(report["audio_present_count"], 3)
            self.assertEqual(report["missing_source_video_ids"], ["bbbbbbbbbbb"])
            self.assertEqual(report["teacher_chunk_count"], 1)
            self.assertEqual(report["qwen_edited_target_count"], 0)
            rows = [json.loads(line) for line in (output / "teacher-all.jsonl").read_text().splitlines()]
            self.assertEqual(rows[0]["requested_language"], "fr")
            self.assertEqual(rows[0]["collection_requested_language"], "auto")
            self.assertFalse(rows[0]["approved"])
            self.assertFalse(rows[0]["humanReviewed"])
            reusable = root / "sources.json"
            catalog = json.loads((output / "source-catalog.json").read_text())
            reusable.write_text(json.dumps({"source_table_sha256": catalog["source_table_sha256"],
                                            "videos": catalog["videos"]}))
            second = build(collection, reusable, root / "prepared-again")
            self.assertEqual(second["teacher_chunk_count"], report["teacher_chunk_count"])
            self.assertEqual(second["audio_present_count"], report["audio_present_count"])


if __name__ == "__main__":
    unittest.main()
