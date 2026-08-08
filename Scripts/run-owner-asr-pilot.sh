#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pilot_root="$HOME/Library/Application Support/VoxoL/Benchmarks/owner-pilot-v1"
audio_root="$pilot_root/audio"
frozen_manifest="$pilot_root/manifest-frozen.json"
source_manifest="$repo_root/Tests/Performance/Fixtures/asr-owner-pilot-v1.json"
asr_revision="$(jq -r '.models[] | select(.role == "asr") | .revision' \
  "$repo_root/Models/manifests/runtime-models.json")"
model_root="$HOME/Library/Application Support/VoxoL/Models/asr/$asr_revision"
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
predictions="$pilot_root/parakeet-$run_stamp.jsonl"
report="$pilot_root/report-$run_stamp.json"

mkdir -p "$audio_root"
cd "$repo_root"

swift run -c release voxol-asr-benchmark capture \
  --manifest "$source_manifest" \
  --audio-root "$audio_root"

if [[ ! -f "$frozen_manifest" ]]; then
  swift run -c release voxol-asr-benchmark freeze \
    --manifest "$source_manifest" \
    --audio-root "$audio_root" \
    --output "$frozen_manifest"
fi

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

echo "Pilot complete: $report"
