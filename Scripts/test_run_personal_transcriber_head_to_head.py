import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("run-personal-transcriber-head-to-head.py")
SPECIFICATION = importlib.util.spec_from_file_location("head_to_head", MODULE_PATH)
assert SPECIFICATION and SPECIFICATION.loader
head_to_head = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(head_to_head)


class HeadToHeadRunnerTests(unittest.TestCase):
    def test_gemini_cache_does_not_skip_invalidating_old_batches(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "audio.wav").write_bytes(b"audio")
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"items": [{"id": "one", "audioPath": "audio.wav"}]}))
            predictions = root / "predictions.jsonl"
            predictions.write_text(json.dumps({"id": "one", "rawText": "Bonjour",
                "teacher": {"transport": "gemini_macos_batch_file_upload"}}) + "\n")
            self.assertFalse(head_to_head.gemini_predictions_cover(predictions, manifest, root))

    def test_report_is_recomputed_when_predictions_change(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, predictions = root / "manifest.json", root / "predictions.jsonl"
            report, items = root / "report.json", root / "items.jsonl"
            manifest.write_text('{}')
            predictions.write_text('first')
            report.write_text('{}')
            items.write_text('{}')
            def score_output(command):
                Path(command[command.index('--output') + 1]).write_text('{}')
                Path(command[command.index('--per-item') + 1]).write_text('{}')

            with patch.object(head_to_head, "run", side_effect=score_output) as run:
                head_to_head.score(Path('cli'), manifest, predictions, report, items)
                head_to_head.score(Path('cli'), manifest, predictions, report, items)
                self.assertEqual(run.call_count, 1)
                predictions.write_text('corrected')
                head_to_head.score(Path('cli'), manifest, predictions, report, items)
                self.assertEqual(run.call_count, 2)

    def test_prediction_cache_requires_every_requested_item(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            predictions = Path(temporary) / "predictions.jsonl"
            predictions.write_text(
                json.dumps({"id": "one"}) + "\n" + json.dumps({"id": "two"}) + "\n",
                encoding="utf-8",
            )

            self.assertTrue(head_to_head.predictions_cover(predictions, {"one", "two"}))
            self.assertFalse(
                head_to_head.predictions_cover(predictions, {"one", "two", "three"})
            )

    def test_adjudicated_benchmarks_are_content_addressed(self) -> None:
        root = Path("/tmp/benchmark")
        first = {"schemaVersion": 1, "items": [{"id": "one", "reference": "alpha"}]}
        reordered = {"items": [{"reference": "alpha", "id": "one"}], "schemaVersion": 1}
        changed = {"schemaVersion": 1, "items": [{"id": "one", "reference": "beta"}]}

        first_path = head_to_head.adjudicated_benchmark_root(root, first)

        self.assertEqual(
            first_path,
            head_to_head.adjudicated_benchmark_root(root, reordered),
        )
        self.assertNotEqual(
            first_path,
            head_to_head.adjudicated_benchmark_root(root, changed),
        )
        self.assertEqual(first_path.parent, root / "adjudicated-benchmarks")

    def test_adjudicated_predictions_contain_only_accepted_items(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "predictions.jsonl"
            destination = root / "accepted.jsonl"
            source.write_text(
                "".join(
                    json.dumps({"id": identifier, "rawText": identifier}) + "\n"
                    for identifier in ("accepted", "quarantined")
                ),
                encoding="utf-8",
            )

            head_to_head.filter_predictions(source, destination, {"accepted"})

            rows = [
                json.loads(line)
                for line in destination.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual([row["id"] for row in rows], ["accepted"])


if __name__ == "__main__":
    unittest.main()
