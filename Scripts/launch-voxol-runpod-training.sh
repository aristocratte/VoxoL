#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  printf '%s\n' \
    "Usage: $0 RUNPOD_HOST RUNPOD_PORT [RUNPOD_USER]" \
    "Example: $0 213.173.111.17 37448 root" >&2
  exit 2
fi

HOST="$1"
PORT="$2"
REMOTE_USER="${3:-root}"
SSH_KEY="${VOXOL_SSH_KEY:-$HOME/.ssh/id_ed25519}"
REPOSITORY_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LAUNCHER="${VOXOL_GPU_LAUNCHER:-$REPOSITORY_ROOT/VoxoL_GPU_Train.sh}"
TEACHER="${VOXOL_TEACHER_DATASET:-/Volumes/0_Oueillez/wispr-data/prepared/voxol-wispr-asr-v2-20260801.tar.gz}"
REMOTE_INPUTS="/workspace/voxol-inputs"
REMOTE_WORK="${VOXOL_REMOTE_WORK:-/workspace/voxol-wispr-replay-v5}"
REMOTE_EXPORTS="/workspace/voxol-exports"
LOCAL_RESULTS="${VOXOL_LOCAL_RESULTS:-$REPOSITORY_ROOT/Artifacts/Training/2026-08-01-wispr-replay-v5}"

[[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || {
  printf '%s\n' "Invalid host: $HOST" >&2
  exit 2
}
[[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( PORT <= 65535 )) || {
  printf '%s\n' "Invalid port: $PORT" >&2
  exit 2
}
[[ "$REMOTE_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || {
  printf '%s\n' "Invalid remote user: $REMOTE_USER" >&2
  exit 2
}
[[ -s "$SSH_KEY" ]] || {
  printf '%s\n' "Missing SSH key: $SSH_KEY" >&2
  exit 1
}
[[ -s "$LAUNCHER" && -s "$TEACHER" ]] || {
  printf '%s\n' "The launcher or Wispr teacher archive is missing." >&2
  exit 1
}

SSH_OPTIONS=(
  -i "$SSH_KEY"
  -p "$PORT"
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=6
  -o StrictHostKeyChecking=accept-new
)
SCP_OPTIONS=(
  -i "$SSH_KEY"
  -P "$PORT"
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=6
  -o StrictHostKeyChecking=accept-new
)
TARGET="$REMOTE_USER@$HOST"
TEACHER_SHA256="$(shasum -a 256 "$TEACHER" | awk '{print $1}')"
LAUNCHER_SHA256="$(shasum -a 256 "$LAUNCHER" | awk '{print $1}')"
TEACHER_FILENAME="$(basename "$TEACHER")"
TEACHER_STEM="${TEACHER_FILENAME%.tar.gz}"
REMOTE_TEACHER="$REMOTE_INPUTS/$TEACHER_STEM-$TEACHER_SHA256.tar.gz"
REMOTE_LAUNCHER="$REMOTE_INPUTS/VoxoL_GPU_Train-$LAUNCHER_SHA256.sh"

upload_if_needed() {
  local source="$1" expected="$2" destination="$3" remote_digest
  local source_bytes remote_bytes remaining
  remote_digest="$(
    ssh "${SSH_OPTIONS[@]}" "$TARGET" \
      "if [ -f '$destination' ]; then sha256sum '$destination' | awk '{print \$1}'; fi"
  )"
  if [[ "$remote_digest" == "$expected" ]]; then
    printf '%s\n' "Reused on RunPod: $(basename "$destination")"
    return
  fi
  source_bytes="$(stat -f '%z' "$source")"
  remote_bytes="$(
    ssh "${SSH_OPTIONS[@]}" "$TARGET" \
      "if [ -f '$destination.partial' ]; then stat -c '%s' '$destination.partial'; else echo 0; fi"
  )"
  if [[ ! "$remote_bytes" =~ ^[0-9]+$ ]] || (( remote_bytes > source_bytes )); then
    ssh "${SSH_OPTIONS[@]}" "$TARGET" "rm -f '$destination.partial'"
    remote_bytes=0
  fi
  remaining=$((source_bytes - remote_bytes))
  printf '%s\n' \
    "Uploading and verifying: $(basename "$destination")" \
    "Resume point: $remote_bytes/$source_bytes bytes"
  if (( remaining > 0 )); then
    if command -v pv >/dev/null 2>&1; then
      tail -c "+$((remote_bytes + 1))" "$source" \
        | pv -s "$remaining" \
        | ssh "${SSH_OPTIONS[@]}" "$TARGET" "cat >> '$destination.partial'"
    else
      tail -c "+$((remote_bytes + 1))" "$source" \
        | ssh "${SSH_OPTIONS[@]}" "$TARGET" "cat >> '$destination.partial'"
    fi
  fi
  remote_digest="$(
    ssh "${SSH_OPTIONS[@]}" "$TARGET" \
      "sha256sum '$destination.partial' | awk '{print \$1}'"
  )"
  [[ "$remote_digest" == "$expected" ]] || {
    printf 'Remote SHA-256 mismatch for %s; the partial upload is retained for diagnosis.\n' \
      "$destination" >&2
    return 1
  }
  ssh "${SSH_OPTIONS[@]}" "$TARGET" "mv '$destination.partial' '$destination'"
}

ssh "${SSH_OPTIONS[@]}" "$TARGET" \
  "mkdir -p '$REMOTE_INPUTS' '$REMOTE_WORK' '$REMOTE_EXPORTS'"
upload_if_needed "$TEACHER" "$TEACHER_SHA256" "$REMOTE_TEACHER"
upload_if_needed "$LAUNCHER" "$LAUNCHER_SHA256" "$REMOTE_LAUNCHER"

REMOTE_PID="$REMOTE_WORK/run.pid"
REMOTE_LOG="$REMOTE_WORK/launcher.out"
RUNNING="$(
  ssh "${SSH_OPTIONS[@]}" "$TARGET" \
    "if [ -s '$REMOTE_PID' ] && kill -0 \"\$(cat '$REMOTE_PID')\" 2>/dev/null; then echo yes; fi"
)"
if [[ "$RUNNING" != "yes" ]]; then
  printf '%s\n' "Starting the verified training pipeline."
  ssh "${SSH_OPTIONS[@]}" "$TARGET" \
    "nohup bash '$REMOTE_LAUNCHER' \
      --yes \
      --hourly-price '${VOXOL_GPU_HOURLY_USD:-0.35}' \
      --budget '${VOXOL_MAX_BUDGET_USD:-10}' \
      --max-hours '${VOXOL_MAX_HOURS:-6}' \
      --max-epochs 5 \
      --work-root '$REMOTE_WORK' \
      --export-dir '$REMOTE_EXPORTS' \
      --teacher-dataset '$REMOTE_TEACHER' \
      --teacher-dataset-sha256 '$TEACHER_SHA256' \
      > '$REMOTE_LOG' 2>&1 < /dev/null & echo \$! > '$REMOTE_PID'"
else
  printf '%s\n' "The existing RunPod training process is still running; monitoring it."
fi

while :; do
  SNAPSHOT="$(
    ssh "${SSH_OPTIONS[@]}" "$TARGET" \
      "python3 - '$REMOTE_WORK/results/status.json' '$REMOTE_PID' <<'PY'
import json
from pathlib import Path
import os
import sys

status_path = Path(sys.argv[1])
pid_path = Path(sys.argv[2])
payload = {}
if status_path.is_file():
    try:
        payload = json.loads(status_path.read_text(encoding='utf-8'))
    except json.JSONDecodeError:
        pass
pid = int(pid_path.read_text()) if pid_path.is_file() else 0
running = False
if pid:
    try:
        os.kill(pid, 0)
        running = True
    except ProcessLookupError:
        pass
print(json.dumps({
    'running': running,
    'state': payload.get('state', 'initializing'),
    'stage': payload.get('currentStage', 'launcher setup'),
    'elapsedHours': payload.get('elapsedHours', 0),
    'estimatedCostUSD': payload.get('estimatedComputeCostUSD', 0),
}, sort_keys=True))
PY"
  )"
  printf '%s\n' "$SNAPSHOT"
  IS_RUNNING="$(
    python3 - "$SNAPSHOT" <<'PY'
import json
import sys
print("true" if json.loads(sys.argv[1])["running"] else "false")
PY
  )"
  if [[ "$IS_RUNNING" != "true" ]]; then
    break
  fi
  sleep 15
done

LATEST="$(
  ssh "${SSH_OPTIONS[@]}" "$TARGET" \
    "if [ -s '$REMOTE_WORK/results/latest-export.txt' ]; then tail -n 1 '$REMOTE_WORK/results/latest-export.txt'; fi"
)"
if [[ -z "$LATEST" ]]; then
  printf '%s\n' \
    "No result archive is available. Keep the Pod and inspect $REMOTE_LOG." >&2
  exit 1
fi

mkdir -p "$LOCAL_RESULTS"
scp "${SCP_OPTIONS[@]}" "$TARGET:$LATEST" "$LOCAL_RESULTS/"
LOCAL_ARCHIVE="$LOCAL_RESULTS/$(basename "$LATEST")"
if ! python3 - "$LOCAL_ARCHIVE" <<'PY'
import json
from pathlib import Path
import sys
import zipfile

archive = Path(sys.argv[1])
with zipfile.ZipFile(archive) as source:
    bad = source.testzip()
    if bad is not None:
        raise SystemExit(f"Corrupt result member: {bad}")
    names = set(source.namelist())
    required = {
        "VoxoL-Parakeet/results/source-gate.json",
        "VoxoL-Parakeet/results/status.json",
        "VoxoL-Parakeet/SHA256SUMS.txt",
    }
    missing = sorted(required - names)
    if missing:
        raise SystemExit(
            "The recovered ZIP is diagnostic-only and training did not finish. "
            f"Missing: {missing}"
        )
    gate = json.loads(
        source.read("VoxoL-Parakeet/results/source-gate.json").decode("utf-8")
    )
print(f"Verified training result: {archive}")
print(f"Source gate passed: {bool(gate.get('sourceGatePassed'))}")
PY
then
  printf '%s\n' \
    "The recovery archive was downloaded, but the complete training result is absent." \
    "Keep the Pod running and inspect: $REMOTE_LOG" \
    "RunPod remains billable until it is stopped or destroyed." >&2
  exit 1
fi

printf '%s\n' \
  "Training result retrieved in: $LOCAL_ARCHIVE" \
  "RunPod remains billable until it is stopped or destroyed in the dashboard."
