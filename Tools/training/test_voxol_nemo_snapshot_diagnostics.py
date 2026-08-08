#!/usr/bin/env python3
"""Tests for VoxoL's legacy snapshot decomposition."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import torch
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT))
SCRIPT = Path(__file__).with_name("run_voxol_nemo_snapshot_diagnostics.py")
SPEC = importlib.util.spec_from_file_location(
    "run_voxol_nemo_snapshot_diagnostics",
    SCRIPT,
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class Block(torch.nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.linear = torch.nn.Linear(2, 2, bias=False)
        self.batchnorm = torch.nn.BatchNorm1d(2)


class Encoder(torch.nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.layers = torch.nn.ModuleList([Block() for _ in range(24)])


class Model(torch.nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.encoder = Encoder()
        self.decoder = torch.nn.Linear(2, 2, bias=False)
        self.joint = torch.nn.Linear(2, 2, bias=False)


class SnapshotDiagnosticsTests(unittest.TestCase):
    @staticmethod
    def benchmark_report(wer: float, deletion_rate: float = 0.01) -> dict:
        return {
            "microWER": wer,
            "emptyOutputCount": 0,
            "wordErrors": {"deletionRate": deletion_rate},
            "byLanguage": {
                "english": {"microWER": wer},
                "french": {"microWER": wer},
            },
        }

    def test_groups_separate_encoder_batchnorm_and_decoder_joint(self) -> None:
        model = Model()
        names = {
            name
            for name in model.state_dict()
            if name.startswith(("encoder.layers.20.", "decoder.", "joint."))
        }

        groups = MODULE.model_state_groups(model, names, torch)

        self.assertIn("encoder.layers.20.linear.weight", groups["encoder"])
        self.assertIn(
            "encoder.layers.20.batchnorm.running_mean",
            groups["batchnorm"],
        )
        self.assertIn("decoder.weight", groups["decoderJoint"])
        self.assertIn("joint.weight", groups["decoderJoint"])

    def test_composition_can_apply_encoder_without_decoder_or_batchnorm(self) -> None:
        model = Model()
        names = {
            name
            for name in model.state_dict()
            if name.startswith(("encoder.layers.20.", "decoder.", "joint."))
        }
        groups = MODULE.model_state_groups(model, names, torch)
        base = MODULE.capture_state(model, names)
        candidate = {
            name: (
                tensor.to(dtype=torch.float32) + 1
                if tensor.is_floating_point()
                else tensor.clone()
            )
            for name, tensor in base.items()
        }

        MODULE.apply_legacy_composition(
            model,
            base,
            candidate,
            groups,
            1.0,
            0.0,
            False,
            torch,
        )
        state = model.state_dict()

        self.assertTrue(
            torch.allclose(
                state["encoder.layers.20.linear.weight"],
                base["encoder.layers.20.linear.weight"] + 1,
            )
        )
        self.assertTrue(
            torch.equal(state["decoder.weight"], base["decoder.weight"])
        )
        self.assertTrue(
            torch.equal(
                state["encoder.layers.20.batchnorm.running_mean"],
                base["encoder.layers.20.batchnorm.running_mean"],
            )
        )

    def test_grid_analysis_selects_a_general_preserving_teacher_gain(self) -> None:
        grid = {}
        for encoder_alpha in (0.0, 1.0):
            for decoder_alpha in (0.0, 1.0):
                for batchnorm in ("base", "candidate"):
                    identifier = (
                        f"E{encoder_alpha:g}-DJ{decoder_alpha:g}-BN{batchnorm}"
                    )
                    general_wer = 0.05
                    teacher_wer = 0.10
                    if encoder_alpha == 1.0:
                        teacher_wer -= 0.02
                    if decoder_alpha == 1.0:
                        general_wer += 0.01
                    if batchnorm == "candidate":
                        general_wer += 0.005
                    grid[identifier] = {
                        "encoderAlpha": encoder_alpha,
                        "decoderJointAlpha": decoder_alpha,
                        "batchNorm": batchnorm,
                        "benchmarks": {
                            "fleurs-validation": self.benchmark_report(
                                general_wer
                            ),
                            "teacher-validation": self.benchmark_report(
                                teacher_wer
                            ),
                        },
                    }

        analysis = MODULE.analyze_grid(grid)

        self.assertEqual(
            analysis["bestGeneralPreservingComposition"],
            "E1-DJ0-BNbase",
        )
        self.assertGreater(
            analysis["averageFleursWEREffects"]["candidateBatchNorm"],
            0,
        )

    def test_validation_reconciliation_normalizes_percent_values(self) -> None:
        result = MODULE.validation_reconciliation(4.8, 0.048)

        self.assertTrue(result["passed"])
        self.assertEqual(result["recordedNormalized"], 0.048)


if __name__ == "__main__":
    unittest.main()
