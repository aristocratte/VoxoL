#!/usr/bin/env python3
"""Round-trip tests for VoxoL's bounded NeMo trainable delta."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import torch
import unittest


SCRIPT_PATH = Path(__file__).with_name("run_nemo_asr_benchmark.py")
SPEC = importlib.util.spec_from_file_location("run_nemo_asr_benchmark", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class TinyModel(torch.nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.projection = torch.nn.Linear(2, 2, bias=False)


class NeMoDeltaTests(unittest.TestCase):
    def test_resume_removes_only_an_incomplete_trailing_prediction(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            predictions = Path(directory) / "predictions.jsonl"
            predictions.write_text(
                '{"id":"complete"}\n{"id":"interrupted"',
                encoding="utf-8",
            )

            rows = MODULE.read_jsonl(predictions)

            self.assertEqual(rows, [{"id": "complete"}])
            self.assertEqual(
                predictions.read_text(encoding="utf-8"),
                '{"id":"complete"}\n',
            )

    def test_delta_reconstructs_selected_model_tensor(self) -> None:
        model = TinyModel()
        expected = torch.full_like(model.projection.weight, 0.25)
        payload = {
            "schemaVersion": 1,
            "baseModel": MODULE.MODEL_ID,
            "epoch": 2,
            "stateDict": {"projection.weight": expected.to(torch.float16)},
        }
        with tempfile.TemporaryDirectory() as directory:
            delta = Path(directory) / "candidate.delta.pt"
            torch.save(payload, delta)
            metadata = MODULE.apply_trainable_delta(model, delta, torch)

        self.assertEqual(metadata["epoch"], 2)
        self.assertTrue(torch.equal(model.projection.weight, expected))

    def test_true_fp32_delta_adds_to_the_pinned_base_tensor(self) -> None:
        model = TinyModel()
        original = model.projection.weight.detach().clone()
        update = torch.full_like(original, 0.125, dtype=torch.float32)
        payload = {
            "schemaVersion": 2,
            "artifactType": "voxol-parameter-delta",
            "baseModel": MODULE.MODEL_ID,
            "baseRevision": MODULE.MODEL_REVISION,
            "baseArtifactSHA256": "base-sha",
            "epoch": 0,
            "stateDelta": {"projection.weight": update},
        }
        with tempfile.TemporaryDirectory() as directory:
            delta = Path(directory) / "candidate.delta.pt"
            torch.save(payload, delta)
            MODULE.apply_trainable_delta(
                model,
                delta,
                torch,
                base_artifact_sha256="base-sha",
            )

        self.assertTrue(torch.allclose(model.projection.weight, original + update))


if __name__ == "__main__":
    unittest.main()
