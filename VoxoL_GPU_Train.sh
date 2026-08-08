#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

BUNDLE_VERSION="2026-08-03-gpu-bundle-v12"
NEMO_REVISION="2381f42f6979449b5b99538f8f80135831009b51"
NUMBA_VERSION="0.61.2"
LLVMLITE_VERSION="0.44.0"
EMBEDDED_SOURCES_SHA256="6a2246adaafeacc33dedc49618967f242bb196431e43ef8e0d857e854f2585c3"

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

encoded_payload = '''H4sIAAAAAAAC/+y9iXYbyZE2+ipljf0L6AZALFzRhs+wJXa3xtqGpNpjk7x1CkCBhAWiYBQgik3jnP8h7kv4Ofwm90luRkTuS1WB
ors9M/Z4LKIqMyuXyMjIWL54eHY2Wk4Xq3xnsUwXyTJtTmbpepk3V2m+ag7T+ejmNll+bC3un/Wf/duvdtb5cmc4ne+k80/R4n51
k817l/PLZ/B/76mBaHWTRqPsdjFLV2m0mM7n6Tj67vXJh9Oz6LslNBgl83F0Mr+eTfObCL4T5YvZdJW3qB3W3nyyzG6jOJ6sV+tl
GsfR9HaRLVes4jxbJatpNs+hlHi6vGYfzlP5YJR/kn/fJPnNbDqUv/+cZ6pmlvNPLZIVlBLfec9+ykL5zXo1ncmfq2Q5mc5S7fvL
NF/fJsNZGo+TVZKnq3ic3c1nWTKGQpfzl8fnx2cn5/HpyY+vzl69exsNostnB+3hsJse7g6PDvaHB+nRfjtJDo8mndH+7mHaPhrt
HU0Oj3bHY5iPF+/efvfq+w+nx+es9hmr/nA5j9h/Lp+l83idXz7riyf0dJbMr9fJdQovoAzO9OWzhl4mWY5upp/SOL9Junv7ULKm
XlOR8dGom/YOhrudJBmNdzvDUfewt7e3m7STw+5wb5d1vLd/eHjQ3j06ONhNR8PuYedoPEqSZG8v6UGjqsW69+PDe7b88O3u4VF8
uNeJWS2j4Cr/VNTDg91Re3e/2zvqHeyO03S4354k+71Jd+9wctQ+6B0eto96Sa87ZH3qdXbbR/t7k4N2OmnvjQ6OJgejxNfDTUNM
7mQZT5YlkztBin7E3HZ7+0fttNPuTnoHMKnjDpvR3dG4O5l00oP9dHeSjtMhm9q93qg9POge7HWSzvBgtNc5HE2ILCrObW/3KG73
9uP23t42c7s3bu+Pe73DYXe3m7bbB4f7k9Gk0x3tjo667fbh8GjSOzoa7yV7o8OD7uiowxb+qL130E1ZyaNRexya2w1tinE6ifJs
vRyl8Xo5q82yUTJL+1G+WjbYhpqxTc7GANsSn9Wj5u/g3z61s0wZX5jrfb58drNaLfL+zs7N+vp6Or+eJKO0Ncp2+JbMd66z7HqW
7hB722F7Npt9Snf0Xk4unz3Ye3WDDew8UP82Ow9G3zaiel0NSux93jl9YKLz9uj4i/TzIh2t0jFfFf3VmHHJ6Rw5Xx+5k10FV7sf
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
6Gw6XE5JpvtCg6iQJKPX0OQZNom2zyYKV2gSxZ/siGLH//HZ6VMbRZ/cEJqvh4tlxs7p3GcbvZx/y3ZP/OH0NZo7hXUGrtP5bNla
wT5ozdMVWmJA+s93Ol0Y59n716/ODSOnmibHGHc73qMt1utOkl5n3D0Yd9POKBkfdA8O9iZp2pvsHu4eJUfWXnNuINh80yfDK3ug
Wp9wPybDvWSv3TvYHe61O8Nhb5iMdg87e2l61Bn3Or290n7cJDMmSoIFK9gbzYLG1VCa8jdKZtcZ25k3tz7DGRABSpdCXzZP72qy
Rl3TiOIW58qP5TBkBbm7YcvN5DV2c4v6A/4ebRy1Tru7G30VwT+21pF60VovxmAjwdqmoMwLaHo2j30N9we3GDr2MdvoJU1LbKUi
7GiNCO0Cm7m64Gt4VZd3A12HNM1j0p/iRuWd0o1YggbqwGT0j2lDJybFjpsLbnEjYf0q+pGb2aIHrckNSN6T2Tq/sbU4fJK0so6R
sFgV9AUKN645K1CxGZpAfIQc3dG5jdZLaIarzBghjW4YqcFTWYQtApZy9cnOLY1qQklxQ4HrgKAVneuqWxlI3skK1FUrNDMk8+u0
1mlEvbqzaCb9epbwJf8S3gX1KUCVWWRrYlkLNfHpB/7HZqfbIKtsys47sMyO6444qQjCLzOulvfWZlNsurVczz2yYkCXAvMZVEI0
m5OEHQXPCgqAJIW0WVQov8numulymS0LizGKX94XlNgrr90cp7OkqI1uhTYYb6be5oWFmbw/ZwyguZrepkzCKijba5c1hKaZZlLU
SLOwDRLxgkWAE/KtGdJwgoAsDvPNzgMyzE3ovhNSXrFdMvo48Ch66rr9f5QudMGi9QJOw/F7+nUCMw/HEC6BReYuR/CZgHTpSzIH
IOV0/I3kbR+hEwnbmPyBY6KpRygrEd3ONUW+PI6xXqVDwVKey6ph1XnwGDllx+59v+IhUnSQaIy++CDxKcv0KcZFZwwN1GS3yWp0
0/cwR+TH4nRn19p5jlI4XVKFLVVaaM+T5XfsXzzfTbt2X7d7m69Amtwopu+YasGwSg9zw0TKjV6WDdUyraKOkV3RczgFwcKEY2it
PoNhzlpp19a6nZ21zMZawb76oHXbtOWgyT25i8HFAyaHO8mgNFdvjVM0hsoLWL2FjAAK545dWbO8RDncgpJVxv6EyyJoZ/lHSCYA
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
