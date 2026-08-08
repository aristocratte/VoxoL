#!/usr/bin/env bash
# Transcribe and score every frozen multilingual benchmark with Wispr Flow.
#
# Wispr is given the language explicitly because its app exposes that setting,
# so this is the configuration a Wispr user actually runs. VoxoL is measured
# with no hint at all. Where VoxoL still wins, it wins against the stronger
# configuration of its competitor.
#
# Segmentation is disabled by forcing the minimum cut length above the longest
# clip in the suite: one benchmark clip becomes exactly one Wispr request, so a
# score difference cannot come from one system seeing different audio spans.
set -uo pipefail

ROOT="${1:-/Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WISPR="${WISPR_SCRIPT:-$REPO/Scripts/wispr-transcribe.sh}"
CLI="$REPO/.build/release/voxol-asr-benchmark"
WORKERS="${WORKERS:-4}"
LOG="$ROOT/run-wispr.log"

[ -x "$WISPR" ] || { echo "missing $WISPR"; exit 1; }
[ -x "$CLI" ] || { echo "missing $CLI"; exit 1; }

# 30 s is the collector's ceiling and the suite's longest clip, so no clip
# reaches a silence cut. Should one ever split, the converter rejoins its
# chunks in order, so the comparison stays over the same audio either way.
export WISPR_MAX_CHUNK_SEC=30
export WISPR_TARGET_CHUNK_SEC=30
export WISPR_MIN_CHUNK_SEC=30
export WISPR_DEFER_MANIFEST_REBUILD=1

for manifest in "$ROOT"/benchmarks/*/manifest-frozen.json; do
  [ -f "$manifest" ] || continue
  directory="$(dirname "$manifest")"
  name="$(basename "$directory")"
  # Derived cells append a condition suffix (commonvoice-fr-babble10db), so a
  # naive suffix strip hands the competitor "babble10db" as its language hint
  # and quietly corrupts the comparison it is meant to make fair.
  base="${name%-babble*db}"
  language="${base##*-}"
  report="$directory/wispr-report.json"

  if [ -f "$report" ]; then
    echo "[skip] $name already scored" | tee -a "$LOG"
    continue
  fi

  workdir="$ROOT/wispr/$name"
  mkdir -p "$workdir"
  # Not mapfile: macOS still ships bash 3.2 as /bin/bash and this has to run
  # there as well as under a newer homebrew bash.
  clips=()
  while IFS= read -r clip; do clips+=("$clip"); done < <(
    # ._* are AppleDouble stubs the exFAT volume leaves beside every file;
    # sending them to a transcriber would fail 300 requests per benchmark.
    find "$directory/audio" -name '*.wav' ! -name '._*' | sort
  )
  if [ "${#clips[@]}" -eq 0 ]; then
    echo "[FAIL] no audio for $name" | tee -a "$LOG"
    continue
  fi

  echo "[wispr] $name (${#clips[@]} clips, lang=$language, $WORKERS workers)" | tee -a "$LOG"
  # A dropped connection leaves a record whose HTTP status is 000, and the
  # collector treats any existing record as finished. Left alone that scores as
  # an empty transcript, which blames the recogniser for a network failure.
  # Each pass deletes those records so the next one requests them again;
  # completed records are never re-requested.
  for attempt in 1 2 3; do
    for worker in $(seq 0 $((WORKERS - 1))); do
      shard=()
      for index in "${!clips[@]}"; do
        [ $((index % WORKERS)) -eq "$worker" ] && shard+=("${clips[$index]}")
      done
      [ "${#shard[@]}" -eq 0 ] && continue
      WISPR_LANG="$language" WISPR_OUT_DIR="$workdir" \
        "$WISPR" "${shard[@]}" >>"$workdir/worker-$worker.log" 2>&1 &
    done
    wait

    dropped=$(python3 "$REPO/Scripts/retry-failed-wispr-records.py" \
      --root "$ROOT" --benchmark "$name" --apply --quiet)
    [ "${dropped:-0}" -eq 0 ] && break
    echo "[wispr] $name: retrying $dropped dropped request(s) (pass $attempt)" \
      | tee -a "$LOG"
  done

  predictions="$directory/wispr-predictions.jsonl"
  if ! python3 "$REPO/Tools/training/convert_wispr_records_to_predictions.py" \
    --records "$workdir/dataset/records" \
    --output "$predictions" >>"$LOG" 2>&1; then
    echo "[FAIL] convert $name" | tee -a "$LOG"
    continue
  fi

  python3 "$REPO/Scripts/fill-missing-predictions.py" \
    --manifest "$manifest" --predictions "$predictions" \
    --coverage "$directory/wispr-coverage.json" | tee -a "$LOG"

  if ! "$CLI" score \
    --manifest "$manifest" \
    --predictions "$predictions" \
    --output "$report" \
    --per-item "$directory/wispr-items.jsonl" >>"$LOG" 2>&1; then
    echo "[FAIL] score $name" | tee -a "$LOG"
    continue
  fi

  python3 -c "
import json, sys
errors = json.load(open(sys.argv[1]))['finalClean']['wordErrors']
total = errors['substitutions'] + errors['deletions'] + errors['insertions']
print(f\"[wispr] {sys.argv[2]}: WER {100 * total / errors['referenceUnitCount']:.2f}%\")
" "$report" "$name" | tee -a "$LOG"

  # The collector keeps a directory of small files per clip. On the exFAT
  # volume this suite lives on, a 1 MiB allocation unit turns that into ~17 MiB
  # per clip — 8 GiB per benchmark, which filled a 931 GiB disk partway through
  # and cost the whole VoxPopuli run. Everything worth keeping is already in
  # the predictions and the report, so the workdir goes once those exist.
  if [ -f "$report" ] && [ -s "$predictions" ]; then
    rm -rf "$workdir"
  fi
done

echo "[wispr] finished" | tee -a "$LOG"
