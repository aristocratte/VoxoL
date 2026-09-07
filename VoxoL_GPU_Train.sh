#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

BUNDLE_VERSION="2026-08-03-gpu-bundle-v12"
NEMO_REVISION="2381f42f6979449b5b99538f8f80135831009b51"
NUMBA_VERSION="0.61.2"
LLVMLITE_VERSION="0.44.0"
EMBEDDED_SOURCES_SHA256="5bc868f390b2394400efadd67d84d50e697c5b3470e368bd5f34785d7dd0ca03"

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

encoded_payload = '''H4sIAAAAAAAC/+y9iXYbyZEu/CpljT0CugEQC1e04TNsid2tsbYhqfbYJH+cAlAgYYEoGAWIYnNwzn2I+xJ+Dr/JfZI/ltwzq1Cg
6G7PjD0ei6jKzMolMjIyli8enp0NF5P5MtuZL5J5vEjq42myWmT1ZZIt64NkNry5jRcfG/P7Z91n//KrnVW22BlMZjvJ7FM0v1/e
pLPO5ezyGf7fe24gWt4k0TC9nU+TZRLNJ7NZMoq+e33y4fQs+m6BDUbxbBSdzK6nk+wmwu9E2Xw6WWYNbgfam40X6W3U749Xy9Ui
6fejye08XSyh4ixdxstJOsuwlHy6uIYPZ4l6MMw+qb9v4uxmOhmo33/OUl0zzcSn5vESS8nvvIefqlB2s1pOpurnMl6MJ9PE+P4i
yVa38WCa9EfxMs6SZX+U3s2maTzCQpezl8fnx2cn5/3Tkx9fnb169zbqRZfPDpqDQTs53B0cHewPDpKj/WYcHx6NW8P93cOkeTTc
OxofHu2ORjgfL969/e7V9x9Oj8+h9hlUf7icRfCfy2fJrL/KLp915RN+Oo1n16v4OsEXWIZm+vJZzSwTL4Y3k09JP7uJ23v7WLKi
X3OR0dGwnXQOBrutOB6OdluDYfuws7e3Gzfjw/Zgbxc63tk/PDxo7h4dHOwmw0H7sHU0GsZxvLcXd7BR3WI1+PHBPSw/frt9eNQ/
3Gv1oZZVcJl9Kurhwe6wubvf7hx1DnZHSTLYb47j/c64vXc4PmoedA4Pm0eduNMeQJ86rd3m0f7e+KCZjJt7w4Oj8cEwDvVwXZOT
O170x4sNkzsmin7E3LY7+0fNpNVsjzsHOKmjFszo7nDUHo9bycF+sjtORskApnavM2wODtoHe624NTgY7rUOh2Mmi5Jz29k96jc7
+/3m3t42c7s3au6POp3DQXu3nTSbB4f74+G41R7uDo/azebh4GjcOToa7cV7w8OD9vCoBQt/1Nw7aCdQ8mjYHOXN7Zo3xSgZR1m6
WgyT/moxrUzTYTxNulG2XNRgQ01hk8MYcFvSs2pU/x3+2+V2FgnwhZnZ58tnN8vlPOvu7Nysrq8ns+txPEwaw3RHbMls5zpNr6fJ
DrO3Hdiz6fRTsmP2cnz57MHdq2tqYOeB+7feebD6tpbVq3pQcu+LzpkDk513RydeJJ/nyXCZjMSqmK9GwCUnM+J8XeJObhVa7W40
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
l6zmsh8rpHvjuWmrAD42nQwnbrwJfafGYR5VP0aMzdVcETqjVigcoKxeX8hKRnAjKl4o95IaPJmlMtvYg49kN7b6olnxKkebZMUE
01pFcrKoiw+6b2vlwELrquI9HrumqIPUCAoje21kwLEKvDVDtFUSzdyguUootpAmWAfE2EXYD6jpamO/dgJ5RKiroA4TgsCOvsuL
utOOAMjX6g9cRByGPLOC8YkhEHq8H0otXI6854ptYfyoYeTmGdCB09r5gy1Nqwz93UR8TDcaAC+G+ZUuV4VJLsh304JRSGZ2pLOX
ARJ/5KV/1AMmpxp25QtkJWFgeGwps4KbWoE4XuHKgoVl0NXGKH6M++2x5yB5SVWwtom9Fd/1rTRCbsgvx5/WvOc630+16nXRbnWT
ycQIuOUwW+oKiJgPehaLUhoKL2NrGCqW1u6K01dNT563jtcoeg/FgyydrpZ+prdwIkxNxlbf/KZVUtVlWtF9+nlSZR7TlE8o61kG
/BDlHXzEAtiGVSibMjPxwWPKTo7tuM+x6TbbrvmVHBQMUZHADZJZCXp8ucJjDrY0fKp4Drrwjpt3iBI+xAAi/Na0iHPu0CKW7AdV
GllDt9hPihlusZ3UydkLiD0b5jo/6jPooyyCLnmGgu6zVjxoiGSKY0OdcL/8kN6aFVab05QZguhExhIuM/p2cWPmAZbXmo4cHCWf
kmk6vzXRI/KDTuXfYedtJ7BU3LfU0IKVvNjZUrV0PKMzAIwn5dM/GdWRG9RRSgiHw5aLZ7VjSAuTw6qg1+JSpeNd7VhXR8RAWyIK
GRYlyNI1FjyCy7/Ox5SvWn6rHGdW4KMFm/3kdr6855uhvBN2rc2utvc8vif3AydaJjfKJBhMY9L2kwa7BONo1p6kuK13nVl1I4A5
T9DPEbsiZGjxxb9zhioihi8O+vyCBhTR1JlBblNXiyNWB0onmqJNWzf4zPbpsN6glVlaqTU+XhaRnwHveMMerb6VPS6plN6n9jXK
DvmiRdXZzgryFG0olLOjdQEtk+qW7EBbQ5IO5VvRBR0OGgpJMfbjA3OFFzLVN2KYiMm5UAzjqrr2tuRjglQc1R16Pv2ELGChFHdl
dHXfUbUoNrRwSlO3yoRjQnR2h+Yz9ULoAvD+hi4RT4T+j1EaaNCQleRv2ETwvz+RcewL1Hp0zY9n6QxPUgHGog8g76JNPM2MdVB1
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'''
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
