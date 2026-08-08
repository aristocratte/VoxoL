#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT_PATH = Path(__file__).with_name("export_voxol_coreml_candidate.py")
SPEC = importlib.util.spec_from_file_location(
    "export_voxol_coreml_candidate",
    SCRIPT_PATH,
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ExportVoxoLCoreMLCandidateTests(unittest.TestCase):
    def test_accepts_the_pinned_export_toolchain(self) -> None:
        MODULE.validate_export_toolchain(
            "9.0",
            "2.7.0+cpu",
            MODULE.TRANSFORMERS_COMMIT,
        )

    def test_rejects_an_unpinned_export_toolchain(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "coremltools"):
            MODULE.validate_export_toolchain(
                "9.1",
                "2.7.0",
                MODULE.TRANSFORMERS_COMMIT,
            )

    def test_maps_official_nemo_attention_names(self) -> None:
        cases = {
            "encoder.layers.20.self_attn.pos_bias_u":
                "encoder.layers.20.self_attn.bias_u",
            "encoder.layers.21.self_attn.linear_q.weight":
                "encoder.layers.21.self_attn.q_proj.weight",
            "encoder.layers.22.self_attn.linear_pos.weight":
                "encoder.layers.22.self_attn.relative_k_proj.weight",
            "encoder.layers.23.feed_forward1.linear1.weight":
                "encoder.layers.23.feed_forward1.linear1.weight",
        }
        for source, expected in cases.items():
            self.assertEqual(
                MODULE.map_nemo_name_to_transformers(source),
                expected,
            )

    def test_rejects_a_delta_outside_the_four_trained_layers(self) -> None:
        payload = {
            "schemaVersion": 2,
            "artifactType": "voxol-parameter-delta",
            "baseModel": MODULE.MODEL_ID,
            "baseRevision": MODULE.MODEL_REVISION,
            "baseArtifactSHA256": MODULE.NEMO_FILE_SHA256,
            "trainedTopEncoderLayers": 4,
            "trainDecoder": False,
            "trainJoint": False,
            "batchNormFrozen": True,
            "stateDelta": {
                f"encoder.layers.{20 + index // 24}.tensor_{index}": object()
                for index in range(MODULE.EXPECTED_DELTA_TENSOR_COUNT)
            },
        }
        payload["stateDelta"]["encoder.layers.19.unexpected"] = payload[
            "stateDelta"
        ].pop("encoder.layers.23.tensor_95")

        with self.assertRaisesRegex(ValueError, "layers mismatch"):
            MODULE.validate_delta_payload(payload)

    def test_accepts_the_exact_schema_two_contract(self) -> None:
        payload = {
            "schemaVersion": 2,
            "artifactType": "voxol-parameter-delta",
            "baseModel": MODULE.MODEL_ID,
            "baseRevision": MODULE.MODEL_REVISION,
            "baseArtifactSHA256": MODULE.NEMO_FILE_SHA256,
            "trainedTopEncoderLayers": 4,
            "trainDecoder": False,
            "trainJoint": False,
            "batchNormFrozen": True,
            "stateDelta": {
                f"encoder.layers.{20 + index // 24}.tensor_{index}": object()
                for index in range(MODULE.EXPECTED_DELTA_TENSOR_COUNT)
            },
        }

        self.assertIs(MODULE.validate_delta_payload(payload), payload)

    def test_hybrid_preserves_only_trained_layers_and_projector(self) -> None:
        self.assertTrue(
            MODULE.preserve_hybrid_fp16_weight(
                "self_encoder_layers_20_self_attn_q_proj_weight_to_fp16"
            )
        )
        self.assertTrue(
            MODULE.preserve_hybrid_fp16_weight(
                "self_encoder_layers_23_feed_forward2_linear2_weight_to_fp16"
            )
        )
        self.assertTrue(
            MODULE.preserve_hybrid_fp16_weight("self_projector_weight_to_fp16")
        )
        self.assertFalse(
            MODULE.preserve_hybrid_fp16_weight(
                "self_encoder_layers_19_self_attn_q_proj_weight_to_fp16"
            )
        )
        self.assertFalse(
            MODULE.preserve_hybrid_fp16_weight(
                "self_encoder_subsampling_linear_weight_to_fp16"
            )
        )


if __name__ == "__main__":
    unittest.main()
