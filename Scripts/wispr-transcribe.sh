#!/usr/bin/env bash
#
# wispr-transcribe.sh
# ---------------------------------------------------------------------------
# Collect Wispr Flow transcriptions for pre-recorded audio, as the reference
# system in the VoxoL benchmark suite.
#
# REBUILT 2026-08-08. The original lived outside the repository, in
# ~/Documents/wispr, and was lost with that directory — no copy, no APFS
# snapshot, no Time Machine, and its source had never passed through a stored
# agent session. Everything already collected survived (9 258 + 4 211
# predictions, 35 teacher records), but new collection was impossible.
#
# This is a reconstruction from evidence, not from memory:
#   - the interface below is the original's, quoted from its header;
#   - the output schema comes from the 35 record.json files still on disk;
#   - the API contract was recovered from the installed desktop app and then
#     verified against the live service before this file was written.
#
# The API contract, for whoever maintains this next:
#   base            https://api.wisprflow.ai
#   raw             POST /llm/asr   {audio, language, prompt}      -> .content
#   edited          POST /llm/api   {audio, properties, transcript_id} -> .text
#   audio           base64 of a 16 kHz mono 16-bit PCM WAV, header included
#   auth            Authorization: <access token>   *** no "Bearer " prefix ***
#   token           Supabase session at
#                   ~/Library/Application Support/Wispr Flow/session.json,
#                   refreshed against the project's /auth/v1/token endpoint
#
# The missing "Bearer " is the whole trick: with it the service answers 401
# "Invalid or expired token", which reads exactly like an auth problem and
# sends you looking in the wrong place. The desktop client sends the token
# raw.
#
# Auth uses the signed-in Wispr Flow desktop session. No token, transcript or
# audio content is written to logs.
#
# Requires: ffmpeg, ffprobe, jq, curl, python3; yt-dlp for YouTube URLs.
#
# Usage:
#   ./wispr-transcribe.sh <audio-or-folder> [<audio-or-folder> ...]
#   ./wispr-transcribe.sh <YouTube-URL> [<YouTube-URL> ...]
#   ./wispr-transcribe.sh --urls-file links.txt
#   pbpaste | ./wispr-transcribe.sh --urls-stdin
#   ./wispr-transcribe.sh --resume
#   ./wispr-transcribe.sh --resume --parallel 4
# YouTube and pasted batches persist under $WISPR_OUT_DIR/youtube-jobs.
# An interrupted batch resumes with --resume; completed requests are reused.
#
# Durable output, by default under ~/Documents/wispr/transcripts:
#
#   dataset/records/<recording-id>/
#     audio/chunk_0001.wav
#     results/chunk_0001.json
#     segmentation.json
#     raw.txt
#     edited.txt
#     record.json
#
#   dataset/all-manifest.jsonl       every teacher result
#   dataset/asr-manifest.jsonl       usable audio -> raw rows
#   dataset/polisher-manifest.jsonl  usable raw -> edited pairs
#   dataset/dataset-summary.json
#
# Environment:
#   WISPR_OUT_DIR        output folder
#   WISPR_DATASET_DIR    dataset folder (default: $WISPR_OUT_DIR/dataset)
#   WISPR_LANG           "fr", "en", etc.; unset, empty, or "auto" = auto
#   WISPR_MAX_CHUNK_SEC  maximum request duration (default: 30, hard cap 30)
#   WISPR_TARGET_CHUNK_SEC preferred utterance duration (default: min(18, max))
#   WISPR_MIN_CHUNK_SEC  earliest allowed silence cut (default: min(6, target))
#   WISPR_MIN_SILENCE_SEC minimum pause considered by the segmenter (default: 0.45)
#   WISPR_APP_TYPE       "other" | "ai" | "email" (default: other)
#   WISPR_SPEAKER_ID     optional stable speaker/group identifier
#   WISPR_SESSION_ID     optional stable recording-session identifier
#   WISPR_DEFER_MANIFEST_REBUILD
#                        "1" skips shared manifest rebuilds for parallel workers
#   WISPR_MIN_REQUEST_INTERVAL
#                        global delay between request starts (default: 0.8s)
#   WISPR_MAX_RETRIES    transient HTTP attempts per request (default: 6)
#   WISPR_PARALLEL_VIDEOS batch workers (default: 3; maximum: 8)
#   WISPR_RATE_FILE      shared timestamp file for parallel request throttling
#   WISPR_ACCESS_TOKEN   already-refreshed token supplied by a batch supervisor
#   WISPR_LOG_PREFIX     identifies a video in interleaved batch logs
#   WISPR_API_BASE, WISPR_SUPA_URL, WISPR_SESSION_FILE overrides
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ "${1:-}" = "--ui" ]; then
  shift
  exec python3 "$SCRIPT_DIR/wispr_youtube_ui.py" "$@"
fi
for argument in "$@"; do
  case "$argument" in
    --help|-h)
      printf '%s\n' \
        'Usage: wispr-transcribe.sh <audio-or-folder|YouTube-URL> [...]' \
        '       wispr-transcribe.sh --urls-file links.txt' \
        '       pbpaste | wispr-transcribe.sh --urls-stdin' \
        '       wispr-transcribe.sh --resume [--parallel 1..8]' \
        '       wispr-transcribe.sh --ui'
      exit 0 ;;
    --urls-file|--urls-stdin|--resume|--parallel|http://*|https://*)
      exec python3 "$SCRIPT_DIR/wispr_youtube_batch.py" "$@" ;;
  esac
done

OUT_DIR="${WISPR_OUT_DIR:-$HOME/Documents/wispr/transcripts}"
DATASET_DIR="${WISPR_DATASET_DIR:-$OUT_DIR/dataset}"
RECORDS_DIR="$DATASET_DIR/records"
API_BASE="${WISPR_API_BASE:-https://api.wisprflow.ai}"
SUPA_URL="${WISPR_SUPA_URL:-https://dodjkfqhwrzqjwkfnthl.supabase.co}"
SESSION_FILE="${WISPR_SESSION_FILE:-$HOME/Library/Application Support/Wispr Flow/session.json}"
ASAR="${WISPR_ASAR:-/Applications/Wispr Flow.app/Contents/Resources/app.asar}"

LANG_PREF="${WISPR_LANG:-auto}"
APP_TYPE="${WISPR_APP_TYPE:-other}"
SPEAKER_ID="${WISPR_SPEAKER_ID:-}"
SESSION_ID="${WISPR_SESSION_ID:-}"
MAX_CHUNK="${WISPR_MAX_CHUNK_SEC:-30}"
MIN_SILENCE="${WISPR_MIN_SILENCE_SEC:-0.45}"
# 0.35 s was the original default; four workers against it earned a 15% 429
# rate on this service, so the floor is higher now. Raise it further if a run
# still reports retries.
MIN_INTERVAL="${WISPR_MIN_REQUEST_INTERVAL:-0.8}"
MAX_RETRIES="${WISPR_MAX_RETRIES:-6}"
DEFER_MANIFESTS="${WISPR_DEFER_MANIFEST_REBUILD:-0}"

# The service rejects anything longer; a caller asking for more gets the cap
# rather than a run that fails one clip at a time.
if ! [[ "$MAX_CHUNK" =~ ^[0-9]+$ ]] || [ "$MAX_CHUNK" -lt 1 ] || [ "$MAX_CHUNK" -gt 30 ]; then
  echo "WISPR_MAX_CHUNK_SEC must be between 1 and 30 seconds." >&2
  exit 1
fi
TARGET_CHUNK="${WISPR_TARGET_CHUNK_SEC:-$((MAX_CHUNK < 18 ? MAX_CHUNK : 18))}"
MIN_CHUNK="${WISPR_MIN_CHUNK_SEC:-$((TARGET_CHUNK < 6 ? TARGET_CHUNK : 6))}"

log() {
  if [ -n "${WISPR_LOG_PREFIX:-}" ]; then
    printf '%s %s\n' "$WISPR_LOG_PREFIX" "$*"
  else
    printf '%s\n' "$*"
  fi
}
die() { printf '%s\n' "$*" >&2; exit 1; }

for tool in ffmpeg ffprobe jq curl python3; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

# --- authentication -------------------------------------------------------
# The stored access token is often stale even when its own expiry says
# otherwise, so the refresh token is exchanged once per run. The anon key is
# read from the app bundle rather than hard-coded: it rotates with releases.
TOKEN_FILE="$(mktemp -t wispr-token)"

refresh_token() {
  python3 - "$SESSION_FILE" "$ASAR" "$SUPA_URL" "$TOKEN_FILE" <<'PYTHON'
import base64, json, re, subprocess, sys

session_file, asar, supa_url, out = sys.argv[1:5]

try:
    stored = json.load(open(session_file))
except OSError:
    sys.exit("Wispr Flow session file not found; sign in to the desktop app.")
raw = stored[next(iter(stored))]
if isinstance(raw, str) and raw.startswith("base64-"):
    raw = base64.b64decode(raw[7:]).decode()
session = json.loads(raw) if isinstance(raw, str) else raw

anon = None
try:
    blob = open(asar, "rb").read().decode("utf-8", "replace")
    for match in re.finditer(
        r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}", blob
    ):
        token = match.group(0)
        try:
            payload = json.loads(
                base64.urlsafe_b64decode(token.split(".")[1] + "==").decode()
            )
        except Exception:
            continue
        if payload.get("role") == "anon":
            anon = token
            break
except OSError:
    pass

refresh = session.get("refresh_token")
if anon and refresh:
    result = subprocess.run(
        [
            "curl", "-sS", "--max-time", "45", "-X", "POST",
            f"{supa_url}/auth/v1/token?grant_type=refresh_token",
            "-H", "Content-Type: application/json",
            "-H", f"apikey: {anon}",
            "-H", f"Authorization: Bearer {anon}",
            "--data-binary", "@-",
        ],
        input=json.dumps({"refresh_token": refresh}).encode(),
        capture_output=True,
    )
    try:
        refreshed = json.loads(result.stdout.decode())
        if refreshed.get("access_token"):
            open(out, "w").write(refreshed["access_token"])
            sys.exit(0)
    except Exception:
        pass

# Falling back to the stored token is better than failing outright: it works
# whenever the desktop app refreshed recently.
if not session.get("access_token"):
    sys.exit("No access token in the Wispr Flow session.")
open(out, "w").write(session["access_token"])
PYTHON
}

ACCESS_TOKEN="${WISPR_ACCESS_TOKEN:-}"
ensure_token() {
  [ -n "$ACCESS_TOKEN" ] && return 0
  refresh_token || { printf '%s\n' 'could not obtain a Wispr Flow access token' >&2; return 2; }
  ACCESS_TOKEN="$(cat "$TOKEN_FILE")"
  [ -n "$ACCESS_TOKEN" ] || { printf '%s\n' 'empty Wispr Flow access token' >&2; return 2; }
}

# --- request --------------------------------------------------------------
if [ -n "${WISPR_RATE_FILE:-}" ]; then
  LAST_REQUEST_FILE="$WISPR_RATE_FILE"
  mkdir -p "$(dirname "$LAST_REQUEST_FILE")" || exit 1
  touch "$LAST_REQUEST_FILE" || exit 1
  SHARED_RATE_FILE=1
else
  LAST_REQUEST_FILE="$(mktemp -t wispr-rate)"
  SHARED_RATE_FILE=0
fi
cleanup() {
  rm -f "$TOKEN_FILE"
  if [ "$SHARED_RATE_FILE" -eq 0 ]; then rm -f "$LAST_REQUEST_FILE"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$SHARED_RATE_FILE" -eq 0 ]; then printf '0' >"$LAST_REQUEST_FILE"; fi

throttle() {
  python3 - "$LAST_REQUEST_FILE" "$MIN_INTERVAL" <<'PYTHON'
import fcntl, sys, time

path, interval = sys.argv[1], float(sys.argv[2])
with open(path, "r+") as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    try:
        previous = float(handle.read() or 0)
    except ValueError:
        previous = 0.0
    now = time.time()
    wait = previous + interval - now
    if wait > 0:
        time.sleep(wait)
        now = time.time()
    handle.seek(0)
    handle.truncate()
    handle.write(str(now))
PYTHON
}

# Posts one chunk and prints "<http-status>\t<json-body>". Retries only what is
# worth retrying: a dropped connection or a 5xx is transient, a 4xx is not.
# Counting a dropped connection as a mishearing once misreported a whole
# benchmark by a factor of three.
post_chunk() {
  local endpoint="$1" body_file="$2" attempt=1 status body
  ensure_token || return 2
  while :; do
    throttle
    local response
    response="$(
      curl -sS -w $'\n%{http_code}' --max-time 90 -X POST "$API_BASE$endpoint" \
        -H "Content-Type: application/json" \
        -H "Authorization: $ACCESS_TOKEN" \
        --data-binary "@$body_file" 2>/dev/null
    )"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    [[ "$status" =~ ^[0-9][0-9][0-9]$ ]] || status="000"
    case "$status" in
      200) printf '%s\t%s' "$status" "$body"; return 0 ;;
      # 429 is the service asking for less, not refusing the request. Treating
      # it as final made a first pass drop 47 of 300 clips, which the caller
      # then had to re-request wholesale. It backs off harder than a transient
      # network failure because the cause is this client's own rate.
      429|000|5*) ;;
      *) printf '%s\t%s' "$status" "$body"; return 0 ;;
    esac
    if [ "$attempt" -ge "$MAX_RETRIES" ]; then
      printf '%s\t%s' "${status:-000}" "$body"
      return 0
    fi
    if [ "$status" = "429" ]; then
      sleep "$((attempt * attempt * 5))"
    else
      sleep "$((attempt * 2))"
    fi
    attempt=$((attempt + 1))
  done
}

if [ "${1:-}" = "--token-only" ]; then
  ensure_token || exit 2
  printf '%s' "$ACCESS_TOKEN"
  exit 0
fi

# --- inputs ---------------------------------------------------------------
DATASET_ABS="$(cd "$(dirname "$DATASET_DIR")" 2>/dev/null && pwd -P)/$(basename "$DATASET_DIR")"
inputs=()
collect_input() {
  local argument="$1"
  if [ -d "$argument" ]; then
    while IFS= read -r -d '' file; do
      case "$file" in
        "$DATASET_ABS"|"$DATASET_ABS"/*) continue ;;
      esac
      inputs+=("$file")
    done < <(
      find "$argument" -type f \
        \( -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.mka' \
           -o -iname '*.flac' -o -iname '*.ogg' -o -iname '*.opus' \) \
        ! -name '._*' -print0 | sort -z
    )
  elif [ -f "$argument" ]; then
    local file
    file="$(cd "$(dirname "$argument")" && pwd -P)/$(basename "$argument")"
    case "$file" in
      "$DATASET_ABS"|"$DATASET_ABS"/*)
        log "skip (generated dataset audio): $file"
        return
        ;;
    esac
    inputs+=("$file")
  else
    log "skip (missing): $argument"
  fi
}

[ "$#" -gt 0 ] || die "no input files. Usage: $0 <audio-or-folder> [...]"
for argument in "$@"; do collect_input "$argument"; done
[ "${#inputs[@]}" -gt 0 ] || die "error: no audio files found in given inputs"

mkdir -p "$RECORDS_DIR"

# --- per-recording --------------------------------------------------------
processed=0
failed=0

for source in "${inputs[@]}"; do
  name="$(basename "$source")"
  stem="${name%.*}"
  source_sha="$(shasum -a 256 "$source" | cut -d' ' -f1)"
  source_bytes="$(stat -f '%z' "$source")"
  recording_id="$stem-$(printf '%s' "$source_sha" | cut -c1-16)"
  record_dir="$RECORDS_DIR/$recording_id"

  if [ -f "$record_dir/record.json" ] &&
     jq -e --arg sha "$source_sha" '
       .source.sha256 == $sha and (.results | length) > 0 and
       all(.results[]; .raw_http_status == "200" and .edited_http_status == "200")
     ' "$record_dir/record.json" >/dev/null 2>&1; then
    log "skip (already collected): $name"
    processed=$((processed + 1))
    continue
  fi

  log "▶ $name [$recording_id]"
  mkdir -p "$record_dir/audio" "$record_dir/results"

  # Normalise once, then segment. Sixteen kilohertz mono PCM is what the
  # service expects and what the benchmark audio already is, so a benchmark
  # clip passes through untouched.
  normalised="$record_dir/audio/source-16k.wav"
  ffmpeg -hide_banner -loglevel error -y -i "$source" \
    -ac 1 -ar 16000 -acodec pcm_s16le "$normalised" 2>/dev/null || {
    log "  ✗ could not decode audio"
    failed=$((failed + 1))
    rm -f "$normalised"
    continue
  }

  # Silence-aware segmentation, capped by the service limit. A clip already
  # shorter than the cap stays one chunk, which is what the benchmark needs:
  # one clip, one request, no segmentation artefacts in the comparison.
  python3 - "$normalised" "$record_dir" "$MAX_CHUNK" "$TARGET_CHUNK" "$MIN_CHUNK" "$MIN_SILENCE" <<'PYTHON'
import json, math, os, subprocess, sys, wave
from pathlib import Path

source, record_dir, maximum, target, minimum, min_silence = (
    sys.argv[1], Path(sys.argv[2]), float(sys.argv[3]),
    float(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6]),
)

with wave.open(source, "rb") as handle:
    rate = handle.getframerate()
    frames = handle.getnframes()
    audio = handle.readframes(frames)
total = frames / rate

def silences():
    result = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", source, "-af",
         f"silencedetect=noise=-32dB:d={min_silence}", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    marks = []
    for line in result.stderr.splitlines():
        if "silence_start:" in line:
            marks.append(float(line.rsplit("silence_start:", 1)[1].strip()))
    return marks

cuts = [0.0]
if total > maximum:
    candidates = silences()
    while cuts[-1] + maximum < total:
        window_start, window_end = cuts[-1] + minimum, cuts[-1] + maximum
        preferred = cuts[-1] + target
        usable = [c for c in candidates if window_start <= c <= window_end]
        # Nearest silence to the preferred length, or a hard cut when the
        # speaker never pauses.
        cuts.append(min(usable, key=lambda c: abs(c - preferred))
                    if usable else window_end)
cuts.append(total)

chunks = []
for index in range(len(cuts) - 1):
    start, end = cuts[index], cuts[index + 1]
    if end - start < 0.05:
        continue
    path = record_dir / "audio" / f"chunk_{index + 1:04d}.wav"
    first, last = int(start * rate), int(end * rate)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(audio[first * 2 : last * 2])
    chunks.append({
        "chunk": index + 1,
        "audio_file": f"audio/{path.name}",
        "audio_bytes": path.stat().st_size,
        "start_seconds": round(start, 3),
        "end_seconds": round(end, 3),
        "duration_seconds": round(end - start, 3),
    })

temporary = record_dir / f"segmentation.json.tmp.{os.getpid()}"
temporary.write_text(
    json.dumps({"chunks": chunks, "source_duration_seconds": round(total, 3),
                "max_chunk_seconds": maximum, "target_chunk_seconds": target,
                "min_chunk_seconds": minimum,
                "min_silence_seconds": min_silence}, indent=2) + "\n"
)
temporary.replace(record_dir / "segmentation.json")
PYTHON
  if [ "$?" -ne 0 ]; then
    log "  ✗ could not segment audio"
    failed=$((failed + 1))
    rm -f "$normalised"
    continue
  fi

  chunk_count="$(jq '.chunks | length' "$record_dir/segmentation.json")"
  if ! [[ "$chunk_count" =~ ^[0-9]+$ ]] || [ "$chunk_count" -lt 1 ]; then
    log "  ✗ no usable audio chunks"
    failed=$((failed + 1))
    rm -f "$normalised"
    continue
  fi
  duration="$(jq -r '.source_duration_seconds' "$record_dir/segmentation.json")"
  log "  $chunk_count persistent chunk(s) (≤ ${MAX_CHUNK}s)"

  chunk_index=0
  auth_failed=0
  save_chunk_state() {
    local destination="$1" payload="$2" temporary="${1}.tmp.$$"
    printf '%s\n' "$payload" >"$temporary" && mv "$temporary" "$destination"
  }
  while [ "$chunk_index" -lt "$chunk_count" ]; do
    chunk_index=$((chunk_index + 1))
    chunk_file="$(jq -r ".chunks[$((chunk_index - 1))].audio_file" "$record_dir/segmentation.json")"
    chunk_path="$record_dir/$chunk_file"
    chunk_sha="$(shasum -a 256 "$chunk_path" | cut -d' ' -f1)"
    state_file="$record_dir/results/chunk_$(printf '%04d' "$chunk_index").state.json"

    # Old partial records predate per-chunk state files. Import their successful
    # requests once so a retry does not pay for the same audio again.
    if [ ! -s "$state_file" ] && [ -s "$record_dir/record.json" ]; then
      jq -c --argjson index "$chunk_index" --arg sha "$chunk_sha" \
        --arg lang "$LANG_PREF" --arg app "$APP_TYPE" '
        first(.results[] | select(.chunk == $index and .audio_sha256 == $sha and
          .requested_language == $lang and .app_type == $app)) // empty
      ' "$record_dir/record.json" >"${state_file}.migration.$$" 2>/dev/null || true
      if [ -s "${state_file}.migration.$$" ]; then
        mv "${state_file}.migration.$$" "$state_file"
      else
        rm -f "${state_file}.migration.$$"
      fi
    fi
    if [ -s "$state_file" ] && jq -e --arg sha "$chunk_sha" \
        --arg lang "$LANG_PREF" --arg app "$APP_TYPE" \
        --arg recording "$recording_id" '
        .audio_sha256 == $sha and .requested_language == $lang and
        .app_type == $app and .recording_id == $recording
      ' "$state_file" >/dev/null 2>&1; then
      state="$(cat "$state_file")"
    else
      state="$(jq -n --arg sha "$chunk_sha" --arg lang "$LANG_PREF" \
        --arg app "$APP_TYPE" --arg recording "$recording_id" '{
        audio_sha256: $sha, requested_language: $lang, app_type: $app,
        recording_id: $recording, raw: "", raw_http_status: "pending",
        edited: "", edited_http_status: "pending", detected_language: ""
      }')"
    fi

    language_field="$LANG_PREF"
    [ "$language_field" = "auto" ] && language_field=""

    raw_status="$(printf '%s' "$state" | jq -r '.raw_http_status // "pending"')"
    if [ "$raw_status" != "200" ]; then
      if ! ensure_token; then auth_failed=1; break; fi
      body_raw="$(mktemp -t wispr-body)"
      python3 - "$chunk_path" "$language_field" "$body_raw" <<'PYTHON'
import base64, json, sys
audio, language, out = sys.argv[1:4]
json.dump(
    {"audio": base64.b64encode(open(audio, "rb").read()).decode(),
     "language": language, "prompt": ""},
    open(out, "w"),
)
PYTHON
      raw_response="$(post_chunk /llm/asr "$body_raw")"
      rm -f "$body_raw"
      raw_status="${raw_response%%$'\t'*}"
      raw_body="${raw_response#*$'\t'}"
      if [ "$raw_status" = "200" ] &&
         ! printf '%s' "$raw_body" | jq -e 'type == "object" and (.content | type == "string")' >/dev/null 2>&1; then
        raw_status="invalid_response"
      fi
      raw_text="$(printf '%s' "$raw_body" | jq -r '.content // ""' 2>/dev/null)"
      detected="$(printf '%s' "$raw_body" | jq -r '.detected_language // ""' 2>/dev/null)"
      state="$(jq -n --argjson prior "$state" --arg raw "$raw_text" \
        --arg status "$raw_status" --arg detected "$detected" '
        $prior + {raw: $raw, raw_http_status: $status, detected_language: $detected}
      ')"
      save_chunk_state "$state_file" "$state" || die "cannot save chunk state: $state_file"
      if printf '%s' "$raw_body" | jq -e . >/dev/null 2>&1; then
        printf '%s\n' "$raw_body" >"${state_file%.state.json}.json.tmp.$$" &&
          mv "${state_file%.state.json}.json.tmp.$$" "${state_file%.state.json}.json"
      fi
      if [ "$raw_status" = "401" ] || [ "$raw_status" = "403" ]; then
        auth_failed=1
        break
      fi
    fi

    edited_status="$(printf '%s' "$state" | jq -r '.edited_http_status // "pending"')"
    if [ "$edited_status" != "200" ]; then
      if ! ensure_token; then auth_failed=1; break; fi
      body_edited="$(mktemp -t wispr-body)"
      python3 - "$chunk_path" "$body_edited" "$APP_TYPE" <<'PYTHON'
import base64, json, sys
audio, out, app_type = sys.argv[1:4]
json.dump(
    {"audio": base64.b64encode(open(audio, "rb").read()).decode(),
     "properties": {"app_type": app_type}, "transcript_id": None},
    open(out, "w"),
)
PYTHON
      edited_response="$(post_chunk /llm/api "$body_edited")"
      rm -f "$body_edited"
      edited_status="${edited_response%%$'\t'*}"
      edited_body="${edited_response#*$'\t'}"
      if [ "$edited_status" = "200" ] &&
         ! printf '%s' "$edited_body" | jq -e 'type == "object" and (.text | type == "string")' >/dev/null 2>&1; then
        edited_status="invalid_response"
      fi
      edited_text="$(printf '%s' "$edited_body" | jq -r '.text // ""' 2>/dev/null)"
      state="$(jq -n --argjson prior "$state" --arg edited "$edited_text" \
        --arg status "$edited_status" '$prior + {edited: $edited, edited_http_status: $status}')"
      save_chunk_state "$state_file" "$state" || die "cannot save chunk state: $state_file"
      if [ "$edited_status" = "401" ] || [ "$edited_status" = "403" ]; then
        auth_failed=1
        break
      fi
    fi
    if [ "$raw_status" = "200" ] && [ "$edited_status" = "200" ]; then
      log "  chunk $chunk_index/$chunk_count ready"
    else
      log "  chunk $chunk_index/$chunk_count incomplete (raw $raw_status; edited $edited_status)"
    fi
  done

  record_status=0
  python3 "$SCRIPT_DIR/wispr_finalize_record.py" \
    --record-dir "$record_dir" --source "$source" --source-sha256 "$source_sha" \
    --duration "$duration" --language "$LANG_PREF" --app-type "$APP_TYPE" \
    --speaker-id "$SPEAKER_ID" --session-id "$SESSION_ID" \
    --youtube-url "${WISPR_SOURCE_URL:-}" \
    --youtube-video-id "${WISPR_SOURCE_VIDEO_ID:-}" || record_status=$?

  if [ "$record_status" -eq 0 ]; then
    log "  ✓ record -> $record_dir/record.json"
    processed=$((processed + 1))
  else
    log "  ✗ incomplete record; re-run to retry missing requests"
    failed=$((failed + 1))
  fi
  rm -f "$normalised"
  if [ "$auth_failed" -eq 1 ]; then
    log "Wispr authentication rejected; sign in to the desktop app, then resume."
    if [ "$DEFER_MANIFESTS" != "1" ]; then
      python3 "$SCRIPT_DIR/wispr_rebuild_manifests.py" --dataset-dir "$DATASET_DIR"
    fi
    exit 42
  fi
done

# --- shared manifests -----------------------------------------------------
if [ "$DEFER_MANIFESTS" != "1" ]; then
  log ""
  log "Rebuilding dataset manifests..."
  python3 "$SCRIPT_DIR/wispr_rebuild_manifests.py" --dataset-dir "$DATASET_DIR" || exit 1
fi

log "Done. $processed file(s), $failed failed -> $DATASET_DIR"
[ "$failed" -eq 0 ]
