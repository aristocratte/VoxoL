import importlib.util
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import wave


MODULE_PATH = Path(__file__).with_name("collect-gemini-app-batches.py")
SPECIFICATION = importlib.util.spec_from_file_location("gemini_batches", MODULE_PATH)
assert SPECIFICATION and SPECIFICATION.loader
gemini_batches = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(gemini_batches)


class GeminiBatchCollectorTests(unittest.TestCase):
    def test_failed_audio_is_quarantined_without_stopping_or_repeating_the_queue(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'bridge').touch()
            for name in ('bad', 'good'):
                (root / f'{name}.wav').write_bytes(name.encode())
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps({'items': [
                {'id': name, 'audioPath': f'{name}.wav'} for name in ('bad', 'good')
            ]}))
            output = root / 'predictions.jsonl'
            argv = ['collect', '--manifest', str(manifest), '--audio-root', str(root),
                    '--records', str(root / 'records'), '--bridge', str(root / 'bridge'),
                    '--output', str(output), '--batch-size', '1']

            def bridge(items, *args):
                if items[0]['id'] == 'bad':
                    raise ValueError('no readable speech')
                return {'good': ('Bonjour.', 'Bonjour.')}, 100, 'capture.json'

            with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(io.StringIO()):
                with patch.object(gemini_batches, 'invoke_bridge', side_effect=bridge) as invoke:
                    self.assertEqual(gemini_batches.main(), 1)
                    self.assertEqual(invoke.call_count, 4)
                self.assertEqual(json.loads(output.read_text())['id'], 'good')
                failure = json.loads(output.with_suffix('.failures.jsonl').read_text())
                self.assertEqual(failure['id'], 'bad')
                with patch.object(gemini_batches, 'invoke_bridge') as invoke:
                    self.assertEqual(gemini_batches.main(), 1)
                    invoke.assert_not_called()

    def test_parses_fenced_json_and_requires_exact_ids(self) -> None:
        response = """```json
        {"items":[
          {"id":"one","verbatim":"Bonjour.","polished":"Bonjour !"},
          {"id":"two","verbatim":"Hello.","polished":"Hello."}
        ]}
        ```"""

        parsed = gemini_batches.parse_batch_response(response, ["one", "two"])

        self.assertEqual(parsed["one"], ("Bonjour.", "Bonjour !"))
        with self.assertRaisesRegex(ValueError, "missing=three"):
            gemini_batches.parse_batch_response(response, ["one", "two", "three"])

    def test_parses_delimited_batch_with_literal_quotes(self) -> None:
        response = """
        <<<ITEM:one>>>
        <<<VERBATIM>>>
        Il a dit "hello" ?
        <<<POLISHED>>>
        Il a dit « hello » ?
        <<<END_ITEM>>>
        <<<ITEM:two>>>
        <<<VERBATIM>>>
        Oui.
        <<<POLISHED>>>
        Oui.
        <<<END_ITEM>>>
        """

        parsed = gemini_batches.parse_batch_response(response, ["one", "two"])

        self.assertEqual(parsed["one"][0], 'Il a dit "hello" ?')
        self.assertEqual(parsed["two"][1], "Oui.")

        compacted = response.replace("<<<", "<<").replace(">>>", ">>")
        self.assertEqual(
            gemini_batches.parse_batch_response(compacted, ["one", "two"]),
            parsed,
        )

    def test_machine_polish_stays_a_candidate(self) -> None:
        row = gemini_batches.prediction_row(
            "one", "Est-ce que ça marche ?", "Ça marche."
        )

        self.assertEqual(row["finalText"], "Est-ce que ça marche ?")
        self.assertEqual(row["polishedCandidate"], "Ça marche.")
        self.assertEqual(row["teacher"]["labelTier"], "silver")

    def test_alignment_rejects_a_transcript_from_another_audio(self) -> None:
        reference = {
            "rawText": "Ok parfait, on passe à la slide suivante.",
            "finalText": "Ok parfait, on passe à la slide suivante.",
        }

        polished, alignment = gemini_batches.validate_capture_alignment(
            "one",
            "Ok, parfait, on passe à la slide suivante.",
            "Ok, parfait. On passe à la slide suivante.",
            reference,
        )

        self.assertTrue(polished)
        self.assertEqual(alignment["status"], "verified_against_parakeet")
        with self.assertRaisesRegex(ValueError, "transcript/reference mismatch"):
            gemini_batches.validate_capture_alignment(
                "one",
                "Le footer est vraiment pas mal, j'aime beaucoup.",
                "Le footer est vraiment pas mal. J'aime beaucoup.",
                reference,
            )

    def test_alignment_rejects_missing_audio_boilerplate(self) -> None:
        with self.assertRaisesRegex(ValueError, "did not receive the audio"):
            gemini_batches.validate_capture_alignment(
                "one",
                "It looks like no audio file was attached to your request.",
                "Bonjour.",
                None,
            )

    def test_multi_file_alignment_repairs_swapped_labels(self) -> None:
        captures = {
            "one": ("Le footer est vraiment pas mal, j'aime beaucoup.", "Le footer est vraiment pas mal. J'aime beaucoup."),
            "two": ("Ok parfait, on passe à la slide suivante.", "Ok parfait. On passe à la slide suivante."),
        }
        references = {
            "one": {
                "rawText": "Ok parfait, on passe à la slide suivante.",
                "finalText": "Ok parfait, on passe à la slide suivante.",
            },
            "two": {
                "rawText": "Le footer est vraiment pas mal, j'aime beaucoup.",
                "finalText": "Le footer est vraiment pas mal, j'aime beaucoup.",
            },
        }

        aligned = gemini_batches.align_batch_captures(
            captures,
            ["one", "two"],
            references,
        )

        self.assertTrue(aligned["one"][0].startswith("Ok parfait"))
        self.assertTrue(aligned["two"][0].startswith("Le footer"))
        self.assertEqual(aligned["one"][2]["claimedID"], "two")
        self.assertEqual(aligned["one"][2]["status"], "verified_and_assigned")

    def test_old_multi_file_cache_is_not_reused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "predictions.jsonl"
            rows = [
                gemini_batches.prediction_row(
                    "old",
                    "Wrong association.",
                    transport="gemini_macos_batch_file_upload",
                ),
                gemini_batches.prediction_row(
                    "new",
                    "Correct association.",
                    source_audio_sha256="sha-new",
                ),
            ]
            path.write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )

            cached = gemini_batches.load_cached_rows(
                path,
                {"old": "sha-old", "new": "sha-new"},
            )

            self.assertNotIn("old", cached)
            self.assertIn("new", cached)

    def test_aligned_cache_requires_matching_audio_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "predictions.jsonl"
            row = gemini_batches.prediction_row(
                "one", "Bonjour.", transport=gemini_batches.ALIGNED_BATCH_TRANSPORT,
                source_audio_sha256="old-audio",
            )
            path.write_text(json.dumps(row) + "\n", encoding="utf-8")
            self.assertEqual(gemini_batches.load_cached_rows(path, {"one": "changed-audio"}), {})

    def test_duplicate_transcripts_cannot_be_forced_onto_two_distinct_audios(self) -> None:
        captures = {"one": ("Bonjour, je teste le microphone.", ""),
                    "two": ("Bonjour, je teste le microphone.", "")}
        references = {"one": {"rawText": "Bonjour, je teste le microphone."},
                      "two": {"rawText": "Le footer est vraiment pas mal, j'aime beaucoup."}}
        with self.assertRaisesRegex(ValueError, "ambiguous|uncertain"):
            gemini_batches.align_batch_captures(captures, ["one", "two"], references)

    def test_existing_app_record_is_reused_without_promoting_polish(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "sessions/one/audio.wav"
            audio.parent.mkdir(parents=True)
            with wave.open(str(audio), "wb") as output:
                output.setnchannels(1)
                output.setsampwidth(2)
                output.setframerate(16_000)
                output.writeframes(b"\0\0" * 160)
            source_sha = gemini_batches.sha256(audio)
            record_dir = root / "records/capture"
            record_dir.mkdir(parents=True)
            (record_dir / "record.json").write_text(
                json.dumps(
                    {
                        "source": {"sha256": source_sha},
                        "results": [
                            {"raw": "La question ?", "edited": "La question."}
                        ],
                    }
                ),
                encoding="utf-8",
            )
            manifest = {"items": [{"id": "one", "audioPath": "sessions/one/audio.wav"}]}

            rows = gemini_batches.rows_from_records(manifest, root, root / "records")

            self.assertEqual(rows["one"]["rawText"], "La question ?")
            self.assertEqual(rows["one"]["finalText"], "La question ?")
            self.assertEqual(rows["one"]["polishedCandidate"], "La question.")


if __name__ == "__main__":
    unittest.main()
