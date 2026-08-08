#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
campaign_root="/Volumes/0_Oueillez/VoxoL-Data-Campaign-v2"
snapshot="${VOXOL_MASS_SNAPSHOT:-20260803}"
prepared_root="$campaign_root/prepared/qwen-mass-v8-$snapshot"
work_root="$campaign_root/prepared/qwen-mass-v8-training-$snapshot"
gate="$prepared_root/qwen-mass-gate.json"
dataset="$prepared_root/mlx-data"
references="$prepared_root/source/evaluation-reference.jsonl"
ami_report="/Volumes/0_Oueillez/VoxoL-Benchmarks-v2/runs/ami-direct-nemo-$snapshot/report.json"
model="$HOME/Library/Application Support/VoxoL/Models/polisher/2fc06364715b967f1860aea9cf38778875588b17"
baseline_adapter="$HOME/Library/Application Support/VoxoL/Models/polisher/voxol-adapter"
promotion_result="$work_root/promotion-result.json"
selection_report="$work_root/checkpoint-selection.json"
package="$campaign_root/prepared/VoxoL-Qwen-v8-candidate-$snapshot.zip"

for required in \
  "$gate" \
  "$dataset/train.jsonl" \
  "$dataset/valid.jsonl" \
  "$dataset/test.jsonl" \
  "$dataset/summary.json" \
  "$references" \
  "$ami_report" \
  "$model/model.safetensors" \
  "$baseline_adapter/adapters.safetensors" \
  "$baseline_adapter/adapter_config.json"; do
  [[ -s "$required" ]] || {
    printf 'Missing Qwen v8 prerequisite: %s\n' "$required" >&2
    exit 1
  }
done
if pgrep -f '/Users/aris/Documents/wispr/wispr-transcribe.sh' >/dev/null 2>&1; then
  printf 'Wispr transcription is still active; Qwen training must wait.\n' >&2
  exit 1
fi
if [[ -s "$promotion_result" ]]; then
  printf 'Qwen v8 experiment already completed: %s\n' "$promotion_result"
  jq . "$promotion_result"
  exit 0
fi
if ! jq -e '.promotion_training_eligible == true' "$gate" >/dev/null; then
  mkdir -p "$work_root"
  python3 - "$gate" "$promotion_result" <<'PY'
import json
from pathlib import Path
import sys

gate = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(sys.argv[2]).write_text(
    json.dumps(
        {
            "gate": gate,
            "reason": "mass-corpus-thresholds-not-met",
            "schemaVersion": "voxol-qwen-v8-promotion-v1",
            "status": "not-trained",
        },
        indent=2,
        sort_keys=True,
    ) + "\n",
    encoding="utf-8",
)
PY
  printf 'Qwen v8 training skipped because the frozen corpus gate did not pass.\n'
  exit 0
fi

mkdir -p "$work_root"
caffeinate -dimsu python3 "$repo_root/Tools/training/run_qwen_wispr_finetune.py" \
  --model "$model" \
  --baseline-adapter "$baseline_adapter" \
  --resume-adapter-file "$baseline_adapter/adapters.safetensors" \
  --prepared-dataset "$dataset" \
  --evaluation-references "$references" \
  --work-root "$work_root" \
  --iterations 400 \
  --learning-rate 5e-6 \
  --memory-gb 6 \
  --evaluation-limit 256 \
  --lora-rank 8 \
  --train-top-layers 8

run_root="$(python3 - "$work_root" <<'PY'
import json
from pathlib import Path
import sys

statuses = []
for path in Path(sys.argv[1]).glob("runs/*/status.json"):
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("status") == "complete":
        statuses.append((str(value.get("completedAt", "")), path.parent))
if not statuses:
    raise SystemExit("No completed Qwen v8 run found")
print(max(statuses)[1])
PY
)"

caffeinate -dimsu python3 "$repo_root/Tools/training/select_qwen_checkpoint.py" \
  --run-root "$run_root" \
  --model "$model" \
  --baseline-adapter "$baseline_adapter" \
  --dataset "$dataset" \
  --references "$references" \
  --limit 256 \
  --test-output "$promotion_result" \
  --output "$selection_report"

rm -f "$package"
ditto -c -k --norsrc --keepParent "$work_root" "$package"
printf 'Qwen v8 candidate package: %s\n' "$package"
shasum -a 256 "$package"
jq . "$promotion_result"
