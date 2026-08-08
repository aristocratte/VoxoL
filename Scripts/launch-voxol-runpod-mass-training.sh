#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  printf 'Usage: %s RUNPOD_HOST RUNPOD_PORT [RUNPOD_USER]\n' "$0" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
campaign_root="/Volumes/0_Oueillez/VoxoL-Data-Campaign-v2"
ready="$campaign_root/runpod-ready/runpod-ready.json"
[[ -s "$ready" ]] || {
  printf 'RunPod handoff is not ready: %s\n' "$ready" >&2
  exit 1
}

teacher_archive="$(jq -er '.teacher_archive' "$ready")"
expected_sha256="$(jq -er '.teacher_archive_sha256' "$ready")"
gpu_bundle="$(jq -er '.gpu_bundle' "$ready")"
expected_gpu_bundle_sha256="$(jq -er '.gpu_bundle_sha256' "$ready")"
actual_sha256="$(shasum -a 256 "$teacher_archive" | awk '{print $1}')"
[[ "$actual_sha256" == "$expected_sha256" ]] || {
  printf 'Teacher archive SHA-256 mismatch.\n' >&2
  exit 1
}
actual_gpu_bundle_sha256="$(shasum -a 256 "$gpu_bundle" | awk '{print $1}')"
[[ "$actual_gpu_bundle_sha256" == "$expected_gpu_bundle_sha256" ]] || {
  printf 'GPU bundle SHA-256 mismatch.\n' >&2
  exit 1
}

export VOXOL_TEACHER_DATASET="$teacher_archive"
export VOXOL_GPU_LAUNCHER="$gpu_bundle"
export VOXOL_REMOTE_WORK="${VOXOL_REMOTE_WORK:-/workspace/voxol-wispr-mass-v3}"
export VOXOL_LOCAL_RESULTS="${VOXOL_LOCAL_RESULTS:-$repo_root/Artifacts/Training/voxol-wispr-mass-v3}"
export VOXOL_MAX_HOURS="${VOXOL_MAX_HOURS:-8}"
export VOXOL_MAX_BUDGET_USD="${VOXOL_MAX_BUDGET_USD:-15}"

exec "$repo_root/Scripts/launch-voxol-runpod-training.sh" "$@"
