#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
training_root="${VOXOL_ASR_TRAINING_ROOT:-$HOME/Library/Caches/VoxoL/Training/parakeet-fleurs-fr-en}"
cache_root="$training_root/source"
dataset_root="$training_root/dataset"

cd "$repo_root"
python3 Scripts/prepare-parakeet-fleurs-finetune.py \
  --cache-root "$cache_root" \
  --output-root "$dataset_root" \
  "$@"
