#!/usr/bin/env python3
"""Regression tests for the memory-bounded NeMo training configuration."""

from __future__ import annotations

from dataclasses import replace
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

    def warmstart_model(self):
        model = torch.nn.Module()
        model.encoder = torch.nn.Module()
        model.encoder.layers = torch.nn.ModuleList([torch.nn.Linear(2, 2) for _ in range(3)])
        model.decoder = torch.nn.Linear(2, 2)
        model.joint = torch.nn.Linear(2, 2)
        with torch.no_grad():
            for parameter in model.parameters():
                parameter.fill_(1.0)
        MODULE.configure_trainable_parameters(
            model, 1, train_decoder=False, train_joint=False,
            freeze_batchnorm=True, torch=torch,
        )
        return model

    def initial_payload(self, model):
        return {
            "schemaVersion": 2,
            "artifactType": "voxol-parameter-delta",
            "baseModel": MODULE.MODEL_ID,
            "baseRevision": MODULE.MODEL_REVISION,
            "baseArtifactSHA256": "base-artifact-sha",
            "trainedTopEncoderLayers": 1,
            "trainDecoder": False,
            "trainJoint": False,
            "batchNormFrozen": True,
            "stateDelta": {
                name: torch.full_like(parameter, 0.25)
                for name, parameter in model.named_parameters() if parameter.requires_grad
            },
        }

    def warmstart_arguments(self, root, delta=None, digest=None):
        arguments = [
            "--train-manifest", str(root / "train.jsonl"),
            "--validation-manifest", str(root / "validation.jsonl"),
            "--experiment-root", str(root / "experiment"),
            "--precision", "bf16-mixed", "--batch-size", "1",
            "--validation-batch-size", "1", "--accumulate-grad-batches", "16",
            "--max-duration", "30", "--train-top-encoder-layers", "1",
            "--freeze-decoder", "--freeze-joint", "--freeze-batchnorm", "--dry-run",
        ]
        if delta is not None:
            arguments += ["--initial-delta", str(delta)]
        if digest is not None:
            arguments += ["--initial-delta-sha256", digest]
        return arguments

    def test_warmstart_exports_parent_and_new_updates_against_original_base(self) -> None:
        model = self.warmstart_model()
        original = {name: tensor.clone() for name, tensor in model.state_dict().items()}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            delta = root / "parent.delta.pt"
            torch.save(self.initial_payload(model), delta)
            configuration = MODULE.validated_configuration(MODULE.parser().parse_args(
                self.warmstart_arguments(root, delta, MODULE.sha256(delta))
            ))
            base, receipt = MODULE.initialize_trainable_state(
                model, configuration, "base-artifact-sha", torch,
            )
            parent_only = MODULE.true_parameter_delta(model, base, torch)
            self.assertTrue(all(torch.equal(t, torch.full_like(t, 0.25)) for t in parent_only.values()))
            with torch.no_grad():
                for parameter in model.parameters():
                    if parameter.requires_grad:
                        parameter.add_(0.125)
            cumulative = MODULE.true_parameter_delta(model, base, torch)
        self.assertTrue(all(torch.equal(t, torch.full_like(t, 0.375)) for t in cumulative.values()))
        reconstructed = self.warmstart_model()
        reconstructed.load_state_dict(original)
        with torch.no_grad():
            for name, parameter in reconstructed.named_parameters():
                if name in cumulative:
                    parameter.add_(cumulative[name])
                else:
                    self.assertTrue(torch.equal(dict(model.named_parameters())[name], original[name]))
        self.assertTrue(all(torch.equal(a, b) for a, b in zip(model.parameters(), reconstructed.parameters())))
        self.assertFalse(receipt["optimizerResumed"])
        self.assertEqual(receipt["outputDeltaReference"], "pinned-nvidia-base")

    def test_warmstart_rejects_hash_metadata_and_invalid_tensors_before_mutation(self) -> None:
        mutations = ["hash", "base", "recipe", "missing", "extra", "shape", "nonfinite", "dtype"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for mutation in mutations:
                with self.subTest(mutation=mutation):
                    model = self.warmstart_model()
                    original = {name: tensor.clone() for name, tensor in model.state_dict().items()}
                    payload = self.initial_payload(model)
                    name = list(payload["stateDelta"])[-1]
                    if mutation == "base":
                        payload["baseArtifactSHA256"] = "wrong-base"
                    elif mutation == "recipe":
                        payload["trainDecoder"] = True
                    elif mutation == "missing":
                        del payload["stateDelta"][name]
                    elif mutation == "extra":
                        payload["stateDelta"]["decoder.weight"] = torch.ones(2, 2)
                    elif mutation == "shape":
                        payload["stateDelta"][name] = torch.zeros(3, 3)
                    elif mutation == "nonfinite":
                        payload["stateDelta"][name].fill_(float("nan"))
                    elif mutation == "dtype":
                        payload["stateDelta"][name] = payload["stateDelta"][name].half()
                    delta = root / "parent.delta.pt"
                    torch.save(payload, delta)
                    configuration = MODULE.validated_configuration(MODULE.parser().parse_args(
                        self.warmstart_arguments(root, delta, MODULE.sha256(delta))
                    ))
                    if mutation == "hash":
                        configuration = replace(configuration, initial_delta_sha256="0" * 64)
                    with self.assertRaises(ValueError):
                        MODULE.initialize_trainable_state(model, configuration, "base-artifact-sha", torch)
                    self.assertTrue(all(torch.equal(value, original[key]) for key, value in model.state_dict().items()))

    def test_initial_delta_cli_requires_hash_and_excludes_optimizer_resume(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            delta = root / "parent.delta.pt"
            delta.write_bytes(b"parent")
            for arguments in [
                self.warmstart_arguments(root, delta),
                self.warmstart_arguments(root, digest="0" * 64),
                self.warmstart_arguments(root, delta, "invalid"),
                self.warmstart_arguments(root, delta, "0" * 64),
                [arg for arg in self.warmstart_arguments(root, delta, MODULE.sha256(delta)) if arg != "--freeze-joint"],
            ]:
                with self.subTest(arguments=arguments), self.assertRaises(SystemExit):
                    MODULE.validated_configuration(MODULE.parser().parse_args(arguments))
            with self.assertRaises(SystemExit):
                MODULE.parser().parse_args(self.warmstart_arguments(root, delta, "0" * 64) + ["--resume-checkpoint", "resume.ckpt"])

    def test_stock_initialization_keeps_existing_delta_behavior(self) -> None:
        model = self.warmstart_model()
        with tempfile.TemporaryDirectory() as directory:
            configuration = MODULE.validated_configuration(MODULE.parser().parse_args(
                self.warmstart_arguments(Path(directory))
            ))
            base, receipt = MODULE.initialize_trainable_state(model, configuration, "base-artifact-sha", torch)
        self.assertIsNone(receipt)
        self.assertTrue(all(torch.count_nonzero(t).item() == 0 for t in MODULE.true_parameter_delta(model, base, torch).values()))

    def test_initial_delta_rejects_existing_experiment_even_in_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            delta = root / "parent.delta.pt"
            delta.write_bytes(b"parent")
            experiment = root / "experiment"
            experiment.mkdir()
            (experiment / "best-trainable-parameters.delta.pt").write_bytes(b"old-candidate")
            with self.assertRaisesRegex(SystemExit, "empty experiment"):
                MODULE.validated_configuration(MODULE.parser().parse_args(
                    self.warmstart_arguments(root, delta, MODULE.sha256(delta))
                ))

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
