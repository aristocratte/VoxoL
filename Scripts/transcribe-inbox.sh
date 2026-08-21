#!/usr/bin/env bash
#
# transcribe-inbox.sh — drop any audio or video into Data/corpus/inbox/, get
# raw transcripts ready for the correction pass.
#
# The corpus bottleneck is faithful-mode volume, and the cheapest honest
# source is real speech run through the real recogniser. This turns anything
# ffmpeg can read — voice memos, screen recordings, podcast episodes, videos —
# into 16 kHz mono WAV, transcribes each with the production Parakeet model,
# and appends one JSON line per file to inbox-raws.jsonl. The labeling pass
# (Claude corrects what it is sure of, routes doubts to the owner) then works
# from that file; nothing here writes targets.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INBOX="$REPO/Data/corpus/inbox"
OUT="$REPO/Data/corpus/inbox-raws.jsonl"
MODEL="${VOXOL_ASR_MODEL_ROOT:-$HOME/Library/Application Support/VoxoL/Models/asr/7c35754d166cca382ad1e53e68b01e7c575f3a1d}"
CLI="$REPO/.build/release/voxol-asr-smoke"

mkdir -p "$INBOX"
[ -x "$CLI" ] || swift build -c release --product voxol-asr-smoke

shopt -s nullglob nocaseglob
files=("$INBOX"/*.{wav,mp3,m4a,aac,flac,ogg,mp4,mov,mkv,webm})
if [ ${#files[@]} -eq 0 ]; then
  echo "Déposez des fichiers audio/vidéo dans $INBOX puis relancez."
  exit 0
fi

for file in "${files[@]}"; do
  base="$(basename "$file")"
  id="inbox-$(shasum -a 256 "$file" | cut -c1-10)"
  if grep -q "\"$id\"" "$OUT" 2>/dev/null; then
    echo "[déjà fait] $base"
    continue
  fi
  wav="$(mktemp -t voxol-inbox).wav"
  # 16 kHz mono : le format exact de la capture de production.
  ffmpeg -y -loglevel error -i "$file" -ac 1 -ar 16000 -vn "$wav"
  echo "[transcription] $base"
  raw="$("$CLI" --model-root "$MODEL" "$wav" | tail -1)"
  rm -f "$wav"
  python3 - "$OUT" "$id" "$base" "$raw" <<'PY'
import json, sys
out, item_id, source, raw = sys.argv[1:5]
with open(out, "a", encoding="utf-8") as h:
    h.write(json.dumps({
        "id": item_id, "sourceFile": source, "language": "fr",
        "raw": raw.strip(),
    }, ensure_ascii=False) + "\n")
PY
done
echo
echo "Bruts prêts pour la passe de correction : $OUT"
