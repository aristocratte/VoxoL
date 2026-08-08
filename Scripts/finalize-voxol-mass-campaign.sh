#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ssd_root="/Volumes/0_Oueillez"
campaign_root="$ssd_root/VoxoL-Data-Campaign-v2"
old_dataset="$ssd_root/wispr-data/transcripts/dataset"
new_dataset="$campaign_root/corpus/transcripts/dataset"
base_split_report="$ssd_root/wispr-data/prepared/parakeet-wispr-v2-20260801/split-report.json"
snapshot="${VOXOL_MASS_SNAPSHOT:-20260803}"
output_root="$campaign_root/prepared/parakeet-wispr-mass-v3-$snapshot"
archive="$campaign_root/prepared/voxol-wispr-asr-mass-v3-$snapshot.tar.gz"
handoff_root="$campaign_root/runpod-ready"

for required in \
  "$old_dataset/all-manifest.jsonl" \
  "$new_dataset/all-manifest.jsonl" \
  "$new_dataset/dataset-summary.json" \
  "$base_split_report"; do
  [[ -s "$required" ]] || {
    printf 'Missing campaign prerequisite: %s\n' "$required" >&2
    exit 1
  }
done
if pgrep -f '/Users/aris/Documents/wispr/wispr-transcribe.sh' >/dev/null 2>&1; then
  printf 'Wispr transcription is still active; finalization must wait.\n' >&2
  exit 1
fi

mkdir -p "$output_root" "$handoff_root/Scripts"
python3 "$repo_root/Tools/training/prepare_wispr_teacher_asr.py" \
  --input "$old_dataset/all-manifest.jsonl" \
  --dataset-root "$old_dataset" \
  --additional-corpus "$new_dataset/all-manifest.jsonl" "$new_dataset" \
  --base-split-report "$base_split_report" \
  --freeze-timestamp "2026-08-03T00:00:00Z" \
  --output-root "$output_root" \
  --archive "$archive"

archive_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
cp "$repo_root/VoxoL_GPU_Train.sh" "$handoff_root/VoxoL_GPU_Train.sh"
cp "$repo_root/Scripts/launch-voxol-runpod-training.sh" "$handoff_root/Scripts/launch-voxol-runpod-training.sh"
cp "$repo_root/Scripts/launch-voxol-runpod-mass-training.sh" "$handoff_root/Scripts/launch-voxol-runpod-mass-training.sh"
bundle="$handoff_root/VoxoL_GPU_Train.sh"
bundle_sha256="$(shasum -a 256 "$bundle" | awk '{print $1}')"
python3 - \
  "$archive" \
  "$archive_sha256" \
  "$output_root/split-report.json" \
  "$handoff_root/runpod-ready.json" \
  "$handoff_root/Scripts/launch-voxol-runpod-mass-training.sh" \
  "$bundle" \
  "$bundle_sha256" <<'PY'
import json
from pathlib import Path
import sys

archive = Path(sys.argv[1])
digest = sys.argv[2]
split_report = Path(sys.argv[3])
output = Path(sys.argv[4])
launcher = Path(sys.argv[5])
bundle = Path(sys.argv[6])
bundle_digest = sys.argv[7]
report = json.loads(split_report.read_text(encoding="utf-8"))
payload = {
    "schema_version": "voxol-runpod-ready-v2",
    "teacher_archive": str(archive),
    "teacher_archive_bytes": archive.stat().st_size,
    "teacher_archive_sha256": digest,
    "included_item_count": report["filter"]["includedItemCount"],
    "excluded_item_count": report["filter"]["excludedItemCount"],
    "splits": report["splits"],
    "launcher": str(launcher),
    "gpu_bundle": str(bundle),
    "gpu_bundle_bytes": bundle.stat().st_size,
    "gpu_bundle_sha256": bundle_digest,
    "quick_start": f"{launcher} RUNPOD_HOST RUNPOD_PORT root",
    "source_gate": "Train as a challenger; promote only after frozen benchmark and Core ML parity gates.",
}
output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(payload, indent=2, sort_keys=True))
PY

printf 'RUNPOD_TEACHER_ARCHIVE=%s\n' "$archive"
printf 'RUNPOD_TEACHER_SHA256=%s\n' "$archive_sha256"
printf 'RUNPOD_GPU_BUNDLE_SHA256=%s\n' "$bundle_sha256"
