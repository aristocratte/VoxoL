#!/bin/bash
# Prepare and freeze the whole multilingual benchmark suite.
#
# Sequential on purpose: a VoxPopuli row group is several hundred megabytes and
# the tar-backed corpora stream a gigabyte each, so running corpora in parallel
# would trade a modest wall-clock win for memory pressure on a laptop that is
# also going to run the recogniser.
set -uo pipefail

ROOT="${1:-/Volumes/0_Oueillez/VoxoL-Benchmarks-Multilingual}"
SAMPLES="${SAMPLES:-300}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/cache"
BENCH="$ROOT/benchmarks"
LOG="$ROOT/prepare.log"

mkdir -p "$CACHE" "$BENCH"
: >"$LOG"

FLEURS_LANGS="en fr de es it pt nl pl"
COMMONVOICE_LANGS="en fr de es it pt nl pl"
MLS_LANGS="fr de es it pt nl pl"
VOXPOPULI_LANGS="en fr de es it nl pl"
# English has no MLS config, so LibriSpeech test-clean fills the audiobook
# slot and every language is measured on the same four kinds of speech.
LIBRISPEECH_LANGS="en"

prepare_one() {
  local corpus="$1" language="$2"
  local out="$BENCH/$corpus-$language"

  if [ -f "$out/manifest-frozen.json" ]; then
    echo "[skip] $corpus/$language already frozen" | tee -a "$LOG"
    return 0
  fi

  echo "[prep] $corpus/$language" | tee -a "$LOG"
  if ! python3 "$REPO/Scripts/prepare-multilingual-benchmark.py" \
    --corpus "$corpus" --language "$language" --samples "$SAMPLES" \
    --cache-root "$CACHE" --output-root "$out" >>"$LOG" 2>&1; then
    echo "[FAIL] prepare $corpus/$language" | tee -a "$LOG"
    return 1
  fi

  if ! "$REPO/.build/release/voxol-asr-benchmark" freeze \
    --manifest "$out/manifest-unfrozen.json" \
    --audio-root "$out/audio" \
    --output "$out/manifest-frozen.json" >>"$LOG" 2>&1; then
    echo "[FAIL] freeze $corpus/$language" | tee -a "$LOG"
    return 1
  fi

  local count
  count=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['items']))" \
    "$out/manifest-frozen.json")
  echo "[done] $corpus/$language: $count clips" | tee -a "$LOG"
}

for language in $FLEURS_LANGS; do prepare_one fleurs "$language"; done
for language in $MLS_LANGS; do prepare_one mls "$language"; done
for language in $VOXPOPULI_LANGS; do prepare_one voxpopuli "$language"; done
for language in $LIBRISPEECH_LANGS; do prepare_one librispeech "$language"; done
# Common Voice last: it is the largest download and the least likely to be the
# blocker for an early look at the other three.
for language in $COMMONVOICE_LANGS; do prepare_one commonvoice "$language"; done

echo "[suite] preparation finished" | tee -a "$LOG"
grep -c "^\[done\]" "$LOG" | xargs echo "[suite] frozen benchmarks:"
