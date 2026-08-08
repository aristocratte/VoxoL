#!/usr/bin/env bash
set -euo pipefail

expected_nemo_revision="2381f42f6979449b5b99538f8f80135831009b51"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
training_root="${VOXOL_ASR_TRAINING_ROOT:-$HOME/Library/Caches/VoxoL/Training/parakeet-fleurs-fr-en}"
dataset_root="$training_root/dataset"
nemo_root="${VOXOL_NEMO_ROOT:-}"
python_command="${VOXOL_TRAINING_PYTHON:-python3}"
experiment_root="${VOXOL_ASR_EXPERIMENT_ROOT:-$training_root/experiments}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Parakeet fine-tuning requires a Linux host with an NVIDIA GPU." >&2
  exit 1
fi
if [[ -z "$nemo_root" || ! -d "$nemo_root/.git" ]]; then
  echo "Set VOXOL_NEMO_ROOT to a checkout of NVIDIA NeMo." >&2
  exit 1
fi

actual_nemo_revision="$(git -C "$nemo_root" rev-parse HEAD)"
if [[ "$actual_nemo_revision" != "$expected_nemo_revision" ]]; then
  echo "NeMo revision mismatch." >&2
  echo "Expected: $expected_nemo_revision" >&2
  echo "Actual:   $actual_nemo_revision" >&2
  exit 1
fi

train_manifest="$dataset_root/train.jsonl"
validation_manifest="$dataset_root/validation.jsonl"
for manifest in "$train_manifest" "$validation_manifest"; do
  if [[ ! -s "$manifest" ]]; then
    echo "Missing training manifest: $manifest" >&2
    exit 1
  fi
done

"$python_command" - <<'PY'
import torch

if not torch.cuda.is_available():
    raise SystemExit("PyTorch cannot access an NVIDIA CUDA GPU.")
print(f"CUDA device: {torch.cuda.get_device_name(0)}")
PY

mkdir -p "$experiment_root"
profile=$(
  "$python_command" - <<'PY'
import torch

device = torch.cuda.get_device_properties(0)
memory_gib = device.total_memory / (1024 ** 3)
if memory_gib < 14:
    raise SystemExit(f"The CUDA GPU has only {memory_gib:.1f} GiB; 14 GiB is required.")
if memory_gib < 20:
    values = ("16-mixed", 1, 1, 16, 12, 6)
elif memory_gib < 38:
    precision = "bf16-mixed" if torch.cuda.is_bf16_supported() else "16-mixed"
    values = (precision, 2, 2, 8, 18, 8)
else:
    precision = "bf16-mixed" if torch.cuda.is_bf16_supported() else "16-mixed"
    values = (precision, 4, 4, 4, 30, 8)
print("\t".join(map(str, values)))
PY
)
IFS=$'\t' read -r \
  precision \
  batch_size \
  validation_batch_size \
  accumulate_grad_batches \
  max_duration \
  train_top_encoder_layers <<<"$profile"

PYTHONPATH="$nemo_root${PYTHONPATH:+:$PYTHONPATH}" \
  "$python_command" "$repo_root/Tools/training/run_voxol_nemo_finetune.py" \
  --train-manifest "$train_manifest" \
  --validation-manifest "$validation_manifest" \
  --experiment-root "$experiment_root" \
  --precision "$precision" \
  --batch-size "$batch_size" \
  --validation-batch-size "$validation_batch_size" \
  --accumulate-grad-batches "$accumulate_grad_batches" \
  --max-duration "$max_duration" \
  --train-top-encoder-layers "$train_top_encoder_layers" \
  --max-epochs 5 \
  --learning-rate 2e-5 \
  --minimum-learning-rate 2e-6 \
  --warmup-steps 100 \
  --num-workers 2

echo "Fine-tuning complete. Experiments: $experiment_root"
