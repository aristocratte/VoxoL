#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
benchmark_base="${VOXOL_BENCHMARK_ROOT:-$HOME/Library/Caches/VoxoL/Benchmarks}"
cache_root="$benchmark_base/mediaspeech-fr-source"
benchmark_root="$benchmark_base/mediaspeech-fr"
audio_root="$benchmark_root/audio"
source_manifest="$benchmark_root/manifest-unfrozen.json"
frozen_manifest="$benchmark_root/manifest-frozen.json"
coreml_predictions="$benchmark_root/parakeet-coreml.jsonl"
diagnostic_root="$benchmark_root/source-coreml-diagnostic"
venv_root="$benchmark_base/parakeet-source-venv"
transformers_revision="b6d5084fb4a5dd11e44005a5fa009e7943271090"
asr_repository="$(jq -r '.models[] | select(.role == "asr") | .repository' \
  "$repo_root/Models/manifests/runtime-models.json")"
asr_revision="$(jq -r '.models[] | select(.role == "asr") | .revision' \
  "$repo_root/Models/manifests/runtime-models.json")"
model_root="$HOME/Library/Application Support/VoxoL/Models/asr/$asr_revision"

cd "$repo_root"
python3 Scripts/prepare-mediaspeech-fr-benchmark.py \
  --cache-root "$cache_root" \
  --output-root "$benchmark_root"

if [[ ! -f "$frozen_manifest" ]]; then
  swift run -c release voxol-asr-benchmark freeze \
    --manifest "$source_manifest" \
    --audio-root "$audio_root" \
    --output "$frozen_manifest" \
    --timestamp "2026-07-26T00:00:00Z"
fi

if [[ ! -f "$coreml_predictions" ]]; then
  swift run -c release voxol-asr-benchmark run-parakeet \
    --manifest "$frozen_manifest" \
    --audio-root "$audio_root" \
    --model-root "$model_root" \
    --compute-units all \
    --output "$coreml_predictions"
fi

if [[ ! -x "$venv_root/bin/python" ]]; then
  python3 -m venv --system-site-packages "$venv_root"
fi
if ! "$venv_root/bin/python" -c \
  'from transformers import AutoModelForTDT; import librosa, soundfile' >/dev/null 2>&1; then
  "$venv_root/bin/pip" install \
    "soundfile==0.13.1" \
    "safetensors>=0.8.0" \
    "librosa==0.11.0" \
    "git+https://github.com/huggingface/transformers.git@$transformers_revision"
fi

"$venv_root/bin/python" Tools/benchmarks/run_mediaspeech_source_diagnostic.py \
  --manifest "$frozen_manifest" \
  --coreml-predictions "$coreml_predictions" \
  --audio-root "$audio_root" \
  --model "$asr_repository" \
  --revision "$asr_revision" \
  --transformers-revision "$transformers_revision" \
  --cache-dir "$repo_root/.build/huggingface-cache/hub" \
  --output-root "$diagnostic_root"
