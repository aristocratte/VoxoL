import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).with_name("build_full_parakeet_refining_campaign.py")
SPEC = importlib.util.spec_from_file_location("full_refining_campaign", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BuildFullParakeetRefiningCampaignTests(unittest.TestCase):
    def test_final_runtime_raw_is_sealed_and_unverified_rights_are_held(self) -> None:
        row = {
            "id": "segment-1",
            "recording_id": "recording-1",
            "chunk": 1,
            "detected_language": "fr",
            "source_sha256": "source-sha",
            "duration": 3.0,
            "raw": "ancien raw Wispr",
            "edited": "Ancien candidat Wispr.",
            "raw_http_status": "200",
            "edited_http_status": "200",
            "usable_for_polisher": True,
        }
        neighbor = {
            **row,
            "id": "segment-2",
            "chunk": 2,
            "raw": "voisin Wispr",
            "edited": "Voisin Wispr.",
            "usable_for_polisher": False,
        }
        predictions = {
            "segment-1": {
                "id": "segment-1",
                "rawText": "raw exact Core ML",
                "confidence": {"inferenceAttemptCount": 1},
            },
            "segment-2": {"id": "segment-2", "rawText": "voisin exact"},
        }
        sources = {
            "source-sha": {
                "original_sha256": "source-sha",
                "title": "Source test",
                "license": "Not specified by platform",
            }
        }

        inputs, counts = MODULE.build_inputs(
            [row],
            [row, neighbor],
            sources,
            predictions,
            {},
            "snapshot",
            "seed",
        )

        self.assertEqual(inputs[0]["raw"], "raw exact Core ML")
        self.assertEqual(inputs[0]["wispr_raw_auxiliary"], "ancien raw Wispr")
        self.assertEqual(inputs[0]["raw_neighbors"]["next"]["raw"], "voisin exact")
        self.assertEqual(
            inputs[0]["quality_control"]["training_rights_status"], "hold"
        )
        self.assertEqual(inputs[0]["input_sha256"], MODULE.input_sha256(inputs[0]))
        self.assertEqual(counts["rights:hold"], 1)
        MODULE.validate_inputs(inputs, [row], predictions)

    def test_bundle_contains_only_requested_batches_and_checksums(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "batches").mkdir()
            (root / "batches" / "batch-fr-01.zip").write_bytes(b"fr")
            (root / "batches" / "batch-en-01.zip").write_bytes(b"en")
            output = root / "bundle.zip"

            MODULE.write_bundle(output, root, ["batch-fr-01"], "instructions")

            with zipfile.ZipFile(output) as archive:
                names = set(archive.namelist())
                self.assertIn("batches/batch-fr-01.zip", names)
                self.assertNotIn("batches/batch-en-01.zip", names)
                self.assertIn("BATCHES.sha256", names)
                self.assertIn(
                    "batches/batch-fr-01.zip",
                    archive.read("BATCHES.sha256").decode("utf-8"),
                )


if __name__ == "__main__":
    unittest.main()
