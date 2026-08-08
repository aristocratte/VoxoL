#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DATASET_ROOT="${VOXOL_WISPR_DATASET_ROOT:-/Volumes/0_Oueillez/wispr-data/transcripts/dataset}"
PREPARED_ROOT="${VOXOL_WISPR_PREPARED_ROOT:-/Volumes/0_Oueillez/wispr-data/prepared/parakeet-wispr-v1}"
INPUT_MANIFEST="${VOXOL_WISPR_MANIFEST:-$DATASET_ROOT/all-manifest.jsonl}"
REVIEW_ROOT="${VOXOL_WISPR_REVIEW_ROOT:-/Volumes/0_Oueillez/wispr-data/review/teacher-audit-400}"
PORT="${VOXOL_WISPR_REVIEW_PORT:-8765}"

[[ -s "$INPUT_MANIFEST" ]] || {
  printf '%s\n' "Missing Wispr manifest: $INPUT_MANIFEST" >&2
  exit 1
}
[[ -d "$PREPARED_ROOT" ]] || {
  printf '%s\n' "Missing prepared teacher dataset: $PREPARED_ROOT" >&2
  exit 1
}

cd "$REPOSITORY_ROOT"
python3 Tools/training/prepare_wispr_teacher_review.py \
  --input-manifest "$INPUT_MANIFEST" \
  --dataset-root "$DATASET_ROOT" \
  --prepared-root "$PREPARED_ROOT" \
  --output-root "$REVIEW_ROOT" \
  --count 400

exec python3 Tools/training/serve_wispr_teacher_review.py \
  --review-root "$REVIEW_ROOT" \
  --port "$PORT"
