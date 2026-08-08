#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
items_per_language="${VOXOL_PUBLIC_ASR_ITEMS_PER_LANGUAGE:-50}"
benchmark_base="${VOXOL_BENCHMARK_ROOT:-$HOME/Library/Caches/VoxoL/Benchmarks}"
cache_root="$benchmark_base/fleurs-source"
benchmark_root="$benchmark_base/fleurs-lite-$items_per_language"
audio_root="$benchmark_root/audio"
source_manifest="$benchmark_root/manifest-unfrozen.json"
frozen_manifest="$benchmark_root/manifest-frozen.json"
asr_revision="$(jq -r '.models[] | select(.role == "asr") | .revision' \
  "$repo_root/Models/manifests/runtime-models.json")"
model_root="$HOME/Library/Application Support/VoxoL/Models/asr/$asr_revision"
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
predictions="$benchmark_root/parakeet-$run_stamp.jsonl"
report="$benchmark_root/report-$run_stamp.json"

cd "$repo_root"
python3 Scripts/prepare-fleurs-lite-benchmark.py \
  --cache-root "$cache_root" \
  --output-root "$benchmark_root" \
  --items-per-language "$items_per_language"

if [[ ! -f "$frozen_manifest" ]]; then
  swift run -c release voxol-asr-benchmark freeze \
    --manifest "$source_manifest" \
    --audio-root "$audio_root" \
    --output "$frozen_manifest" \
    --timestamp "2026-07-26T00:00:00Z"
fi

swift run -c release voxol-asr-benchmark validate \
  --manifest "$frozen_manifest" \
  --audio-root "$audio_root" \
  --require-frozen

if [[ ! -d "$model_root" ]]; then
  echo "Parakeet is not installed at: $model_root" >&2
  echo "Download it from VoxoL, then run this script again." >&2
  exit 1
fi

swift run -c release voxol-asr-benchmark run-parakeet \
  --manifest "$frozen_manifest" \
  --audio-root "$audio_root" \
  --model-root "$model_root" \
  --compute-units all \
  --output "$predictions"

swift run -c release voxol-asr-benchmark score \
  --manifest "$frozen_manifest" \
  --predictions "$predictions" \
  --output "$report"

echo "Public ASR lite benchmark complete: $report"
