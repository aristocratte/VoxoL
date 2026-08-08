#!/usr/bin/env bash
#
# run-parakeet-lr-sweep.sh
# ---------------------------------------------------------------------------
# Probe several learning rates against an already prepared Wispr work root.
#
# This runs ON THE GPU POD, after VoxoL_GPU_Train.sh has completed at least one
# run: it reuses that run's extracted teacher corpus, mixed training manifest
# and FLEURS benchmark instead of preparing them again. Each probe trains a
# short budget and is scored on the Wispr held-out split and FLEURS only.
#
# Usage, from anywhere on the pod:
#   ./run-parakeet-lr-sweep.sh [--work-root DIR] [--learning-rates LIST]
#                              [--max-steps N] [--batch-size N]
#
# Environment overrides mirror VoxoL_GPU_Train.sh:
#   VOXOL_WORK_ROOT, VOXOL_RUNTIME_ROOT
# ---------------------------------------------------------------------------
set -Eeuo pipefail

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

WORK_ROOT="${VOXOL_WORK_ROOT:-}"
LEARNING_RATES="3e-6,1e-5,3e-5"
MAX_STEPS=200
BATCH_SIZE=2
ACCUMULATE=8

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-root)
      [[ $# -ge 2 ]] || die "--work-root requires a value."
      WORK_ROOT="$2"
      shift 2
      ;;
    --learning-rates)
      [[ $# -ge 2 ]] || die "--learning-rates requires a value."
      LEARNING_RATES="$2"
      shift 2
      ;;
    --max-steps)
      [[ $# -ge 2 ]] || die "--max-steps requires a value."
      MAX_STEPS="$2"
      shift 2
      ;;
    --batch-size)
      [[ $# -ge 2 ]] || die "--batch-size requires a value."
      BATCH_SIZE="$2"
      shift 2
      ;;
    --accumulate-grad-batches)
      [[ $# -ge 2 ]] || die "--accumulate-grad-batches requires a value."
      ACCUMULATE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '3,18p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ -z "$WORK_ROOT" ]]; then
  if [[ -d /workspace && -w /workspace ]]; then
    WORK_ROOT="/workspace/voxol-parakeet"
  else
    [[ -n "${HOME:-}" ]] || die "HOME is unset; pass --work-root."
    WORK_ROOT="$HOME/voxol-parakeet"
  fi
fi
[[ -d "$WORK_ROOT" ]] || die "Work root does not exist: $WORK_ROOT"

if [[ -n "${VOXOL_RUNTIME_ROOT:-}" ]]; then
  RUNTIME_ROOT="$VOXOL_RUNTIME_ROOT"
elif [[ -d /workspace && -w /workspace ]]; then
  RUNTIME_ROOT="/workspace/voxol-runtime-v7"
else
  RUNTIME_ROOT="$WORK_ROOT/runtime"
fi

SOURCE_ROOT="$RUNTIME_ROOT/voxol-sources"
NEMO_ROOT="$RUNTIME_ROOT/NeMo"
PYTHON="$RUNTIME_ROOT/venv/bin/python"

[[ -d "$SOURCE_ROOT" ]] || die "No deployed sources at $SOURCE_ROOT; run VoxoL_GPU_Train.sh first."
[[ -x "$PYTHON" ]] || die "No prepared virtualenv at $PYTHON; run VoxoL_GPU_Train.sh first."

SWEEP_SCRIPT="$SOURCE_ROOT/Tools/training/run_parakeet_lr_sweep.py"
[[ -f "$SWEEP_SCRIPT" ]] || die "Sweep driver missing: $SWEEP_SCRIPT"

export PYTHONPATH="$SOURCE_ROOT:$NEMO_ROOT${PYTHONPATH:+:$PYTHONPATH}"

printf 'Work root:   %s\n' "$WORK_ROOT"
printf 'Sources:     %s\n' "$SOURCE_ROOT"
printf 'Rates:       %s\n' "$LEARNING_RATES"
printf 'Probe steps: %s (batch %s x %s accumulation)\n\n' \
  "$MAX_STEPS" "$BATCH_SIZE" "$ACCUMULATE"

exec "$PYTHON" "$SWEEP_SCRIPT" \
  --source-root "$SOURCE_ROOT" \
  --work-root "$WORK_ROOT" \
  --learning-rates "$LEARNING_RATES" \
  --max-steps "$MAX_STEPS" \
  --batch-size "$BATCH_SIZE" \
  --accumulate-grad-batches "$ACCUMULATE"
