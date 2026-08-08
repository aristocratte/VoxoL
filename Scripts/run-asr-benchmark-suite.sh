#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
suite_root="${VOXOL_BENCHMARK_SUITE_ROOT:-/Volumes/0_Oueillez/VoxoL-Benchmarks-v2}"
source_root="$suite_root/sources"
benchmark_root="$suite_root/benchmarks"
run_id="${VOXOL_BENCHMARK_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
run_root="$suite_root/runs/$run_id"
binary="$repo_root/.build/arm64-apple-macosx/release/voxol-asr-benchmark"
asr_revision="$(
  jq -r '.models[] | select(.role == "asr") | .revision' \
    "$repo_root/Models/manifests/runtime-models.json"
)"
model_root="${VOXOL_ASR_MODEL_ROOT:-$HOME/Library/Application Support/VoxoL/Models/asr/$asr_revision}"
freeze_timestamp="2026-08-03T00:00:00Z"

if [[ ! -d /Volumes/0_Oueillez ]]; then
  echo "The 0_Oueillez SSD is not mounted." >&2
  exit 1
fi
if [[ ! -d "$model_root" ]]; then
  echo "The active ASR runtime is missing: $model_root" >&2
  exit 1
fi
available_kib="$(df -Pk "$suite_root" | awk 'NR == 2 {print $4}')"
if [[ "$available_kib" -lt 10485760 ]]; then
  echo "At least 10 GiB must remain free on 0_Oueillez." >&2
  exit 1
fi

mkdir -p "$source_root" "$benchmark_root" "$run_root"
cd "$repo_root"

echo "[1/4] Preparing and verifying official benchmark sources"
python3 Scripts/prepare-fleurs-test-benchmark.py \
  --cache-root "$source_root/fleurs" \
  --output-root "$benchmark_root/fleurs-fr-en"
python3 Scripts/prepare-mediaspeech-fr-benchmark.py \
  --cache-root "$source_root/mediaspeech-fr" \
  --output-root "$benchmark_root/mediaspeech-fr"
python3 Scripts/prepare-librispeech-test-benchmark.py \
  --cache-root "$source_root/librispeech" \
  --output-root "$benchmark_root/librispeech-test"

echo "[2/4] Freezing and validating manifests"
for name in fleurs-fr-en mediaspeech-fr librispeech-test; do
  unfrozen="$benchmark_root/$name/manifest-unfrozen.json"
  frozen="$benchmark_root/$name/manifest-frozen.json"
  if [[ ! -f "$frozen" ]]; then
    python3 Tools/training/freeze_asr_manifest.py \
      --input "$unfrozen" \
      --output "$frozen" \
      --timestamp "$freeze_timestamp"
  fi
  "$binary" validate \
    --manifest "$frozen" \
    --audio-root "$benchmark_root/$name/audio" \
    --require-frozen
done

echo "[3/4] Running the selected Parakeet runtime with resumable outputs"
for name in fleurs-fr-en mediaspeech-fr librispeech-test; do
  manifest="$benchmark_root/$name/manifest-frozen.json"
  predictions="$run_root/$name-predictions.jsonl"
  report="$run_root/$name-report.json"
  expected_count="$(jq '.items | length' "$manifest")"
  "$binary" run-parakeet \
    --manifest "$manifest" \
    --audio-root "$benchmark_root/$name/audio" \
    --model-root "$model_root" \
    --compute-units all \
    --output "$predictions" \
    --resume
  actual_count="$(wc -l < "$predictions" | tr -d ' ')"
  if [[ "$actual_count" != "$expected_count" ]]; then
    echo "$name produced $actual_count/$expected_count predictions." >&2
    exit 1
  fi
  if [[ ! -f "$report" ]]; then
    "$binary" score \
      --manifest "$manifest" \
      --predictions "$predictions" \
      --output "$report"
  fi
done

echo "[4/4] Writing the compact result summary"
python3 - "$run_root" "$model_root" <<'PY'
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys

run_root = Path(sys.argv[1])
model_root = Path(sys.argv[2])
rows = []
for report_path in sorted(run_root.glob("*-report.json")):
    if report_path.name.startswith("._"):
        continue
    report = json.loads(report_path.read_text(encoding="utf-8"))
    metrics = report["rawVerbatim"]
    latency = report["latency"]["inference"]
    rows.append(
        {
            "benchmark_id": report["benchmarkID"],
            "item_count": metrics["itemCount"],
            "macro_wer": metrics["macroWER"],
            "micro_wer": sum(metrics["wordErrors"][key] for key in ("deletions", "insertions", "substitutions"))
            / metrics["wordErrors"]["referenceUnitCount"],
            "p50_ms": latency["p50Milliseconds"],
            "p95_ms": latency["p95Milliseconds"],
            "p99_ms": latency["p99Milliseconds"],
            "report": str(report_path),
        }
    )
quantization = json.loads((model_root / "quantization-report.json").read_text(encoding="utf-8"))
encoder_weights = model_root / "encoder.mlpackage" / "Data" / "com.apple.CoreML" / "weights" / "weight.bin"
encoder_digest = hashlib.sha256()
with encoder_weights.open("rb") as stream:
    while chunk := stream.read(1024 * 1024):
        encoder_digest.update(chunk)
summary = {
    "schema_version": 1,
    "asr_revision": model_root.name,
    "candidate_delta_sha256": quantization["deltaSHA256"],
    "encoder_weight_sha256": encoder_digest.hexdigest(),
    "runtime_variant": quantization.get("variant", "unknown"),
    "runtime_root": str(model_root),
    "benchmarks": rows,
}
summary_path = run_root / "summary.json"
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(summary, indent=2, sort_keys=True))
PY

echo "Benchmark suite complete: $run_root/summary.json"
