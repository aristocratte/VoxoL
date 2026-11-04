from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("run-launch-benchmark.py")
SPEC = importlib.util.spec_from_file_location("run_launch_benchmark", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RunLaunchBenchmarkTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    @staticmethod
    def write(path: Path, content: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def make_runtime(self, name: str, encoder: bytes = b"encoder") -> Path:
        root = self.root / name
        self.write(root / "encoder.mlpackage/Data/model.bin", encoder)
        self.write(root / "decoder.mlpackage/Data/model.bin", b"decoder")
        self.write(root / "joint.mlpackage/Data/model.bin", b"joint")
        self.write(root / "tokenizer.json", b"tokenizer")
        self.write(
            root / "language-penalty.json",
            b'{"french_suppressed_token_ids":[1,2,3]}\n',
        )
        return root

    def test_encoder_candidate_requires_identical_runtime_support(self) -> None:
        reference = self.make_runtime("reference", b"encoder-reference")
        candidate = self.make_runtime("candidate", b"encoder-candidate")

        result = MODULE.verify_encoder_candidate_model(reference, candidate)

        self.assertNotEqual(
            result["referenceEncoderSHA256"], result["candidateEncoderSHA256"]
        )
        self.assertEqual(
            [entry["path"] for entry in result["runtimeSupport"]],
            list(MODULE.RUNTIME_SUPPORT_COMPONENTS),
        )

    def test_encoder_candidate_rejects_decoder_drift(self) -> None:
        reference = self.make_runtime("reference", b"encoder-reference")
        candidate = self.make_runtime("candidate", b"encoder-candidate")
        self.write(candidate / "decoder.mlpackage/Data/model.bin", b"different-decoder")

        with self.assertRaisesRegex(ValueError, "decoder.mlpackage"):
            MODULE.verify_encoder_candidate_model(reference, candidate)

    def test_encoder_candidate_rejects_language_penalty_drift(self) -> None:
        reference = self.make_runtime("reference", b"encoder-reference")
        candidate = self.make_runtime("candidate", b"encoder-candidate")
        self.write(
            candidate / "language-penalty.json",
            b'{"french_suppressed_token_ids":[4,5,6]}\n',
        )

        with self.assertRaisesRegex(ValueError, "language-penalty.json"):
            MODULE.verify_encoder_candidate_model(reference, candidate)

    def test_encoder_candidate_rejects_identical_encoder(self) -> None:
        reference = self.make_runtime("reference", b"same-encoder")
        candidate = self.make_runtime("candidate", b"same-encoder")

        with self.assertRaisesRegex(ValueError, "byte-identical"):
            MODULE.verify_encoder_candidate_model(reference, candidate)

    def test_registry_model_files_rejects_byte_drift(self) -> None:
        runtime = self.make_runtime("runtime")
        tokenizer = runtime / "tokenizer.json"
        model = {
            "artifact": {
                "files": [
                    {"path": "tokenizer.json", "sha256": MODULE.sha256(tokenizer)}
                ]
            }
        }
        self.write(tokenizer, b"changed-tokenizer")

        with self.assertRaisesRegex(ValueError, "registry"):
            MODULE.verify_registry_model_files(runtime, model)

    def test_encoder_window_runtime_requires_shorter_candidate(self) -> None:
        result = MODULE.verify_encoder_window_runtime(
            [
                {"variant": "baseline", "maximumWaveformSampleCount": 480_000},
                {"variant": "candidate", "maximumWaveformSampleCount": 320_000},
                {"variant": "candidate", "maximumWaveformSampleCount": 320_000},
                {"variant": "baseline", "maximumWaveformSampleCount": 480_000},
            ]
        )

        self.assertEqual(result["referenceMaximumWaveformSampleCount"], 480_000)
        self.assertEqual(result["candidateMaximumWaveformSampleCount"], 320_000)
        self.assertAlmostEqual(result["reductionPercent"], 100 / 3)

    def test_encoder_window_runtime_rejects_same_capacity(self) -> None:
        blocks = [
            {"variant": "baseline", "maximumWaveformSampleCount": 480_000},
            {"variant": "candidate", "maximumWaveformSampleCount": 480_000},
        ]

        with self.assertRaisesRegex(RuntimeError, "shorter waveform capacity"):
            MODULE.verify_encoder_window_runtime(blocks)


if __name__ == "__main__":
    unittest.main()
