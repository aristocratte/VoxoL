#!/usr/bin/env python3
"""Regression tests for the memory-bounded NeMo training configuration."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import torch
import unittest


SCRIPT_PATH = Path(__file__).with_name("run_voxol_nemo_finetune.py")
SPEC = importlib.util.spec_from_file_location("run_voxol_nemo_finetune", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class VoxoLNeMoFineTuneTests(unittest.TestCase):
    def test_experiment_manager_disables_full_model_checkpoints(self) -> None:
        configuration = MODULE.experiment_manager_configuration("/tmp/voxol")

        self.assertFalse(configuration["create_checkpoint_callback"])
        self.assertFalse(configuration["resume_if_exists"])

    def test_delta_checkpoint_has_a_bounded_artifact_name(self) -> None:
        path = MODULE.delta_checkpoint_path(Path("/tmp/voxol"))

        self.assertEqual(path.name, "best-trainable-parameters.delta.pt")

    def test_full_checkpoint_is_published_atomically(self) -> None:
        class Trainer:
            def save_checkpoint(self, path, weights_only):
                self.path = Path(path)
                self.weights_only = weights_only
                self.path.write_bytes(b"complete")

        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "step-000018.ckpt"
            trainer = Trainer()

            MODULE.atomic_trainer_checkpoint(trainer, destination)

            self.assertEqual(destination.read_bytes(), b"complete")
            self.assertFalse(
                destination.with_suffix(".ckpt.partial").exists()
            )
            self.assertFalse(trainer.weights_only)

    def test_true_delta_contains_only_trainable_parameters_in_fp32(self) -> None:
        class Encoder(torch.nn.Module):
            def __init__(self) -> None:
                super().__init__()
                self.layers = torch.nn.ModuleList(
                    [torch.nn.Linear(2, 2) for _ in range(3)]
                )

        class Model(torch.nn.Module):
            def __init__(self) -> None:
                super().__init__()
                self.preprocessor = torch.nn.Linear(2, 2)
                self.encoder = Encoder()
                self.decoder = torch.nn.Linear(2, 2)
                self.joint = torch.nn.Linear(2, 2)

        model = Model()
        MODULE.configure_trainable_parameters(model, 1)
        base = MODULE.capture_trainable_base_state(model, torch)
        with torch.no_grad():
            for parameter in model.parameters():
                if parameter.requires_grad:
                    parameter.add_(0.25)
        state = MODULE.true_parameter_delta(model, base, torch)

        self.assertTrue(state)
        self.assertTrue(all(tensor.dtype == torch.float32 for tensor in state.values()))
        self.assertTrue(
            all(
                torch.allclose(tensor, torch.full_like(tensor, 0.25))
                for tensor in state.values()
            )
        )
        self.assertFalse(any(name.startswith("preprocessor.") for name in state))
        self.assertFalse(any(name.startswith("encoder.layers.0.") for name in state))
        self.assertFalse(any(name.startswith("encoder.layers.1.") for name in state))
        self.assertTrue(any(name.startswith("encoder.layers.2.") for name in state))
        self.assertTrue(any(name.startswith("decoder.") for name in state))
        self.assertTrue(any(name.startswith("joint.") for name in state))

    def test_encoder_only_recipe_freezes_batchnorm_decoder_and_joint(self) -> None:
        class Block(torch.nn.Module):
            def __init__(self) -> None:
                super().__init__()
                self.linear = torch.nn.Linear(2, 2)
                self.batchnorm = torch.nn.BatchNorm1d(2)

        class Encoder(torch.nn.Module):
            def __init__(self) -> None:
                super().__init__()
                self.layers = torch.nn.ModuleList([Block(), Block()])

        class Model(torch.nn.Module):
            def __init__(self) -> None:
                super().__init__()
                self.encoder = Encoder()
                self.decoder = torch.nn.Linear(2, 2)
                self.joint = torch.nn.Linear(2, 2)

        model = Model()
        MODULE.configure_trainable_parameters(
            model,
            1,
            train_decoder=False,
            train_joint=False,
            freeze_batchnorm=True,
            torch=torch,
        )
        MODULE.freeze_batchnorm_modules(model, torch)
        parameters = dict(model.named_parameters())

        self.assertTrue(parameters["encoder.layers.1.linear.weight"].requires_grad)
        self.assertFalse(
            parameters["encoder.layers.1.batchnorm.weight"].requires_grad
        )
        self.assertFalse(parameters["decoder.weight"].requires_grad)
        self.assertFalse(parameters["joint.weight"].requires_grad)
        self.assertFalse(model.encoder.layers[1].batchnorm.training)

    def test_validation_manifest_resolves_relative_audio_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / "validation.jsonl"
            manifest.write_text(
                json.dumps(
                    {
                        "audio_path": "audio/example.wav",
                        "text": "Bonjour le monde.",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            items = MODULE.load_validation_items(manifest)

        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].reference, "Bonjour le monde.")
        self.assertEqual(items[0].audio_path, str((root / "audio/example.wav").resolve()))

    def test_normalized_validation_score_ignores_case_and_punctuation(self) -> None:
        score = MODULE.normalized_validation_score(
            ["Bonjour, le MONDE !", "L’application fonctionne."],
            ["bonjour le monde", "l'application fonctionne"],
        )

        self.assertEqual(score["microWER"], 0.0)
        self.assertEqual(score["wordErrors"], 0)
        self.assertEqual(score["referenceWords"], 5)

    def test_validation_model_scores_every_item_globally(self) -> None:
        class Hypothesis:
            def __init__(self, text: str) -> None:
                self.text = text

        class Model:
            def __init__(self) -> None:
                self.calls = []

            def transcribe(self, audio, batch_size, verbose):
                self.calls.append((audio, batch_size, verbose))
                return [
                    Hypothesis("hello world") if path == "first.wav" else "bonjour"
                    for path in audio
                ]

        model = Model()
        score = MODULE.score_validation_model(
            model,
            [
                MODULE.ValidationItem("first.wav", "Hello, world!"),
                MODULE.ValidationItem("second.wav", "Bonjour."),
            ],
            batch_size=1,
        )

        self.assertEqual(score["microWER"], 0.0)
        self.assertEqual(len(model.calls), 2)


if __name__ == "__main__":
    unittest.main()
