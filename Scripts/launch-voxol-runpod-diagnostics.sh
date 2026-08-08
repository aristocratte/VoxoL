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
LAUNCHER="$REPOSITORY_ROOT/VoxoL_GPU_Train.sh"
TEACHER="/Volumes/0_Oueillez/wispr-data/prepared/voxol-wispr-asr-v1.tar.gz"
PRIMARY="$REPOSITORY_ROOT/Artifacts/Training/2026-07-29-wispr-silver/voxol-parakeet-results-20260729T090136Z.zip"
SECONDARY="$REPOSITORY_ROOT/Artifacts/Training/2026-07-29-wispr-silver/voxol-parakeet-results-20260729T085519Z.zip"
TEACHER_SHA256="53caf616c80088013053fed560c027ce0cf1883e403ace24de3e8b1a2880a699"
PRIMARY_SHA256="7d7ea8015c850b7e75e8f5bd50aeeb802feba678333e7568480448ab1f774f80"
SECONDARY_SHA256="2aa27e157519b135af0dc7d79dfa9029f43588a974e5ceacb20a6ac9ea3d75a0"
REMOTE_INPUTS="/workspace/voxol-inputs"
REMOTE_WORK="/root/voxol-diagnostics"
LOCAL_RESULTS="$REPOSITORY_ROOT/Artifacts/Diagnostics/Remote"

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
[[ -f "$SSH_KEY" ]] || {
  printf '%s\n' "Missing SSH key: $SSH_KEY" >&2
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

verify_local() {
  local path="$1" expected="$2" actual
  [[ -s "$path" ]] || {
    printf '%s\n' "Missing input: $path" >&2
    exit 1
  }
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    printf '%s\n' "SHA-256 mismatch for $path: $actual" >&2
    exit 1
  }
}

upload_if_needed() {
  local source="$1" expected="$2" remote_name="$3" remote_digest
  remote_digest="$(
    ssh "${SSH_OPTIONS[@]}" "$TARGET" \
      "if [ -f '$REMOTE_INPUTS/$remote_name' ]; then sha256sum '$REMOTE_INPUTS/$remote_name' | awk '{print \$1}'; fi"
  )"
  if [[ "$remote_digest" == "$expected" ]]; then
    printf '%s\n' "Reused on RunPod: $remote_name"
    return
  fi
  printf '%s\n' "Uploading: $remote_name"
  scp "${SCP_OPTIONS[@]}" "$source" "$TARGET:$REMOTE_INPUTS/$remote_name.partial"
  ssh "${SSH_OPTIONS[@]}" "$TARGET" \
    "test \"\$(sha256sum '$REMOTE_INPUTS/$remote_name.partial' | awk '{print \$1}')\" = '$expected' && mv '$REMOTE_INPUTS/$remote_name.partial' '$REMOTE_INPUTS/$remote_name'"
}

verify_local "$TEACHER" "$TEACHER_SHA256"
verify_local "$PRIMARY" "$PRIMARY_SHA256"
verify_local "$SECONDARY" "$SECONDARY_SHA256"
[[ -s "$LAUNCHER" ]] || {
  printf '%s\n' "Missing launcher: $LAUNCHER" >&2
  exit 1
}

ssh "${SSH_OPTIONS[@]}" "$TARGET" "mkdir -p '$REMOTE_INPUTS' '$REMOTE_WORK'"
upload_if_needed "$TEACHER" "$TEACHER_SHA256" "voxol-wispr-asr-v1.tar.gz"
upload_if_needed "$PRIMARY" "$PRIMARY_SHA256" "candidate-1-epoch.zip"
upload_if_needed "$SECONDARY" "$SECONDARY_SHA256" "candidate-3-epochs.zip"
scp "${SCP_OPTIONS[@]}" "$LAUNCHER" "$TARGET:$REMOTE_INPUTS/VoxoL_GPU_Train.sh"

set +e
ssh -tt "${SSH_OPTIONS[@]}" "$TARGET" \
  "bash '$REMOTE_INPUTS/VoxoL_GPU_Train.sh' \
    --yes \
    --hourly-price '${VOXOL_GPU_HOURLY_USD:-0.35}' \
    --budget '${VOXOL_MAX_BUDGET_USD:-5}' \
    --max-hours '${VOXOL_MAX_HOURS:-4}' \
    --work-root '$REMOTE_WORK' \
    --export-dir /workspace/voxol-exports \
    --teacher-dataset '$REMOTE_INPUTS/voxol-wispr-asr-v1.tar.gz' \
    --teacher-dataset-sha256 '$TEACHER_SHA256' \
    --research-archive '$REMOTE_INPUTS/candidate-1-epoch.zip' \
    --research-archive-sha256 '$PRIMARY_SHA256' \
    --secondary-research-archive '$REMOTE_INPUTS/candidate-3-epochs.zip' \
    --secondary-research-archive-sha256 '$SECONDARY_SHA256'"
REMOTE_STATUS=$?
set -e

LATEST="$(
  ssh "${SSH_OPTIONS[@]}" "$TARGET" \
    "if [ -s '$REMOTE_WORK/results/latest-export.txt' ]; then tail -n 1 '$REMOTE_WORK/results/latest-export.txt'; fi"
)"
if [[ -n "$LATEST" ]]; then
  mkdir -p "$LOCAL_RESULTS"
  scp "${SCP_OPTIONS[@]}" "$TARGET:$LATEST" "$LOCAL_RESULTS/"
  printf '%s\n' "Result retrieved in: $LOCAL_RESULTS"
else
  printf '%s\n' "No result archive was exposed; keep the Pod and inspect $REMOTE_WORK." >&2
fi

printf '%s\n' \
  "RunPod is still billable until you stop or destroy it in the dashboard."
exit "$REMOTE_STATUS"
