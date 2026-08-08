#!/usr/bin/env python3
"""Fine-tune Parakeet with a memory-bounded, architecture-preserving recipe."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import gc
import hashlib
import json
import os
from pathlib import Path
import re
from typing import Iterable

try:
    from Tools.training.score_asr_predictions import edit_distance, normalize
except ModuleNotFoundError:
    from score_asr_predictions import edit_distance, normalize


MODEL_ID = "nvidia/parakeet-tdt-0.6b-v3"
MODEL_REVISION = "7c35754d166cca382ad1e53e68b01e7c575f3a1d"
MODEL_FILENAME = "parakeet-tdt-0.6b-v3.nemo"
ENCODER_LAYER_PATTERN = re.compile(r"^encoder\.layers\.(\d+)\.")


@dataclass(frozen=True)
class TrainingConfiguration:
    train_manifest: str
    validation_manifest: str
    experiment_root: str
    precision: str
    batch_size: int
    validation_batch_size: int
    accumulate_grad_batches: int
    max_duration: float
    train_top_encoder_layers: int
    train_decoder: bool
    train_joint: bool
    freeze_batchnorm: bool
    max_epochs: int
    max_steps: int
    learning_rate: float
    minimum_learning_rate: float
    warmup_steps: int
    checkpoint_every_n_steps: int
    num_workers: int
    seed: int
    deterministic: bool
    resume_checkpoint: str | None


@dataclass(frozen=True)
class ValidationItem:
    audio_path: str
    reference: str


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--train-manifest", type=Path, required=True)
    result.add_argument("--validation-manifest", type=Path, required=True)
    result.add_argument("--experiment-root", type=Path, required=True)
    result.add_argument("--precision", choices=("16-mixed", "bf16-mixed"), required=True)
    result.add_argument("--batch-size", type=int, required=True)
    result.add_argument("--validation-batch-size", type=int, required=True)
    result.add_argument("--accumulate-grad-batches", type=int, required=True)
    result.add_argument("--max-duration", type=float, required=True)
    result.add_argument("--train-top-encoder-layers", type=int, default=8)
    result.add_argument("--freeze-decoder", action="store_true")
    result.add_argument("--freeze-joint", action="store_true")
    result.add_argument("--freeze-batchnorm", action="store_true")
    result.add_argument("--max-epochs", type=int, default=5)
    result.add_argument("--max-steps", type=int, default=0)
    result.add_argument("--learning-rate", type=float, default=2e-5)
    result.add_argument("--minimum-learning-rate", type=float, default=2e-6)
    result.add_argument("--warmup-steps", type=int, default=100)
    result.add_argument("--checkpoint-every-n-steps", type=int, default=0)
    result.add_argument("--num-workers", type=int, default=2)
    result.add_argument("--seed", type=int, default=42)
    result.add_argument("--deterministic", action="store_true")
    result.add_argument("--resume-checkpoint", type=Path)
    result.add_argument("--dry-run", action="store_true")
    return result


def validated_configuration(arguments: argparse.Namespace) -> TrainingConfiguration:
    positive_values = {
        "batch size": arguments.batch_size,
        "validation batch size": arguments.validation_batch_size,
        "gradient accumulation": arguments.accumulate_grad_batches,
        "maximum duration": arguments.max_duration,
        "trained encoder layers": arguments.train_top_encoder_layers,
        "epochs": arguments.max_epochs,
        "learning rate": arguments.learning_rate,
        "minimum learning rate": arguments.minimum_learning_rate,
        "workers": arguments.num_workers,
    }
    invalid = [name for name, value in positive_values.items() if value <= 0]
    if invalid:
        raise SystemExit(f"Values must be positive: {', '.join(invalid)}")
    nonnegative_values = {
        "maximum steps": arguments.max_steps,
        "warmup steps": arguments.warmup_steps,
        "checkpoint interval": arguments.checkpoint_every_n_steps,
    }
    invalid_nonnegative = [
        name for name, value in nonnegative_values.items() if value < 0
    ]
    if invalid_nonnegative:
        raise SystemExit(
            f"Values must be nonnegative: {', '.join(invalid_nonnegative)}"
        )
    for manifest in (arguments.train_manifest, arguments.validation_manifest):
        if not arguments.dry_run and (not manifest.is_file() or manifest.stat().st_size == 0):
            raise SystemExit(f"Missing training manifest: {manifest}")
    if (
        arguments.resume_checkpoint is not None
        and not arguments.dry_run
        and (
            not arguments.resume_checkpoint.is_file()
            or arguments.resume_checkpoint.stat().st_size == 0
        )
    ):
        raise SystemExit(
            f"Missing resume checkpoint: {arguments.resume_checkpoint}"
        )
    return TrainingConfiguration(
        train_manifest=str(arguments.train_manifest.resolve()),
        validation_manifest=str(arguments.validation_manifest.resolve()),
        experiment_root=str(arguments.experiment_root.resolve()),
        precision=arguments.precision,
        batch_size=arguments.batch_size,
        validation_batch_size=arguments.validation_batch_size,
        accumulate_grad_batches=arguments.accumulate_grad_batches,
        max_duration=arguments.max_duration,
        train_top_encoder_layers=arguments.train_top_encoder_layers,
        train_decoder=not arguments.freeze_decoder,
        train_joint=not arguments.freeze_joint,
        freeze_batchnorm=arguments.freeze_batchnorm,
        max_epochs=arguments.max_epochs,
        max_steps=arguments.max_steps,
        learning_rate=arguments.learning_rate,
        minimum_learning_rate=arguments.minimum_learning_rate,
        warmup_steps=arguments.warmup_steps,
        checkpoint_every_n_steps=arguments.checkpoint_every_n_steps,
        num_workers=arguments.num_workers,
        seed=arguments.seed,
        deterministic=arguments.deterministic,
        resume_checkpoint=(
            str(arguments.resume_checkpoint.resolve())
            if arguments.resume_checkpoint is not None
            else None
        ),
    )


def encoder_layer_indices(names: Iterable[str]) -> list[int]:
    return sorted(
        {
            int(match.group(1))
            for name in names
            if (match := ENCODER_LAYER_PATTERN.match(name)) is not None
        }
    )


def parameter_should_train(
    name: str,
    first_trainable_encoder_layer: int,
    *,
    train_decoder: bool = True,
    train_joint: bool = True,
    batchnorm_names: frozenset[str] = frozenset(),
) -> bool:
    if name in batchnorm_names:
        return False
    match = ENCODER_LAYER_PATTERN.match(name)
    if match is not None:
        return int(match.group(1)) >= first_trainable_encoder_layer
    if train_decoder and name.startswith("decoder."):
        return True
    return train_joint and name.startswith("joint.")


def batchnorm_state_names(model: object, torch: object) -> frozenset[str]:
    names = set()
    batchnorm_base = torch.nn.modules.batchnorm._BatchNorm
    for module_name, module in model.named_modules():
        if not isinstance(module, batchnorm_base):
            continue
        prefix = f"{module_name}." if module_name else ""
        names.update(prefix + name for name, _ in module.named_parameters(recurse=False))
        names.update(prefix + name for name, _ in module.named_buffers(recurse=False))
    return frozenset(names)


def freeze_batchnorm_modules(model: object, torch: object) -> None:
    batchnorm_base = torch.nn.modules.batchnorm._BatchNorm
    for module in model.modules():
        if isinstance(module, batchnorm_base):
            module.eval()


def configure_trainable_parameters(
    model: object,
    top_layer_count: int,
    *,
    train_decoder: bool = True,
    train_joint: bool = True,
    freeze_batchnorm: bool = False,
    torch: object | None = None,
) -> tuple[int, int]:
    named_parameters = list(model.named_parameters())
    indices = encoder_layer_indices(name for name, _ in named_parameters)
    if not indices or indices != list(range(indices[-1] + 1)):
        raise RuntimeError("Unexpected Parakeet encoder layer names.")
    if top_layer_count > len(indices):
        raise RuntimeError(
            f"Requested {top_layer_count} trainable encoder layers, model has {len(indices)}."
        )
    first_trainable = len(indices) - top_layer_count
    if freeze_batchnorm and torch is None:
        raise RuntimeError("torch is required when BatchNorm is frozen.")
    batchnorm_names = (
        batchnorm_state_names(model, torch) if freeze_batchnorm else frozenset()
    )
    trainable = 0
    total = 0
    for name, parameter in named_parameters:
        parameter.requires_grad = parameter_should_train(
            name,
            first_trainable,
            train_decoder=train_decoder,
            train_joint=train_joint,
            batchnorm_names=batchnorm_names,
        )
        parameter_count = parameter.numel()
        total += parameter_count
        if parameter.requires_grad:
            trainable += parameter_count
    if trainable == 0:
        raise RuntimeError("The selective fine-tuning recipe selected no parameters.")
    return trainable, total


def delta_checkpoint_path(experiment_root: Path) -> Path:
    return experiment_root / "best-trainable-parameters.delta.pt"


def atomic_trainer_checkpoint(
    trainer: object,
    destination: Path,
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".partial")
    temporary.unlink(missing_ok=True)
    trainer.save_checkpoint(temporary, weights_only=False)
    os.replace(temporary, destination)


def experiment_manager_configuration(experiment_root: str) -> dict[str, object]:
    return {
        "exp_dir": experiment_root,
        "name": "voxol-parakeet-finetune",
        "create_tensorboard_logger": True,
        "create_checkpoint_callback": False,
        "resume_if_exists": False,
        "resume_ignore_no_checkpoint": True,
        "resume_past_end": False,
    }


def capture_trainable_base_state(
    model: object,
    torch: object,
) -> dict[str, object]:
    selected = {
        name: parameter.detach()
        .to(device="cpu", dtype=torch.float32)
        .contiguous()
        .clone()
        for name, parameter in model.named_parameters()
        if parameter.requires_grad
    }
    if not selected:
        raise RuntimeError("The selective fine-tuning recipe selected no parameters.")
    return selected


def true_parameter_delta(
    model: object,
    base_state: dict[str, object],
    torch: object,
) -> dict[str, object]:
    current = dict(model.named_parameters())
    missing = sorted(set(base_state) - set(current))
    if missing:
        raise RuntimeError(f"The model lost a trainable tensor: {missing[0]}")
    return {
        name: (
            current[name]
            .detach()
            .to(device="cpu", dtype=torch.float32)
            .contiguous()
            - base
        )
        for name, base in base_state.items()
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_validation_items(manifest_path: Path) -> list[ValidationItem]:
    items = []
    for line_number, line in enumerate(
        manifest_path.read_text(encoding="utf-8").splitlines(),
        1,
    ):
        if not line.strip():
            continue
        row = json.loads(line)
        audio_value = row.get("audio_filepath", row.get("audio_path"))
        reference = str(row.get("text", "")).strip()
        if not audio_value or not reference:
            raise RuntimeError(
                f"Invalid validation row at {manifest_path}:{line_number}"
            )
        audio_path = Path(str(audio_value))
        if not audio_path.is_absolute():
            audio_path = manifest_path.parent / audio_path
        items.append(
            ValidationItem(
                audio_path=str(audio_path.resolve()),
                reference=reference,
            )
        )
    if not items:
        raise RuntimeError(f"Empty validation manifest: {manifest_path}")
    return items


def transcription_text(result: object) -> str:
    if isinstance(result, str):
        return result.strip()
    text = getattr(result, "text", None)
    if isinstance(text, str):
        return text.strip()
    raise TypeError(f"Unsupported NeMo transcription result: {type(result).__name__}")


def normalized_validation_score(
    references: list[str],
    hypotheses: list[str],
) -> dict[str, float | int | str]:
    if len(references) != len(hypotheses):
        raise RuntimeError(
            "Validation transcription count does not match the manifest."
        )
    word_errors = 0
    reference_words = 0
    for reference, hypothesis in zip(references, hypotheses, strict=True):
        reference_tokens = normalize(reference).split()
        hypothesis_tokens = normalize(hypothesis).split()
        word_errors += edit_distance(reference_tokens, hypothesis_tokens)
        reference_words += len(reference_tokens)
    if reference_words == 0:
        raise RuntimeError("Validation manifest contains no reference words.")
    return {
        "metric": "voxol-asr-v1-micro-wer",
        "microWER": word_errors / reference_words,
        "referenceWords": reference_words,
        "wordErrors": word_errors,
    }


def score_validation_model(
    model: object,
    items: list[ValidationItem],
    batch_size: int,
) -> dict[str, float | int | str]:
    references = []
    hypotheses = []
    for offset in range(0, len(items), batch_size):
        batch = items[offset : offset + batch_size]
        results = model.transcribe(
            audio=[item.audio_path for item in batch],
            batch_size=len(batch),
            verbose=False,
        )
        references.extend(item.reference for item in batch)
        hypotheses.extend(transcription_text(result) for result in results)
    return normalized_validation_score(references, hypotheses)


def main() -> None:
    arguments = parser().parse_args()
    configuration = validated_configuration(arguments)
    if arguments.dry_run:
        print(json.dumps(asdict(configuration), indent=2, sort_keys=True))
        return

    import lightning.pytorch as pl
    from huggingface_hub import hf_hub_download
    from nemo.collections.asr.models import ASRModel
    from nemo.utils.exp_manager import exp_manager
    from omegaconf import OmegaConf
    import torch

    if not torch.cuda.is_available():
        raise SystemExit("A CUDA-capable NVIDIA GPU is required.")
    if (
        configuration.precision == "bf16-mixed"
        and not torch.cuda.is_bf16_supported()
    ):
        raise SystemExit("The selected GPU does not support BF16.")

    pl.seed_everything(configuration.seed, workers=True)

    class KeepFrozenModulesInEvaluationMode(pl.Callback):
        def __init__(
            self,
            trained_top_layer_count: int,
            freeze_batchnorm: bool,
        ) -> None:
            self.trained_top_layer_count = trained_top_layer_count
            self.freeze_batchnorm = freeze_batchnorm

        def enforce(self, pl_module: object) -> None:
            layers = list(pl_module.encoder.layers)
            frozen_count = len(layers) - self.trained_top_layer_count
            if frozen_count < 0:
                raise RuntimeError("The model has fewer encoder layers than requested.")
            for layer in layers[:frozen_count]:
                layer.eval()
            if self.freeze_batchnorm:
                freeze_batchnorm_modules(pl_module, torch)

        def on_train_epoch_start(self, trainer: object, pl_module: object) -> None:
            del trainer
            self.enforce(pl_module)

        def on_train_batch_start(
            self,
            trainer: object,
            pl_module: object,
            batch: object,
            batch_index: int,
        ) -> None:
            del trainer, batch, batch_index
            self.enforce(pl_module)

    experiment_root = Path(configuration.experiment_root)
    experiment_root.mkdir(parents=True, exist_ok=True)
    delta_path = delta_checkpoint_path(experiment_root)
    full_checkpoint_base = os.environ.get("VOXOL_FULL_CHECKPOINT_ROOT")
    full_checkpoint_root = (
        Path(full_checkpoint_base).resolve() / experiment_root.name
        if full_checkpoint_base
        else experiment_root / "checkpoints"
    )
    base_artifact = Path(
        hf_hub_download(
            repo_id=MODEL_ID,
            filename=MODEL_FILENAME,
            revision=MODEL_REVISION,
        )
    )
    base_artifact_sha256 = sha256(base_artifact)

    model = ASRModel.restore_from(
        restore_path=str(base_artifact),
        map_location="cpu",
    )
    for metric in (
        getattr(model, "wer", None),
        getattr(getattr(model, "joint", None), "_wer", None),
    ):
        if metric is not None and hasattr(metric, "log_prediction"):
            metric.log_prediction = False
    trainable, total = configure_trainable_parameters(
        model,
        configuration.train_top_encoder_layers,
        train_decoder=configuration.train_decoder,
        train_joint=configuration.train_joint,
        freeze_batchnorm=configuration.freeze_batchnorm,
        torch=torch,
    )
    trainable_base_state = capture_trainable_base_state(model, torch)
    validation_items = load_validation_items(
        Path(configuration.validation_manifest)
    )

    class SaveBestTrainableDelta(pl.Callback):
        def __init__(
            self,
            output_path: Path,
            items: list[ValidationItem],
            batch_size: int,
        ) -> None:
            self.output_path = output_path
            self.items = items
            self.batch_size = batch_size
            self.best_selection_wer = float("inf")
            if output_path.is_file() and output_path.stat().st_size > 0:
                existing = torch.load(
                    output_path,
                    map_location="cpu",
                    weights_only=True,
                )
                self.best_selection_wer = float(
                    existing["validationWERSelection"]
                )
            self.saved_steps: set[int] = set()

        def payload(
            self,
            trainer: object,
            pl_module: object,
            raw_nemo_wer: float,
            selection_score: dict[str, float | int | str],
        ) -> dict[str, object]:
            return {
                "schemaVersion": 2,
                "artifactType": "voxol-parameter-delta",
                "baseModel": MODEL_ID,
                "baseRevision": MODEL_REVISION,
                "baseArtifactSHA256": base_artifact_sha256,
                "epoch": int(trainer.current_epoch),
                "globalStep": int(trainer.global_step),
                "validationWERInternal": raw_nemo_wer,
                "validationWERSelection": selection_score["microWER"],
                "validationWERSelectionMetric": selection_score["metric"],
                "validationReferenceWords": selection_score["referenceWords"],
                "validationWordErrors": selection_score["wordErrors"],
                "trainedTopEncoderLayers": (
                    configuration.train_top_encoder_layers
                ),
                "trainDecoder": configuration.train_decoder,
                "trainJoint": configuration.train_joint,
                "batchNormFrozen": configuration.freeze_batchnorm,
                "stateDelta": true_parameter_delta(
                    pl_module,
                    trainable_base_state,
                    torch,
                ),
            }

        def save_payload(
            self,
            path: Path,
            payload: dict[str, object],
        ) -> None:
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary_path = path.with_suffix(path.suffix + ".partial")
            torch.save(payload, temporary_path)
            temporary_path.replace(path)

        def on_validation_end(self, trainer: object, pl_module: object) -> None:
            if trainer.sanity_checking:
                return
            step = int(trainer.global_step)
            if step in self.saved_steps:
                return
            metric = trainer.callback_metrics.get("val_wer")
            if metric is None:
                raise RuntimeError("Validation completed without val_wer.")
            raw_nemo_wer = float(metric.detach().float().cpu())
            selection_score = score_validation_model(
                pl_module,
                self.items,
                self.batch_size,
            )
            selection_wer = float(selection_score["microWER"])
            payload = self.payload(
                trainer,
                pl_module,
                raw_nemo_wer,
                selection_score,
            )
            checkpoint_root = experiment_root / "checkpoints"
            self.save_payload(
                checkpoint_root / f"step-{step:06d}.delta.pt",
                payload,
            )
            if configuration.checkpoint_every_n_steps > 0:
                atomic_trainer_checkpoint(
                    trainer,
                    full_checkpoint_root / f"step-{step:06d}.ckpt",
                )
            self.saved_steps.add(step)
            if selection_wer < self.best_selection_wer:
                self.save_payload(self.output_path, payload)
                self.best_selection_wer = selection_wer
                print(
                    "Saved trainable FP32 parameter delta at "
                    f"VoxoL normalized val_wer={selection_wer:.5f} "
                    f"(NeMo callback val_wer={raw_nemo_wer:.5f}): "
                    f"{self.output_path}",
                    flush=True,
                )
            del payload
            gc.collect()

    validation_interval_batches = (
        configuration.checkpoint_every_n_steps
        * configuration.accumulate_grad_batches
        if configuration.checkpoint_every_n_steps > 0
        else None
    )
    trainer = pl.Trainer(
        accelerator="gpu",
        devices=1,
        strategy="auto",
        precision=configuration.precision,
        max_epochs=configuration.max_epochs,
        max_steps=configuration.max_steps or -1,
        accumulate_grad_batches=configuration.accumulate_grad_batches,
        gradient_clip_val=1.0,
        sync_batchnorm=False,
        num_sanity_val_steps=0,
        check_val_every_n_epoch=(
            None if validation_interval_batches is not None else 1
        ),
        val_check_interval=validation_interval_batches,
        log_every_n_steps=10,
        enable_checkpointing=False,
        logger=False,
        benchmark=False,
        deterministic=configuration.deterministic,
        callbacks=[
            KeepFrozenModulesInEvaluationMode(
                configuration.train_top_encoder_layers,
                configuration.freeze_batchnorm,
            ),
            SaveBestTrainableDelta(
                delta_path,
                validation_items,
                configuration.validation_batch_size,
            ),
        ],
    )
    model.set_trainer(trainer)
    exp_manager(
        trainer,
        OmegaConf.create(
            experiment_manager_configuration(str(experiment_root))
        ),
    )

    summary = {
        **asdict(configuration),
        "model": MODEL_ID,
        "modelRevision": MODEL_REVISION,
        "baseArtifact": str(base_artifact),
        "baseArtifactSHA256": base_artifact_sha256,
        "cudaDevice": torch.cuda.get_device_name(0),
        "trainableParameters": trainable,
        "totalParameters": total,
        "trainableFraction": trainable / total,
        "fullCheckpointRoot": str(full_checkpoint_root),
    }
    (experiment_root / "training-configuration.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, indent=2, sort_keys=True), flush=True)

    model.setup_training_data(
        OmegaConf.create(
            {
                "manifest_filepath": configuration.train_manifest,
                "sample_rate": 16_000,
                "batch_size": configuration.batch_size,
                "shuffle": True,
                "num_workers": configuration.num_workers,
                "pin_memory": True,
                "max_duration": configuration.max_duration,
                "min_duration": 0.1,
                "is_tarred": False,
                "tarred_audio_filepaths": None,
                "shuffle_n": 2_048,
                "bucketing_strategy": "fully_randomized",
                "bucketing_batch_size": None,
            }
        )
    )
    model.setup_multiple_validation_data(
        OmegaConf.create(
            {
                "manifest_filepath": configuration.validation_manifest,
                "sample_rate": 16_000,
                "batch_size": configuration.validation_batch_size,
                "shuffle": False,
                "use_start_end_token": False,
                "num_workers": configuration.num_workers,
                "pin_memory": True,
            }
        )
    )
    model.setup_optimization(
        OmegaConf.create(
            {
                "name": "adamw",
                "lr": configuration.learning_rate,
                "betas": [0.9, 0.98],
                "weight_decay": 1e-3,
                "sched": {
                    "name": "CosineAnnealing",
                    "warmup_steps": configuration.warmup_steps,
                    "warmup_ratio": None,
                    "min_lr": configuration.minimum_learning_rate,
                },
            }
        )
    )
    model.spec_augment = ASRModel.from_config_dict(
        OmegaConf.create(
            {
                "_target_": "nemo.collections.asr.modules.SpectrogramAugmentation",
                "freq_masks": 2,
                "time_masks": 10,
                "freq_width": 27,
                "time_width": 0.05,
            }
        )
    )
    trainer.fit(model, ckpt_path=configuration.resume_checkpoint)
    if not delta_path.is_file() or delta_path.stat().st_size == 0:
        raise RuntimeError("Training completed without a trainable delta checkpoint.")


if __name__ == "__main__":
    main()
