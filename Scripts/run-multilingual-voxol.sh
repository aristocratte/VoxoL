#!/usr/bin/env bash
# Transcribe and score every frozen multilingual benchmark with VoxoL.
#
# VoxoL runs with no language hint: the shipped app detects the language from
# the audio, and measuring it any other way would report a number no user ever
# sees. Wispr, by contrast, is given the language explicitly, because its app
# exposes that setting — see run-multilingual-wispr.sh.
set -uo pipefail

ROOT="${1:-/Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_ROOT="${VOXOL_MODEL_ROOT:-$HOME/Library/Application Support/VoxoL/Models/asr/7c35754d166cca382ad1e53e68b01e7c575f3a1d}"
CLI="$REPO/.build/release/voxol-asr-benchmark"
# A label lets a second runtime (FP16, stock weights, another compute unit) be
# measured on the same frozen benchmarks without overwriting the shipped
# runtime's results.
LABEL="${VOXOL_LABEL:-voxol}"
ONLY="${VOXOL_ONLY:-}"
# The shipped INT8 runtime runs on the Neural Engine; an FP16 build of the
# same graph fails there with CoreML error -9 and has to go to the GPU.
COMPUTE_UNITS="${VOXOL_COMPUTE_UNITS:-all}"
# Set to measure the whole product — deterministic cleanup, fast-path gating
# and the polisher — instead of the recogniser on its own.
POLISHER_ROOT="${VOXOL_POLISHER_ROOT:-}"
LOG="$ROOT/run-$LABEL.log"

[ -x "$CLI" ] || { echo "missing $CLI"; exit 1; }
[ -d "$MODEL_ROOT" ] || { echo "missing model root $MODEL_ROOT"; exit 1; }

for manifest in "$ROOT"/benchmarks/*/manifest-frozen.json; do
  [ -f "$manifest" ] || continue
  directory="$(dirname "$manifest")"
  name="$(basename "$directory")"
  if [ -n "$ONLY" ] && ! printf '%s\n' $ONLY | grep -qx "$name"; then continue; fi
  predictions="$directory/$LABEL-predictions.jsonl"
  report="$directory/$LABEL-report.json"

  if [ -f "$report" ]; then
    echo "[skip] $name already scored" | tee -a "$LOG"
    continue
  fi

  echo "[$LABEL] $name" | tee -a "$LOG"
  if ! "$CLI" run-parakeet \
    --manifest "$manifest" \
    --audio-root "$directory/audio" \
    --model-root "$MODEL_ROOT" \
    --output "$predictions" \
    --compute-units "$COMPUTE_UNITS" \
    ${POLISHER_ROOT:+--polisher-root "$POLISHER_ROOT"} \
    --resume >>"$LOG" 2>&1; then
    echo "[FAIL] transcribe $name" | tee -a "$LOG"
    continue
  fi

  python3 "$REPO/Scripts/fill-missing-predictions.py" \
    --manifest "$manifest" --predictions "$predictions" \
    --coverage "$directory/$LABEL-coverage.json" | tee -a "$LOG"

  if ! "$CLI" score \
    --manifest "$manifest" \
    --predictions "$predictions" \
    --output "$report" \
    --per-item "$directory/$LABEL-items.jsonl" >>"$LOG" 2>&1; then
    echo "[FAIL] score $name" | tee -a "$LOG"
    continue
  fi

  python3 -c "
import json, sys
errors = json.load(open(sys.argv[1]))['finalClean']['wordErrors']
total = errors['substitutions'] + errors['deletions'] + errors['insertions']
print(f\"[{sys.argv[3]}] {sys.argv[2]}: WER {100 * total / errors['referenceUnitCount']:.2f}%\")
" "$report" "$name" "$LABEL" | tee -a "$LOG"
done

echo "[$LABEL] finished" | tee -a "$LOG"
