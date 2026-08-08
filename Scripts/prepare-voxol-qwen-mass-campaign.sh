#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
campaign_root="/Volumes/0_Oueillez/VoxoL-Data-Campaign-v2"
dataset_root="$campaign_root/corpus/transcripts/dataset"
snapshot="${VOXOL_MASS_SNAPSHOT:-20260803}"
asr_prepared="$campaign_root/prepared/parakeet-wispr-mass-v3-$snapshot"
output_root="$campaign_root/prepared/qwen-mass-v8-$snapshot"
new_source_root="$output_root/new-source"
reviewed_replay_source="/Volumes/0_Oueillez/wispr-data/prepared/qwen-final-runtime-gpt56-v1/final-runtime-adjudicated-v1/source.jsonl"
model_root="${VOXOL_ASR_MODEL_ROOT:-$repo_root/Artifacts/Training/2026-08-01-wispr-replay-v5/coreml-candidates/nemo-direct-waveform-int8}"
binary="$repo_root/.build/arm64-apple-macosx/release/voxol-asr-benchmark"
dataset_builder="$repo_root/.build/arm64-apple-macosx/release/voxol-dataset-builder"

for required in \
  "$dataset_root/polisher-manifest.jsonl" \
  "$asr_prepared/split-report.json" \
  "$reviewed_replay_source" \
  "$model_root/quantization-report.json" \
  "$binary" \
  "$dataset_builder"; do
  [[ -s "$required" ]] || {
    printf 'Missing Qwen campaign prerequisite: %s\n' "$required" >&2
    exit 1
  }
done
if pgrep -f '/Users/aris/Documents/wispr/wispr-transcribe.sh' >/dev/null 2>&1; then
  printf 'Wispr transcription is still active; Qwen preparation must wait.\n' >&2
  exit 1
fi

mkdir -p "$output_root"
python3 "$repo_root/Tools/training/convert_wispr_manifest_to_benchmark.py" \
  --input "$dataset_root/polisher-manifest.jsonl" \
  --split-report "$asr_prepared/split-report.json" \
  --output "$output_root/runtime-manifest-unfrozen.json" \
  --benchmark-id "voxol-wispr-mass-utterance-complete-$snapshot" \
  --require-complete-boundary
# Freeze through the Swift CLI, not freeze_asr_manifest.py. ASRBenchmarkKit
# computes contentSHA256 over the re-encoded manifest struct, so keys it does
# not declare are absent from the hashed bytes. The Python freezer hashes the
# file as written, extra keys included, and `validate --require-frozen` then
# rejects its digest. The Swift path is the one that has to agree with itself.
# The CLI refuses to overwrite its output, which would make every resumed run
# fail here. Freezing is deterministic — pinned timestamp, sorted items — so
# regenerating reproduces the same bytes and the campaign stays restartable.
rm -f "$output_root/runtime-manifest-frozen.json"
"$binary" freeze \
  --manifest "$output_root/runtime-manifest-unfrozen.json" \
  --audio-root "$dataset_root" \
  --output "$output_root/runtime-manifest-frozen.json" \
  --timestamp '2026-08-03T00:00:00Z'

"$binary" validate \
  --manifest "$output_root/runtime-manifest-frozen.json" \
  --audio-root "$dataset_root" \
  --require-frozen
"$binary" run-parakeet \
  --manifest "$output_root/runtime-manifest-frozen.json" \
  --audio-root "$dataset_root" \
  --model-root "$model_root" \
  --compute-units all \
  --output "$output_root/runtime-predictions.jsonl" \
  --resume
# Same overwrite guard as freeze: scoring a fixed manifest against a fixed
# predictions file is deterministic, so clearing the previous report keeps the
# campaign resumable instead of stranding it on a rerun.
rm -f "$output_root/runtime-vs-wispr-raw-report.json"
"$binary" score \
  --manifest "$output_root/runtime-manifest-frozen.json" \
  --predictions "$output_root/runtime-predictions.jsonl" \
  --output "$output_root/runtime-vs-wispr-raw-report.json"

python3 "$repo_root/Tools/training/prepare_wispr_qwen_dataset.py" \
  --input "$dataset_root/polisher-manifest.jsonl" \
  --split-report "$asr_prepared/split-report.json" \
  --raw-predictions "$output_root/runtime-predictions.jsonl" \
  --require-complete-boundary \
  --output-root "$new_source_root"

python3 "$repo_root/Tools/training/merge_qwen_sources.py" \
  --input "$reviewed_replay_source" \
  --input "$new_source_root/source.jsonl" \
  --output-root "$output_root/source"

"$dataset_builder" \
  --prepare-source "$output_root/source/source.jsonl" \
  --output "$output_root/prepared-source.jsonl"
"$dataset_builder" \
  --input "$output_root/source/source.jsonl" \
  --output "$output_root/mlx-data"

python3 - "$output_root" <<'PY'
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])

def rows(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]

source = {row["id"]: row for row in rows(root / "source" / "source.jsonl")}
prepared = {row["id"]: row for row in rows(root / "prepared-source.jsonl")}
summary = json.loads((root / "mlx-data" / "summary.json").read_text(encoding="utf-8"))
rejected = set(map(str, summary.get("rejected_ids", [])))
counts = Counter()
delta_ids = []
for identifier, row in source.items():
    if identifier in rejected:
        continue
    split = str(row["split"])
    language = str(row["language"])
    changed = prepared[identifier]["normalized_text"] != row["target_text"]
    counts[(split, language, "edit" if changed else "noop")] += 1
    if changed:
        delta_ids.append(identifier)

evaluation_edits = sum(
    counts[(split, language, "edit")]
    for split in ("validation", "test")
    for language in ("en", "fr")
)
training_edits = sum(counts[("train", language, "edit")] for language in ("en", "fr"))
eligible = (
    len(delta_ids) >= 500
    and evaluation_edits >= 150
    and all(counts[("train", language, "edit")] >= 100 for language in ("en", "fr"))
    and all(
        sum(counts[(split, language, "edit")] for split in ("validation", "test")) >= 50
        for language in ("en", "fr")
    )
)
payload = {
    "schema_version": "voxol-qwen-mass-gate-v1",
    "promotion_training_eligible": eligible,
    "accepted_example_count": len(source) - len(rejected),
    "rejected_example_count": len(rejected),
    "internal_delta_count": len(delta_ids),
    "training_delta_count": training_edits,
    "evaluation_delta_count": evaluation_edits,
    "counts": {
        split: {
            language: {kind: counts[(split, language, kind)] for kind in ("edit", "noop")}
            for language in ("en", "fr")
        }
        for split in ("train", "validation", "test")
    },
    "thresholds": {
        "minimum_internal_deltas": 500,
        "minimum_evaluation_deltas": 150,
        "minimum_training_deltas_per_language": 100,
        "minimum_evaluation_deltas_per_language": 50,
    },
    "source_sha256": hashlib.sha256((root / "source" / "source.jsonl").read_bytes()).hexdigest(),
}
(root / "qwen-mass-gate.json").write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
print(json.dumps(payload, indent=2, sort_keys=True))
PY

package="$campaign_root/prepared/VoxoL-Qwen-Mass-v8-$snapshot.zip"
rm -f "$package"
ditto -c -k --norsrc --keepParent "$output_root" "$package"
printf 'Qwen mass package: %s\n' "$package"
shasum -a 256 "$package"
