#!/usr/bin/env python3
"""Build VoxoL's self-contained NVIDIA GPU training launcher."""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import json
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = REPOSITORY_ROOT / "VoxoL_GPU_Train.sh"
NEMO_REVISION = "2381f42f6979449b5b99538f8f80135831009b51"
EMBEDDED_FILES = (
    "Scripts/resumable_dataset_download.py",
    "Scripts/prepare-parakeet-fleurs-finetune.py",
    "Scripts/prepare-fleurs-test-benchmark.py",
    "Scripts/prepare-mediaspeech-fr-benchmark.py",
    "Scripts/prepare-librispeech-test-benchmark.py",
    "Scripts/prepare-voxpopuli-fr-en-benchmark.py",
    "Tools/training/convert_nemo_manifest_to_benchmark.py",
    "Tools/training/freeze_asr_manifest.py",
    "Tools/training/run_voxol_nemo_finetune.py",
    "Tools/training/run_voxol_nemo_snapshot_diagnostics.py",
    "Tools/training/run_nemo_asr_benchmark.py",
    "Tools/training/score_asr_predictions.py",
    "Tools/training/run_voxol_gpu_pipeline.py",
    "Tools/training/run_voxol_snapshot_diagnostic_pipeline.py",
    "Tools/training/run_voxol_wispr_gpu_pipeline.py",
    "Tools/training/run_parakeet_lr_sweep.py",
    "Scripts/run-parakeet-lr-sweep.sh",
)


LAUNCHER_TEMPLATE = r"""#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

BUNDLE_VERSION="2026-08-03-gpu-bundle-v12"
NEMO_REVISION="@@NEMO_REVISION@@"
NUMBA_VERSION="0.61.2"
LLVMLITE_VERSION="0.44.0"
EMBEDDED_SOURCES_SHA256="@@PAYLOAD_SHA256@@"

HOURLY_PRICE="${VOXOL_GPU_HOURLY_USD:-0.35}"
BUDGET="${VOXOL_MAX_BUDGET_USD:-10}"
MAX_HOURS="${VOXOL_MAX_HOURS:-6}"
MAX_EPOCHS="${VOXOL_MAX_EPOCHS:-5}"
WORK_ROOT="${VOXOL_WORK_ROOT:-}"
EXPORT_DIR="${VOXOL_EXPORT_DIR:-}"
TORCH_INDEX_URL="${VOXOL_TORCH_INDEX_URL:-}"
TEACHER_DATASET="${VOXOL_TEACHER_DATASET:-}"
TEACHER_DATASET_SHA256="${VOXOL_TEACHER_DATASET_SHA256:-}"
RESEARCH_ARCHIVE="${VOXOL_RESEARCH_ARCHIVE:-}"
RESEARCH_ARCHIVE_SHA256="${VOXOL_RESEARCH_ARCHIVE_SHA256:-}"
SECONDARY_RESEARCH_ARCHIVE="${VOXOL_SECONDARY_RESEARCH_ARCHIVE:-}"
SECONDARY_RESEARCH_ARCHIVE_SHA256="${VOXOL_SECONDARY_RESEARCH_ARCHIVE_SHA256:-}"
DIAGNOSTIC_BATCH_SIZE="${VOXOL_DIAGNOSTIC_BATCH_SIZE:-}"
INSTALL_TORCH=1
AUTO_SHUTDOWN=0
ASSUME_YES=0
DRY_RUN=0
START_DELAY_SECONDS="${VOXOL_START_DELAY_SECONDS:-10}"

usage() {
  cat <<'USAGE'
VoxoL_GPU_Train.sh — entraînement et benchmark Parakeet autonome

Usage:
  bash VoxoL_GPU_Train.sh [options]

Options:
  --hourly-price USD   Prix horaire total affiché par le fournisseur (défaut: 0.35).
  --budget USD         Budget maximal accepté par le script (défaut: 10).
  --max-hours HOURS    Arrêt logiciel après cette durée totale (défaut: 6).
  --max-epochs COUNT   Nombre d'époques de fine-tuning (défaut: 5).
  --work-root PATH     Dossier persistant de travail et de reprise.
  --export-dir PATH    Copie l'archive finale vers un volume monté.
  --torch-index-url URL
                       Index PyTorch CUDA à utiliser si PyTorch n'est pas présent.
  --teacher-dataset PATH
                       Archive locale préparée depuis les labels Wispr raw.
  --teacher-dataset-sha256 SHA256
                       SHA-256 attendu de l'archive Wispr.
  --research-archive PATH
                       Archive du candidat 1 époque à diagnostiquer sans entraînement.
  --research-archive-sha256 SHA256
                       SHA-256 attendu de l'archive de recherche.
  --secondary-research-archive PATH
                       Archive du candidat 3 époques, utilisée comme diagnostic.
  --secondary-research-archive-sha256 SHA256
                       SHA-256 attendu de l'archive secondaire.
  --diagnostic-batch-size COUNT
                       Batch d'inférence de la grille post-hoc (auto: 4 ou 8).
  --no-install-torch   Refuse d'installer PyTorch si l'image GPU ne le fournit pas.
  --auto-shutdown      Éteint l'OS après la création de l'archive.
  --yes                Supprime le délai de sécurité avant démarrage.
  --dry-run            Affiche le coût et le plan sans toucher à la machine.
  --help               Affiche cette aide.

Le prix doit être celui de la machine entière, pas seulement celui du GPU. L'arrêt
du script ou de l'OS ne garantit pas que le fournisseur arrête sa facturation :
il faut arrêter/détruire l'instance dans son tableau de bord après récupération.
USAGE
}

die() {
  printf '\nERREUR: %s\n' "$*" >&2
  exit 1
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "Il manque une valeur après $1."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hourly-price)
      require_value "$@"
      HOURLY_PRICE="$2"
      shift 2
      ;;
    --budget)
      require_value "$@"
      BUDGET="$2"
      shift 2
      ;;
    --max-hours)
      require_value "$@"
      MAX_HOURS="$2"
      shift 2
      ;;
    --max-epochs)
      require_value "$@"
      MAX_EPOCHS="$2"
      shift 2
      ;;
    --work-root)
      require_value "$@"
      WORK_ROOT="$2"
      shift 2
      ;;
    --export-dir)
      require_value "$@"
      EXPORT_DIR="$2"
      shift 2
      ;;
    --torch-index-url)
      require_value "$@"
      TORCH_INDEX_URL="$2"
      shift 2
      ;;
    --teacher-dataset)
      require_value "$@"
      TEACHER_DATASET="$2"
      shift 2
      ;;
    --teacher-dataset-sha256)
      require_value "$@"
      TEACHER_DATASET_SHA256="$2"
      shift 2
      ;;
    --research-archive)
      require_value "$@"
      RESEARCH_ARCHIVE="$2"
      shift 2
      ;;
    --research-archive-sha256)
      require_value "$@"
      RESEARCH_ARCHIVE_SHA256="$2"
      shift 2
      ;;
    --secondary-research-archive)
      require_value "$@"
      SECONDARY_RESEARCH_ARCHIVE="$2"
      shift 2
      ;;
    --secondary-research-archive-sha256)
      require_value "$@"
      SECONDARY_RESEARCH_ARCHIVE_SHA256="$2"
      shift 2
      ;;
    --diagnostic-batch-size)
      require_value "$@"
      DIAGNOSTIC_BATCH_SIZE="$2"
      shift 2
      ;;
    --no-install-torch)
      INSTALL_TORCH=0
      shift
      ;;
    --auto-shutdown)
      AUTO_SHUTDOWN=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Option inconnue: $1"
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 est requis."
python3 - <<'PY' || die "Python 3.10 ou plus récent est requis."
import sys
if sys.version_info < (3, 10):
    raise SystemExit(1)
PY
[[ "$MAX_EPOCHS" =~ ^[1-9][0-9]*$ ]] \
  || die "--max-epochs doit être un entier strictement positif."
if [[ -n "$TEACHER_DATASET" || -n "$TEACHER_DATASET_SHA256" ]]; then
  [[ -n "$TEACHER_DATASET" && -n "$TEACHER_DATASET_SHA256" ]] \
    || die "--teacher-dataset et --teacher-dataset-sha256 doivent être fournis ensemble."
  [[ "$TEACHER_DATASET_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "--teacher-dataset-sha256 doit contenir 64 caractères hexadécimaux minuscules."
fi
if [[ -n "$RESEARCH_ARCHIVE" || -n "$RESEARCH_ARCHIVE_SHA256" ]]; then
  [[ -n "$RESEARCH_ARCHIVE" && -n "$RESEARCH_ARCHIVE_SHA256" ]] \
    || die "--research-archive et --research-archive-sha256 doivent être fournis ensemble."
  [[ "$RESEARCH_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "--research-archive-sha256 doit contenir 64 caractères hexadécimaux minuscules."
  [[ -n "$TEACHER_DATASET" ]] \
    || die "Le diagnostic exige aussi --teacher-dataset et son SHA-256."
fi
if [[ -n "$SECONDARY_RESEARCH_ARCHIVE" || -n "$SECONDARY_RESEARCH_ARCHIVE_SHA256" ]]; then
  [[ -n "$SECONDARY_RESEARCH_ARCHIVE" && -n "$SECONDARY_RESEARCH_ARCHIVE_SHA256" ]] \
    || die "--secondary-research-archive et son SHA-256 doivent être fournis ensemble."
  [[ "$SECONDARY_RESEARCH_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "--secondary-research-archive-sha256 doit contenir 64 caractères hexadécimaux minuscules."
  [[ -n "$RESEARCH_ARCHIVE" ]] \
    || die "L'archive secondaire exige le mode diagnostic principal."
fi
if [[ -n "$DIAGNOSTIC_BATCH_SIZE" ]]; then
  [[ "$DIAGNOSTIC_BATCH_SIZE" =~ ^[1-9][0-9]*$ ]] \
    || die "--diagnostic-batch-size doit être un entier strictement positif."
fi

MODE="FLEURS public"
if [[ -n "$RESEARCH_ARCHIVE" ]]; then
  MODE="Diagnostic post-hoc sans entraînement"
elif [[ -n "$TEACHER_DATASET" ]]; then
  MODE="Wispr teacher + FLEURS replay"
fi

if [[ -z "$WORK_ROOT" ]]; then
  if [[ -d /workspace && -w /workspace ]]; then
    WORK_ROOT="/workspace/voxol-parakeet"
  else
    [[ -n "${HOME:-}" ]] || die "HOME est absent; fournissez --work-root."
    WORK_ROOT="$HOME/voxol-parakeet"
  fi
fi

case "$WORK_ROOT" in
  /|"${HOME:-/__voxol_no_home__}")
    die "--work-root doit désigner un sous-dossier dédié, jamais / ou HOME."
    ;;
esac

COST_REPORT="$(
  python3 - "$HOURLY_PRICE" "$BUDGET" "$MAX_HOURS" "$MAX_EPOCHS" <<'PY'
from decimal import Decimal, InvalidOperation
import sys

names = ("hourly price", "budget", "maximum hours", "epochs")
try:
    price, budget, hours, epochs = map(Decimal, sys.argv[1:])
except InvalidOperation as error:
    raise SystemExit(f"Invalid numeric option: {error}")
if any(value <= 0 for value in (price, budget, hours, epochs)):
    raise SystemExit("Price, budget, duration and epochs must be positive.")
if epochs != epochs.to_integral_value():
    raise SystemExit("Epoch count must be an integer.")
maximum = price * hours
if maximum > budget:
    raise SystemExit(
        f"Refusing to start: ${maximum:.2f} exceeds the ${budget:.2f} budget."
    )
print(f"{maximum:.2f}")
PY
)" || die "Les paramètres de coût sont invalides."

printf '%s\n' \
  "VoxoL GPU bundle: $BUNDLE_VERSION" \
  "Dossier persistant: $WORK_ROOT" \
  "Prix horaire déclaré: \$$HOURLY_PRICE" \
  "Durée maximale: $MAX_HOURS h" \
  "Coût compute maximal déclaré: \$$COST_REPORT (budget: \$$BUDGET)" \
  "$([[ -n "$RESEARCH_ARCHIVE" ]] && printf 'Analyses: parité A/A + validation exacte + grille de 18 compositions' || [[ -n "$TEACHER_DATASET" ]] && printf 'Recette: une époque effective bornée, replay FLEURS cible 25 %%, sélection multi-checkpoints, gates FLEURS/MediaSpeech/LibriSpeech' || printf 'Époques: %s' "$MAX_EPOCHS")" \
  "Mode: $MODE" \
  "Sortie: une archive ZIP vérifiée avec résultats, logs et décision"

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%s\n' \
    "DRY RUN OK — aucune installation, aucun téléchargement et aucun entraînement."
  exit 0
fi

if [[ -n "$TEACHER_DATASET" ]]; then
  [[ -s "$TEACHER_DATASET" ]] \
    || die "Archive Wispr absente ou vide: $TEACHER_DATASET"
fi
if [[ -n "$RESEARCH_ARCHIVE" ]]; then
  [[ -s "$RESEARCH_ARCHIVE" ]] \
    || die "Archive de recherche absente ou vide: $RESEARCH_ARCHIVE"
fi
if [[ -n "$SECONDARY_RESEARCH_ARCHIVE" ]]; then
  [[ -s "$SECONDARY_RESEARCH_ARCHIVE" ]] \
    || die "Archive de recherche secondaire absente ou vide: $SECONDARY_RESEARCH_ARCHIVE"
fi
[[ "$(uname -s)" == "Linux" ]] || die "Ce lanceur exige Linux."
command -v nvidia-smi >/dev/null 2>&1 \
  || die "Aucun pilote NVIDIA visible. Choisissez une image GPU NVIDIA/PyTorch."
command -v timeout >/dev/null 2>&1 \
  || die "La commande timeout est requise pour faire respecter la durée maximale."

GPU_LINE="$(
  nvidia-smi \
    --query-gpu=name,memory.total,driver_version \
    --format=csv,noheader,nounits \
    | sed -n '1p'
)"
[[ -n "$GPU_LINE" ]] || die "nvidia-smi ne retourne aucun GPU."
GPU_MEMORY_MIB="$(printf '%s' "$GPU_LINE" | awk -F',' '{gsub(/ /, "", $2); print int($2)}')"
[[ "$GPU_MEMORY_MIB" -ge 14336 ]] \
  || die "Le GPU n'a que ${GPU_MEMORY_MIB} MiB de VRAM; 14 GiB sont requis."
if [[ -n "$TEACHER_DATASET" && -z "$RESEARCH_ARCHIVE" && "$GPU_MEMORY_MIB" -lt 20480 ]]; then
  die "Le corpus Wispr en segments de 30 s exige au moins 20 GiB de VRAM."
fi
if [[ -z "$DIAGNOSTIC_BATCH_SIZE" ]]; then
  if [[ "$GPU_MEMORY_MIB" -ge 20480 ]]; then
    DIAGNOSTIC_BATCH_SIZE=8
  else
    DIAGNOSTIC_BATCH_SIZE=4
  fi
fi

mkdir -p "$WORK_ROOT"
AVAILABLE_KIB="$(df -Pk "$WORK_ROOT" | awk 'NR==2 {print $4}')"
MINIMUM_KIB=$((35 * 1024 * 1024))
[[ "$AVAILABLE_KIB" -ge "$MINIMUM_KIB" ]] \
  || die "Il faut au moins 35 GiB libres dans $WORK_ROOT."

TOTAL_MEMORY_KIB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
[[ "$TOTAL_MEMORY_KIB" -ge $((12 * 1024 * 1024)) ]] \
  || die "La VM doit avoir au moins 12 GiB de RAM système."
if [[ "$TOTAL_MEMORY_KIB" -lt $((24 * 1024 * 1024)) ]]; then
  printf '%s\n' "AVERTISSEMENT: moins de 24 GiB de RAM; le profil restera conservateur."
fi

printf '%s\n' "GPU détecté: $GPU_LINE"
if [[ "$ASSUME_YES" -eq 0 ]]; then
  printf '%s\n' \
    "Le compteur démarre maintenant. Ctrl-C annule; lancement dans ${START_DELAY_SECONDS}s."
  sleep "$START_DELAY_SECONDS"
fi

RUN_STARTED_EPOCH="$(date +%s)"
DEADLINE_EPOCH="$(
  python3 - "$RUN_STARTED_EPOCH" "$MAX_HOURS" <<'PY'
import sys
print(int(float(sys.argv[1]) + float(sys.argv[2]) * 3600))
PY
)"
export VOXOL_RUN_STARTED_EPOCH="$RUN_STARTED_EPOCH"

remaining_seconds() {
  local now remaining
  now="$(date +%s)"
  remaining=$((DEADLINE_EPOCH - now))
  [[ "$remaining" -gt 0 ]] || die "Durée maximale atteinte."
  printf '%s\n' "$remaining"
}

timed() {
  local remaining return_code
  remaining="$(remaining_seconds)"
  return_code=0
  timeout --signal=TERM --kill-after=120 "${remaining}s" "$@" || return_code=$?
  if [[ "$return_code" -eq 124 || "$return_code" -eq 137 ]]; then
    die "Durée maximale atteinte pendant: $*"
  fi
  [[ "$return_code" -eq 0 ]] || return "$return_code"
}

RESULT_ROOT="$WORK_ROOT/results"
LOG_ROOT="$RESULT_ROOT/logs"
if [[ -n "${VOXOL_RUNTIME_ROOT:-}" ]]; then
  RUNTIME_ROOT="$VOXOL_RUNTIME_ROOT"
elif [[ -d /workspace && -w /workspace ]]; then
  RUNTIME_ROOT="/workspace/voxol-runtime-v7"
else
  RUNTIME_ROOT="$WORK_ROOT/runtime"
fi
SOURCE_ROOT="$RUNTIME_ROOT/voxol-sources"
NEMO_ROOT="$RUNTIME_ROOT/NeMo"
VENV_ROOT="$RUNTIME_ROOT/venv"
mkdir -p \
  "$LOG_ROOT" \
  "$SOURCE_ROOT" \
  "$RUNTIME_ROOT/cache/pip" \
  "$RUNTIME_ROOT/cache/huggingface" \
  "$RUNTIME_ROOT/cache/datasets"
RUN_LOG="$LOG_ROOT/launcher-$(date -u +%Y%m%dT%H%M%SZ).log"
export HF_HOME="${HF_HOME:-$RUNTIME_ROOT/cache/huggingface}"
export VOXOL_DATASET_CACHE_ROOT="${VOXOL_DATASET_CACHE_ROOT:-$RUNTIME_ROOT/cache/datasets}"
export PIP_CACHE_DIR="$RUNTIME_ROOT/cache/pip"
export TOKENIZERS_PARALLELISM=false
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export NUMBA_CUDA_USE_NVIDIA_BINDING=1
if [[ -d /workspace && -w /root ]]; then
  export VOXOL_FULL_CHECKPOINT_ROOT="${VOXOL_FULL_CHECKPOINT_ROOT:-/root/voxol-checkpoints}"
fi
exec > >(tee -a "$RUN_LOG") 2>&1

write_launcher_status() {
  local state="$1" stage="$2"
  python3 - "$RESULT_ROOT/status.json" "$state" "$stage" \
    "$RUN_STARTED_EPOCH" "$HOURLY_PRICE" <<'PY'
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import time

destination = Path(sys.argv[1])
elapsed_hours = max(0.0, (time.time() - float(sys.argv[4])) / 3600)
payload = {
    "schemaVersion": 1,
    "state": sys.argv[2],
    "currentStage": sys.argv[3],
    "elapsedHours": round(elapsed_hours, 4),
    "estimatedComputeCostUSD": round(elapsed_hours * float(sys.argv[5]), 4),
    "updatedAt": datetime.now(timezone.utc).isoformat(),
}
temporary = destination.with_suffix(".json.partial")
temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.replace(destination)
PY
}

recovery_archive() {
  local recovery_python
  if [[ -x "$VENV_ROOT/bin/python" ]]; then
    recovery_python="$VENV_ROOT/bin/python"
  else
    recovery_python="python3"
  fi
  "$recovery_python" - "$WORK_ROOT" <<'PY' || true
from datetime import datetime, timezone
from pathlib import Path
import zipfile
import sys

root = Path(sys.argv[1]).resolve()
latest = root / "results" / "latest-export.txt"
if latest.is_file():
    candidate = Path(latest.read_text(encoding="utf-8").strip())
    if candidate.is_file():
        print(candidate)
        raise SystemExit

exports = root / "exports"
exports.mkdir(parents=True, exist_ok=True)
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
destination = exports / f"voxol-parakeet-recovery-{stamp}.zip"
temporary = destination.with_suffix(".zip.partial")
with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
    for relative_root in ("results", "candidates", "experiments", "diagnostics"):
        source_root = root / relative_root
        if not source_root.is_dir():
            continue
        for path in sorted(source_root.rglob("*")):
            if not path.is_file() or path.suffix == ".partial":
                continue
            if relative_root == "experiments" and not path.name.endswith(".delta.pt"):
                continue
            archive.write(path, f"VoxoL-Parakeet/{path.relative_to(root)}")
temporary.replace(destination)
latest.parent.mkdir(parents=True, exist_ok=True)
latest.write_text(str(destination) + "\n", encoding="utf-8")
print(destination)
PY
}

FINALIZED=0
finalize() {
  local return_code="$?"
  trap - EXIT
  if [[ "$FINALIZED" -eq 0 ]]; then
    recovery_archive
  fi
  local archive="" export_path=""
  if [[ -s "$RESULT_ROOT/latest-export.txt" ]]; then
    archive="$(tail -n 1 "$RESULT_ROOT/latest-export.txt")"
  fi
  if [[ -n "$archive" && -f "$archive" ]]; then
    if [[ -n "$EXPORT_DIR" ]]; then
      mkdir -p "$EXPORT_DIR"
      export_path="$EXPORT_DIR/$(basename "$archive")"
      if [[ "$archive" != "$export_path" ]]; then
        cp "$archive" "$export_path"
      fi
      archive="$export_path"
    fi
    local host_ip host_user ssh_port
    host_ip="${RUNPOD_PUBLIC_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    host_user="$(id -un)"
    ssh_port="${RUNPOD_TCP_PORT_22:-${SSH_PORT:-22}}"
    printf '\n%s\n' \
      "ARCHIVE À RÉCUPÉRER: $archive" \
      "Depuis ton Mac (si SSH est actif):" \
      "scp -P $ssh_port \"$host_user@$host_ip:$archive\" ." \
      "Ensuite, arrête ou détruis l'instance dans le tableau de bord du fournisseur."
  else
    printf '\n%s\n' \
      "Aucune archive n'a pu être créée. Conserve la VM et inspecte: $RUN_LOG" >&2
  fi
  if [[ "$AUTO_SHUTDOWN" -eq 1 ]]; then
    printf '%s\n' \
      "Extinction de l'OS demandée. Vérifie quand même la facturation fournisseur."
    if [[ "$EUID" -eq 0 ]]; then
      shutdown -h now || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo shutdown -h now || true
    fi
  fi
  exit "$return_code"
}
trap finalize EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

printf '\n%s\n' "[1/8] Extraction et vérification des sources VoxoL"
write_launcher_status "initializing" "1/8 — vérification des sources"
python3 - "$SOURCE_ROOT" "$EMBEDDED_SOURCES_SHA256" <<'PY'
import base64
import gzip
import hashlib
import json
from pathlib import Path
import sys

encoded_payload = '''@@PAYLOAD@@'''
payload = base64.b64decode(
    "".join(encoded_payload.split()).encode("ascii"),
    validate=True,
)
expected = sys.argv[2]
actual = hashlib.sha256(payload).hexdigest()
if actual != expected:
    raise SystemExit(f"Embedded source digest mismatch: {actual} != {expected}")
sources = json.loads(gzip.decompress(payload).decode("utf-8"))
root = Path(sys.argv[1]).resolve()
for relative_path, source in sources.items():
    relative = Path(relative_path)
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit(f"Unsafe embedded path: {relative_path}")
    destination = root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".partial")
    temporary.write_text(source, encoding="utf-8")
    if relative.suffix == ".sh":
        temporary.chmod(0o755)
    temporary.replace(destination)
print(f"Sources verified: {len(sources)} files, payload sha256={actual}")
PY

printf '\n%s\n' "[2/8] Dépendances système"
write_launcher_status "initializing" "2/8 — dépendances système"
PACKAGES=(git ffmpeg libsndfile1 python3-venv)
MISSING_PACKAGES=()
if command -v dpkg-query >/dev/null 2>&1; then
  for package in "${PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null \
      | grep -q "ok installed" || MISSING_PACKAGES+=("$package")
  done
else
  MISSING_PACKAGES=("${PACKAGES[@]}")
fi
if [[ "${#MISSING_PACKAGES[@]}" -gt 0 ]]; then
  command -v apt-get >/dev/null 2>&1 \
    || die "apt-get est requis pour installer: ${MISSING_PACKAGES[*]}"
  if [[ "$EUID" -eq 0 ]]; then
    timed apt-get -qq update
    timed apt-get -qq install -y "${MISSING_PACKAGES[@]}"
  elif command -v sudo >/dev/null 2>&1; then
    timed sudo apt-get -qq update
    timed sudo apt-get -qq install -y "${MISSING_PACKAGES[@]}"
  else
    die "Droits root/sudo requis pour installer: ${MISSING_PACKAGES[*]}"
  fi
fi

printf '\n%s\n' "[3/8] Environnement Python et CUDA"
write_launcher_status "initializing" "3/8 — environnement Python et CUDA"
timed python3 -m venv --system-site-packages "$VENV_ROOT"
PYTHON="$VENV_ROOT/bin/python"
timed "$PYTHON" -m pip install -q --upgrade pip setuptools wheel

if ! "$PYTHON" - <<'PY'
import torch
if not torch.cuda.is_available():
    raise SystemExit(1)
print(f"PyTorch {torch.__version__}; CUDA {torch.version.cuda}; GPU {torch.cuda.get_device_name(0)}")
PY
then
  [[ "$INSTALL_TORCH" -eq 1 ]] \
    || die "PyTorch CUDA manque dans l'image et --no-install-torch a été demandé."
  printf '%s\n' "PyTorch CUDA absent; installation automatique."
  TORCH_COMMAND=("$PYTHON" -m pip install --upgrade --force-reinstall torch)
  if [[ -n "$TORCH_INDEX_URL" ]]; then
    TORCH_COMMAND+=(--index-url "$TORCH_INDEX_URL")
  fi
  timed "${TORCH_COMMAND[@]}"
fi
"$PYTHON" - <<'PY' || die "Le build PyTorch installé ne voit toujours pas CUDA."
import torch
if not torch.cuda.is_available():
    raise SystemExit(1)
memory = torch.cuda.get_device_properties(0).total_memory / (1024 ** 3)
if memory < 14:
    raise SystemExit(f"Only {memory:.1f} GiB VRAM is visible.")
print(f"PyTorch CUDA prêt: {torch.__version__}, {torch.cuda.get_device_name(0)}, {memory:.1f} GiB")
PY

printf '\n%s\n' "[4/8] Checkout NeMo épinglé"
write_launcher_status "initializing" "4/8 — checkout NeMo épinglé"
if [[ ! -d "$NEMO_ROOT/.git" ]]; then
  mkdir -p "$NEMO_ROOT"
  timed git -C "$NEMO_ROOT" init -q
  timed git -C "$NEMO_ROOT" remote add origin https://github.com/NVIDIA-NeMo/NeMo.git
fi
if git -C "$NEMO_ROOT" remote get-url origin >/dev/null 2>&1; then
  timed git -C "$NEMO_ROOT" remote set-url origin https://github.com/NVIDIA-NeMo/NeMo.git
else
  timed git -C "$NEMO_ROOT" remote add origin https://github.com/NVIDIA-NeMo/NeMo.git
fi
ACTUAL_NEMO_REVISION="$(git -C "$NEMO_ROOT" rev-parse HEAD 2>/dev/null || true)"
if [[ "$ACTUAL_NEMO_REVISION" != "$NEMO_REVISION" ]]; then
  [[ -z "$(git -C "$NEMO_ROOT" status --porcelain 2>/dev/null)" ]] \
    || die "Le checkout NeMo dédié contient des modifications; utilise un autre --work-root."
  timed git -C "$NEMO_ROOT" fetch --depth=1 origin "$NEMO_REVISION"
  timed git -C "$NEMO_ROOT" checkout --detach FETCH_HEAD
fi
ACTUAL_NEMO_REVISION="$(git -C "$NEMO_ROOT" rev-parse HEAD)"
[[ "$ACTUAL_NEMO_REVISION" == "$NEMO_REVISION" ]] \
  || die "Révision NeMo incorrecte: $ACTUAL_NEMO_REVISION"

printf '\n%s\n' "[5/8] Installation NeMo ASR"
write_launcher_status "initializing" "5/8 — installation NeMo ASR"
NEMO_MARKER="$VENV_ROOT/.voxol-nemo-revision"
NEMO_RUNTIME_MARKER="$NEMO_REVISION|$NUMBA_VERSION|$LLVMLITE_VERSION"
NEMO_READY=0
if [[ -s "$NEMO_MARKER" ]] \
  && [[ "$(cat "$NEMO_MARKER")" == "$NEMO_RUNTIME_MARKER" ]]; then
  if PYTHONPATH="$NEMO_ROOT" "$PYTHON" -c "import nemo; import nemo.collections.asr"; then
    NEMO_READY=1
  fi
fi
if [[ "$NEMO_READY" -eq 0 ]]; then
  timed "$PYTHON" -m pip install -q -e "$NEMO_ROOT[asr]" \
    "numba==$NUMBA_VERSION" "llvmlite==$LLVMLITE_VERSION"
  printf '%s\n' "$NEMO_RUNTIME_MARKER" > "$NEMO_MARKER"
fi
PYTHONPATH="$NEMO_ROOT" "$PYTHON" - <<'PY' \
  || die "NeMo ASR ne s'importe pas après installation."
import nemo
import nemo.collections.asr
import llvmlite
import numba
print(
    f"NeMo prêt: {getattr(nemo, '__version__', 'unknown')}; "
    f"Numba {numba.__version__}; llvmlite {llvmlite.__version__}"
)
PY

printf '\n%s\n' "[6/8] Lancement du pipeline avec progression en direct"
write_launcher_status "running" "6/8 — préparation des données et entraînement"
export PYTHONPATH="$SOURCE_ROOT:$NEMO_ROOT${PYTHONPATH:+:$PYTHONPATH}"
PIPELINE_SCRIPT="$SOURCE_ROOT/Tools/training/run_voxol_gpu_pipeline.py"
PIPELINE_ARGUMENTS=(
  --source-root "$SOURCE_ROOT"
  --work-root "$WORK_ROOT"
  --hourly-price "$HOURLY_PRICE"
  --budget "$BUDGET"
  --max-hours "$MAX_HOURS"
  --max-epochs "$MAX_EPOCHS"
)
if [[ -n "$TEACHER_DATASET" ]]; then
  PIPELINE_SCRIPT="$SOURCE_ROOT/Tools/training/run_voxol_wispr_gpu_pipeline.py"
  PIPELINE_ARGUMENTS+=(
    --teacher-dataset "$TEACHER_DATASET"
    --teacher-dataset-sha256 "$TEACHER_DATASET_SHA256"
  )
fi
if [[ -n "$RESEARCH_ARCHIVE" ]]; then
  PIPELINE_SCRIPT="$SOURCE_ROOT/Tools/training/run_voxol_snapshot_diagnostic_pipeline.py"
  PIPELINE_ARGUMENTS=(
    --source-root "$SOURCE_ROOT"
    --work-root "$WORK_ROOT"
    --teacher-dataset "$TEACHER_DATASET"
    --teacher-dataset-sha256 "$TEACHER_DATASET_SHA256"
    --research-archive "$RESEARCH_ARCHIVE"
    --research-archive-sha256 "$RESEARCH_ARCHIVE_SHA256"
    --batch-size "$DIAGNOSTIC_BATCH_SIZE"
  )
  if [[ -n "$SECONDARY_RESEARCH_ARCHIVE" ]]; then
    PIPELINE_ARGUMENTS+=(
      --secondary-research-archive "$SECONDARY_RESEARCH_ARCHIVE"
      --secondary-research-archive-sha256 "$SECONDARY_RESEARCH_ARCHIVE_SHA256"
    )
  fi
fi
timed "$PYTHON" "$PIPELINE_SCRIPT" "${PIPELINE_ARGUMENTS[@]}"

printf '\n%s\n' "[7/8] Vérification de l'archive"
[[ -s "$RESULT_ROOT/latest-export.txt" ]] \
  || die "Le pipeline n'a pas écrit latest-export.txt."
FINAL_ARCHIVE="$(tail -n 1 "$RESULT_ROOT/latest-export.txt")"
[[ -s "$FINAL_ARCHIVE" ]] || die "Archive finale absente: $FINAL_ARCHIVE"
"$PYTHON" - "$FINAL_ARCHIVE" "$MODE" <<'PY'
from pathlib import Path
import sys
import zipfile

archive = Path(sys.argv[1])
mode = sys.argv[2]
with zipfile.ZipFile(archive) as source:
    bad = source.testzip()
    if bad is not None:
        raise SystemExit(f"Corrupt ZIP member: {bad}")
    names = set(source.namelist())
    if mode == "Diagnostic post-hoc sans entraînement":
        required = {
            "VoxoL-Diagnostics/results/diagnostic-report.json",
            "VoxoL-Diagnostics/diagnostic-config.json",
            "VoxoL-Diagnostics/SHA256SUMS.txt",
        }
    else:
        required = {
            "VoxoL-Parakeet/results/status.json",
            "VoxoL-Parakeet/results/source-gate.json",
            "VoxoL-Parakeet/results/quantization-plan.json",
            "VoxoL-Parakeet/SHA256SUMS.txt",
        }
    missing = sorted(required - names)
    if missing:
        raise SystemExit(f"Archive is missing: {missing}")
print(f"Archive vérifiée: {archive} ({archive.stat().st_size / (1024 ** 2):.1f} MiB)")
PY

printf '\n%s\n' "[8/8] Terminé"
FINALIZED=1
if [[ "$MODE" == "Diagnostic post-hoc sans entraînement" ]]; then
  printf '%s\n' "Le diagnostic est dans: $WORK_ROOT/diagnostics/results/diagnostic-report.json"
else
  printf '%s\n' "Le verdict est dans: $RESULT_ROOT/source-gate.json"
fi
"""


def embedded_payload() -> tuple[str, str]:
    sources = {
        relative_path: (REPOSITORY_ROOT / relative_path).read_text(encoding="utf-8")
        for relative_path in EMBEDDED_FILES
    }
    serialized = json.dumps(
        sources,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    compressed = gzip.compress(serialized, compresslevel=9, mtime=0)
    digest = hashlib.sha256(compressed).hexdigest()
    encoded = base64.b64encode(compressed).decode("ascii")
    wrapped = "\n".join(
        encoded[offset : offset + 100] for offset in range(0, len(encoded), 100)
    )
    return wrapped, digest


def rendered_launcher() -> str:
    payload, digest = embedded_payload()
    return (
        LAUNCHER_TEMPLATE.replace("@@NEMO_REVISION@@", NEMO_REVISION)
        .replace("@@PAYLOAD_SHA256@@", digest)
        .replace("@@PAYLOAD@@", payload)
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    rendered = rendered_launcher()
    if arguments.check:
        if not OUTPUT_PATH.is_file():
            raise SystemExit(f"Generated GPU launcher is missing: {OUTPUT_PATH}")
        if OUTPUT_PATH.read_text(encoding="utf-8") != rendered:
            raise SystemExit(f"Generated GPU launcher is stale: {OUTPUT_PATH}")
        if not OUTPUT_PATH.stat().st_mode & 0o100:
            raise SystemExit(f"Generated GPU launcher is not executable: {OUTPUT_PATH}")
        print(f"GPU launcher is current: {OUTPUT_PATH}")
        return
    OUTPUT_PATH.write_text(rendered, encoding="utf-8")
    OUTPUT_PATH.chmod(0o755)
    print(OUTPUT_PATH)


if __name__ == "__main__":
    main()
