#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
benchmark_base="${VOXOL_BENCHMARK_ROOT:-$HOME/Library/Caches/VoxoL/Benchmarks}"
benchmark_root="$benchmark_base/mediaspeech-fr"
audio_root="$benchmark_root/audio"
diagnostic_report="$benchmark_root/source-coreml-diagnostic/report.json"
output_root="$benchmark_root/recovered-stage-parity-v3"
venv_root="$benchmark_base/parakeet-source-venv"
source_cache="$repo_root/.build/huggingface-cache/hub"
asr_repository="$(jq -r '.models[] | select(.role == "asr") | .repository' \
  "$repo_root/Models/manifests/runtime-models.json")"
asr_revision="$(jq -r '.models[] | select(.role == "asr") | .revision' \
  "$repo_root/Models/manifests/runtime-models.json")"
model_root="$HOME/Library/Application Support/VoxoL/Models/asr/$asr_revision"

if [[ ! -f "$diagnostic_report" ]]; then
  echo "Run Scripts/run-mediaspeech-source-diagnostic.sh first." >&2
  exit 1
fi
if [[ ! -x "$venv_root/bin/python" ]]; then
  echo "The pinned Parakeet source environment is missing: $venv_root" >&2
  exit 1
fi
if [[ ! -d "$model_root" ]]; then
  echo "Parakeet is not installed at: $model_root" >&2
  exit 1
fi

cd "$repo_root"
swift build -c release --product voxol-parakeet-parity
binary_root="$(swift build -c release --show-bin-path)"
mkdir -p "$output_root"

while IFS= read -r item; do
  item_id="$(jq -r '.id' <<<"$item")"
  relative_audio_path="$(jq -r '.audioPath' <<<"$item")"
  audio_path="$audio_root/$relative_audio_path"
  item_root="$output_root/$item_id"
  source_root="$item_root/source"

  if [[ ! -f "$source_root/snapshot.json" ]]; then
    "$venv_root/bin/python" Tools/parity/export_parakeet_reference.py \
      --model "$asr_repository" \
      --revision "$asr_revision" \
      --cache-dir "$source_cache" \
      --audio "$audio_path" \
      --output "$source_root"
  fi

  for feature_mode in production source; do
    coreml_root="$item_root/coreml-$feature_mode"
    if [[ ! -f "$coreml_root/snapshot.json" ]]; then
      command=(
        "$binary_root/voxol-parakeet-parity"
        --model-root "$model_root"
        --compute-units all
        --output "$coreml_root"
      )
      if [[ "$feature_mode" == source ]]; then
        command+=(--source-compatible-features)
      fi
      command+=("$audio_path")
      "${command[@]}"
    fi

    set +e
    "$venv_root/bin/python" Tools/parity/compare_parakeet_snapshots.py \
      --source "$source_root" \
      --coreml "$coreml_root" \
      --output "$item_root/report-$feature_mode.json" \
      --quiet
    comparison_code=$?
    set -e
    if [[ $comparison_code -ne 0 && $comparison_code -ne 2 ]]; then
      exit "$comparison_code"
    fi
  done
  echo "Parity complete: $item_id"
done < <(
  jq -c '
    .items[]
    | select(.coreMLScore.empty == true and .sourceScore.empty == false)
    | {id, audioPath}
  ' "$diagnostic_report"
)

"$venv_root/bin/python" Tools/parity/summarize_recovered_empty_parity.py \
  --diagnostic-report "$diagnostic_report" \
  --parity-root "$output_root" \
  --output "$output_root/report.json"
