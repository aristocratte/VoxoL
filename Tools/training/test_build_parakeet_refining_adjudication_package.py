import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).with_name("build_parakeet_refining_adjudication_package.py")
SPEC = importlib.util.spec_from_file_location("parakeet_realign", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BuildParakeetRefiningAdjudicationPackageTests(unittest.TestCase):
    def test_build_inputs_replaces_raw_and_neighbors_and_reseals(self) -> None:
        old = {
            "id": "segment-1",
            "language": "fr",
            "raw": "chiper une feature",
            "wispr_edited_candidate": "Shipper une feature.",
            "raw_neighbors": {
                "previous": {"id": "segment-0", "raw": "ancien avant"},
                "next": {"id": "segment-2", "raw": "ancien après"},
            },
            "source": {"title": "Test"},
            "segment": {"recording_id": "recording", "chunk": 1, "chunk_count": 3},
            "quality_control": {"selection_stratum": "ordinary"},
        }
        predictions = {
            "segment-0": {"id": "segment-0", "rawText": "Parakeet avant"},
            "segment-1": {
                "id": "segment-1",
                "rawText": "Je vais chiper une feature",
                "confidence": {"inferenceAttemptCount": 1},
            },
            "segment-2": {"id": "segment-2", "rawText": "Parakeet après"},
        }
        prior = {
            "segment-1": [
                {
                    "reviewer": "draft_a",
                    "decision": "accept_wispr_edited",
                    "refined_edited": "Shipper une feature.",
                }
            ]
        }

        inputs, audit = MODULE.build_inputs(
            [old], predictions, prior, "20260801T000000Z"
        )

        self.assertEqual(inputs[0]["raw"], "Je vais chiper une feature")
        self.assertEqual(inputs[0]["wispr_raw_auxiliary"], "chiper une feature")
        self.assertEqual(inputs[0]["raw_neighbors"]["previous"]["raw"], "Parakeet avant")
        self.assertEqual(inputs[0]["raw_neighbors"]["next"]["raw"], "Parakeet après")
        self.assertFalse(inputs[0]["prior_review_evidence"]["binding"])
        self.assertEqual(inputs[0]["input_sha256"], MODULE.input_sha256(inputs[0]))
        self.assertEqual(audit["requiresFreshAdjudicationCount"], 1)

    def test_missing_prediction_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "Missing Parakeet predictions"):
            MODULE.build_inputs(
                [{"id": "missing"}],
                {},
                {"missing": []},
                "snapshot",
            )

    def test_bulk_archive_excludes_appledouble_sidecars(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            batches = root / "batches"
            batches.mkdir()
            (batches / "batch-fr-01.zip").write_bytes(b"batch")
            (batches / "._batch-fr-01.zip").write_bytes(b"sidecar")
            output = root / "bulk.zip"

            MODULE.write_bulk_archive(output, root, 20, 1)

            with zipfile.ZipFile(output) as archive:
                self.assertIn("batches/batch-fr-01.zip", archive.namelist())
                self.assertNotIn("batches/._batch-fr-01.zip", archive.namelist())


if __name__ == "__main__":
    unittest.main()
