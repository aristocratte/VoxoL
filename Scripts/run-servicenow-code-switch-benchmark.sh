#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
benchmark_root="${VOXOL_SERVICENOW_BENCHMARK_ROOT:-$HOME/Library/Application Support/VoxoL/Benchmarks/ServiceNowCodeSwitch}"
source_root="$benchmark_root/source-cache"
dataset_root="$benchmark_root/dataset"
run_id="${VOXOL_SERVICENOW_RUN_ID:-voxol-$(date -u +%Y%m%dT%H%M%SZ)}"
run_root="$benchmark_root/runs/$run_id"
model_root="${VOXOL_ASR_MODEL_ROOT:-$HOME/Library/Application Support/VoxoL/Models/asr/7c35754d166cca382ad1e53e68b01e7c575f3a1d}"
binary="$repo_root/.build/arm64-apple-macosx/release/voxol-asr-benchmark"

if [[ ! -x "$binary" ]]; then
  swift build --package-path "$repo_root" -c release --product voxol-asr-benchmark
fi
if [[ ! -d "$model_root" ]]; then
  printf 'The VoxoL ASR model is missing: %s\n' "$model_root" >&2
  exit 1
fi

mkdir -p "$source_root" "$dataset_root" "$run_root"
cd "$repo_root"

python3 Scripts/prepare-servicenow-code-switch-benchmark.py \
  --cache-root "$source_root" \
  --output-root "$dataset_root"
python3 Tools/training/freeze_asr_manifest.py \
  --input "$dataset_root/manifest-unfrozen.json" \
  --output "$dataset_root/manifest-frozen.json" \
  --timestamp '2026-07-21T21:37:30Z'

"$binary" validate \
  --manifest "$dataset_root/manifest-frozen.json" \
  --audio-root "$dataset_root/audio" \
  --require-frozen
"$binary" run-parakeet \
  --manifest "$dataset_root/manifest-frozen.json" \
  --audio-root "$dataset_root/audio" \
  --model-root "$model_root" \
  --compute-units all \
  --output "$run_root/predictions.jsonl" \
  --resume
"$binary" score \
  --manifest "$dataset_root/manifest-frozen.json" \
  --predictions "$run_root/predictions.jsonl" \
  --output "$run_root/voxol-report.json"
python3 Scripts/score-servicenow-code-switch.py \
  --manifest "$dataset_root/manifest-frozen.json" \
  --metadata "$dataset_root/codeswitch-metadata.jsonl" \
  --predictions "$run_root/predictions.jsonl" \
  --output "$run_root/servicenow-protocol-report.json" \
  --records-output "$run_root/servicenow-records.jsonl" \
  --markdown-output "$run_root/README.md"

printf 'ServiceNow FR/EN code-switch benchmark complete: %s\n' "$run_root/README.md"
