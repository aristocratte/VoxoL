#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

BUNDLE_VERSION="2026-08-03-gpu-bundle-v12"
NEMO_REVISION="2381f42f6979449b5b99538f8f80135831009b51"
NUMBA_VERSION="0.61.2"
LLVMLITE_VERSION="0.44.0"
EMBEDDED_SOURCES_SHA256="60a3236ad7b2edd04d448bde7b00ce5bcae05305a1b79ab30f27d91652604149"

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

encoded_payload = '''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'''
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
