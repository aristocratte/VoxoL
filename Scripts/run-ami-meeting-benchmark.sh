#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
suite_root="${VOXOL_BENCHMARK_SUITE_ROOT:-/Volumes/0_Oueillez/VoxoL-Benchmarks-v2}"
benchmark_root="$suite_root/benchmarks/ami-meeting-eval"
source_root="$suite_root/sources/ami"
run_id="${VOXOL_AMI_RUN_ID:-ami-direct-nemo-$(date -u +%Y%m%dT%H%M%SZ)}"
run_root="$suite_root/runs/$run_id"
model_root="${VOXOL_ASR_MODEL_ROOT:-$repo_root/Artifacts/Training/2026-08-01-wispr-replay-v5/coreml-candidates/nemo-direct-waveform-int8}"
binary="$repo_root/.build/arm64-apple-macosx/release/voxol-asr-benchmark"

[[ -d /Volumes/0_Oueillez ]] || {
  printf 'The 0_Oueillez SSD is not mounted.\n' >&2
  exit 1
}
[[ -d "$model_root" ]] || {
  printf 'ASR model root is missing: %s\n' "$model_root" >&2
  exit 1
}
mkdir -p "$benchmark_root" "$source_root" "$run_root"
cd "$repo_root"

python3 Scripts/prepare-ami-meeting-benchmark.py \
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

printf 'AMI meeting benchmark complete: %s\n' "$run_root/report.json"
