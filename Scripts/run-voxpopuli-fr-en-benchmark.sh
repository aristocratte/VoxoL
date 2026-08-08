#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
suite_root="${VOXOL_BENCHMARK_SUITE_ROOT:-/Volumes/0_Oueillez/VoxoL-Benchmarks-v2}"
benchmark_root="$suite_root/benchmarks/voxpopuli-fr-en-test"
source_root="$suite_root/sources/voxpopuli-fr-en"
run_id="${VOXOL_VOXPOPULI_RUN_ID:-voxpopuli-direct-nemo-$(date -u +%Y%m%dT%H%M%SZ)}"
run_root="$suite_root/runs/$run_id"
model_root="${VOXOL_ASR_MODEL_ROOT:-$repo_root/Artifacts/Training/2026-08-01-wispr-replay-v5/coreml-candidates/nemo-direct-waveform-int8}"
binary="$repo_root/.build/arm64-apple-macosx/release/voxol-asr-benchmark"

[[ -d /Volumes/0_Oueillez ]] || {
  printf 'The 0_Oueillez SSD is not mounted.\n' >&2
  exit 1
}
free_kib="$(df -k /Volumes/0_Oueillez | awk 'NR == 2 {print $4}')"
minimum_free_kib=$((25 * 1024 * 1024))
[[ "$free_kib" =~ ^[0-9]+$ ]] && (( free_kib >= minimum_free_kib )) || {
  printf 'At least 25 GiB free is required before preparing VoxPopuli.\n' >&2
  exit 1
}
[[ -d "$model_root" && -x "$binary" ]] || {
  printf 'The direct-NeMo model or benchmark binary is missing.\n' >&2
  exit 1
}
mkdir -p "$benchmark_root" "$source_root" "$run_root"
cd "$repo_root"

python3 Scripts/prepare-voxpopuli-fr-en-benchmark.py \
  --cache-root "$source_root" \
  --output-root "$benchmark_root"
python3 Tools/training/freeze_asr_manifest.py \
  --input "$benchmark_root/manifest-unfrozen.json" \
  --output "$benchmark_root/manifest-frozen.json" \
  --timestamp '2026-08-03T00:00:00Z'

"$binary" validate \
  --manifest "$benchmark_root/manifest-frozen.json" \
  --audio-root "$benchmark_root/audio" \
  --require-frozen
"$binary" run-parakeet \
  --manifest "$benchmark_root/manifest-frozen.json" \
  --audio-root "$benchmark_root/audio" \
  --model-root "$model_root" \
  --compute-units all \
  --output "$run_root/predictions.jsonl" \
  --resume
"$binary" score \
  --manifest "$benchmark_root/manifest-frozen.json" \
  --predictions "$run_root/predictions.jsonl" \
  --output "$run_root/report.json"

printf 'VoxPopuli FR/EN benchmark complete: %s\n' "$run_root/report.json"
