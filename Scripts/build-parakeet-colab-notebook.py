#!/usr/bin/env python3
"""Build the self-contained VoxoL Parakeet Google Colab notebook."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = (
    REPOSITORY_ROOT / "Notebooks" / "VoxoL_Parakeet_Finetune_Colab.ipynb"
)
EMBEDDED_FILES = (
    "Scripts/resumable_dataset_download.py",
    "Scripts/prepare-parakeet-fleurs-finetune.py",
    "Scripts/prepare-fleurs-test-benchmark.py",
    "Scripts/prepare-mediaspeech-fr-benchmark.py",
    "Tools/training/freeze_asr_manifest.py",
    "Tools/training/run_voxol_nemo_finetune.py",
    "Tools/training/run_nemo_asr_benchmark.py",
    "Tools/training/score_asr_predictions.py",
)


def source_lines(source: str) -> list[str]:
    return source.splitlines(keepends=True) or [""]


def markdown_cell(source: str) -> dict[str, object]:
    return {
        "cell_type": "markdown",
        "metadata": {},
        "source": source_lines(source),
    }


def code_cell(source: str) -> dict[str, object]:
    return {
        "cell_type": "code",
        "execution_count": None,
        "metadata": {},
        "outputs": [],
        "source": source_lines(source),
    }


def embedded_sources_cell() -> str:
    sources = {
        relative_path: (REPOSITORY_ROOT / relative_path).read_text(encoding="utf-8")
        for relative_path in EMBEDDED_FILES
    }
    serialized = json.dumps(sources, ensure_ascii=False, indent=2, sort_keys=True)
    return f"""\
import json
from pathlib import Path

EMBEDDED_SOURCES = json.loads(r'''{serialized}''')
SOURCE_ROOT = Path("/content/voxol-sources")
for relative_path, source in EMBEDDED_SOURCES.items():
    destination = SOURCE_ROOT / relative_path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(source, encoding="utf-8")

print(f"VoxoL sources ready: {{SOURCE_ROOT}}")
"""


def notebook() -> dict[str, object]:
    return {
        "nbformat": 4,
        "nbformat_minor": 5,
        "metadata": {
            "accelerator": "GPU",
            "colab": {
                "gpuType": "T4",
                "include_colab_link": True,
                "provenance": [],
            },
            "kernelspec": {
                "display_name": "Python 3",
                "name": "python3",
            },
            "language_info": {"name": "python"},
        },
        "cells": [
            markdown_cell(
                """\
# VoxoL — Parakeet FR/EN autonomous training gate

Choose a GPU runtime, then use **Runtime → Run all**. The only interaction is Google's Drive
authorization. The notebook selects a safe T4/L4/A100 profile, resumes verified downloads,
trains an architecture-compatible candidate, and compares the
official source model with the candidate on locked FLEURS FR/EN and MediaSpeech FR tests.

The candidate is never promoted merely because training completed. It must preserve both FLEURS
languages, improve MediaSpeech by at least 10% relative, and reduce empty transcripts. Expect
several hours and roughly 12 GB of free Google Drive space. The trainer stores only the best
fine-tuned parameter delta; the evaluator reconstructs the official model from that delta.
"""
            ),
            code_cell(
                """\
from pathlib import Path
import json
import os
import shutil

from google.colab import drive
import torch

drive.mount("/content/drive")
if not torch.cuda.is_available():
    raise RuntimeError("Select Runtime → Change runtime type → GPU, then run all again.")

gpu = torch.cuda.get_device_properties(0)
memory_gib = gpu.total_memory / (1024 ** 3)
bf16 = torch.cuda.is_bf16_supported()
if memory_gib < 14:
    raise RuntimeError(f"The assigned GPU has only {memory_gib:.1f} GiB; at least 14 GiB is required.")

if memory_gib < 20:
    PROFILE = {
        "name": "t4-safe",
        "precision": "16-mixed",
        "batch_size": 1,
        "validation_batch_size": 1,
        "accumulate_grad_batches": 16,
        "max_duration": 12,
        "train_top_encoder_layers": 6,
        "evaluation_batch_size": 4,
    }
elif memory_gib < 38:
    PROFILE = {
        "name": "l4-safe",
        "precision": "bf16-mixed" if bf16 else "16-mixed",
        "batch_size": 2,
        "validation_batch_size": 2,
        "accumulate_grad_batches": 8,
        "max_duration": 18,
        "train_top_encoder_layers": 8,
        "evaluation_batch_size": 8,
    }
else:
    PROFILE = {
        "name": "a100-safe",
        "precision": "bf16-mixed" if bf16 else "16-mixed",
        "batch_size": 4,
        "validation_batch_size": 4,
        "accumulate_grad_batches": 4,
        "max_duration": 30,
        "train_top_encoder_layers": 8,
        "evaluation_batch_size": 16,
    }

DRIVE_ROOT = Path("/content/drive/MyDrive/VoxoL-Parakeet")
SCRATCH_ROOT = Path("/content/voxol")
NEMO_ROOT = Path("/content/NeMo")
for directory in (DRIVE_ROOT, SCRATCH_ROOT):
    directory.mkdir(parents=True, exist_ok=True)

os.environ["HF_HOME"] = str(SCRATCH_ROOT / "huggingface")
os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "expandable_segments:True"
torch.set_float32_matmul_precision("high")

run_profile = {
    **PROFILE,
    "gpu": gpu.name,
    "memoryGiB": round(memory_gib, 2),
    "bf16Supported": bf16,
    "scratchFreeGiB": round(shutil.disk_usage("/content").free / (1024 ** 3), 2),
}
(DRIVE_ROOT / "run-profile.json").write_text(
    json.dumps(run_profile, indent=2, sort_keys=True) + "\\n",
    encoding="utf-8",
)
print(json.dumps(run_profile, indent=2, sort_keys=True))
"""
            ),
            code_cell(
                """\
import importlib
import importlib.util
import subprocess
import sys

NEMO_REVISION = "2381f42f6979449b5b99538f8f80135831009b51"

def checked(command):
    print("+", " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True)

checked(["apt-get", "-qq", "update"])
checked(["apt-get", "-qq", "install", "-y", "libsndfile1", "ffmpeg"])
if not (NEMO_ROOT / ".git").exists():
    NEMO_ROOT.mkdir(parents=True, exist_ok=True)
    checked(["git", "-C", NEMO_ROOT, "init"])
    checked(["git", "-C", NEMO_ROOT, "remote", "add", "origin", "https://github.com/NVIDIA-NeMo/NeMo.git"])
checked(["git", "-C", NEMO_ROOT, "fetch", "--depth=1", "origin", NEMO_REVISION])
checked(["git", "-C", NEMO_ROOT, "checkout", "--detach", "FETCH_HEAD"])
actual_revision = subprocess.check_output(
    ["git", "-C", NEMO_ROOT, "rev-parse", "HEAD"],
    text=True,
).strip()
if actual_revision != NEMO_REVISION:
    raise RuntimeError(f"NeMo revision mismatch: {actual_revision}")

checked([sys.executable, "-m", "pip", "install", "-q", "--upgrade", "pip"])
checked([sys.executable, "-m", "pip", "install", "-q", "-e", f"{NEMO_ROOT}[asr]"])

nemo_package = NEMO_ROOT / "nemo" / "__init__.py"
if not nemo_package.is_file():
    raise RuntimeError(f"NeMo checkout does not contain the Python package: {nemo_package}")
if str(NEMO_ROOT) not in sys.path:
    sys.path.insert(0, str(NEMO_ROOT))
importlib.invalidate_caches()
if importlib.util.find_spec("nemo") is None:
    package_report = subprocess.run(
        [sys.executable, "-m", "pip", "show", "nemo_toolkit"],
        capture_output=True,
        text=True,
        check=False,
    )
    raise RuntimeError(
        "NeMo was installed but is not importable in the current Colab kernel.\\n"
        f"pip show output:\\n{package_report.stdout or package_report.stderr}"
    )
import nemo
print(f"NeMo ready at {actual_revision}")
"""
            ),
            code_cell(embedded_sources_cell()),
            code_cell(
                """\
import subprocess
import sys
from collections import deque

def run_python(relative_script, *arguments):
    command = [sys.executable, str(SOURCE_ROOT / relative_script), *map(str, arguments)]
    print("+", " ".join(command), flush=True)
    log_root = DRIVE_ROOT / "logs"
    log_root.mkdir(parents=True, exist_ok=True)
    log_path = log_root / f"{relative_script.replace('/', '-')}.log"
    tail = deque(maxlen=80)
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="")
            log.write(line)
            log.flush()
            tail.append(line)
        return_code = process.wait()
    if return_code != 0:
        diagnostic = "".join(tail).strip() or "The child process produced no output."
        raise RuntimeError(
            f"{relative_script} failed with exit code {return_code}.\\n"
            f"Last output:\\n{diagnostic}\\n"
            f"Full log: {log_path}"
        )

dataset_cache = DRIVE_ROOT / "dataset-cache"
training_data = SCRATCH_ROOT / "data" / "parakeet-fleurs-fr-en"
fleurs_test = SCRATCH_ROOT / "benchmarks" / "fleurs-test"
mediaspeech_test = SCRATCH_ROOT / "benchmarks" / "mediaspeech-fr"
print("Dataset preparation version: 2026-07-27-fleurs-tsv-v2")

run_python(
    "Scripts/prepare-parakeet-fleurs-finetune.py",
    "--cache-root", dataset_cache / "fleurs-training",
    "--output-root", training_data,
)
run_python(
    "Scripts/prepare-fleurs-test-benchmark.py",
    "--cache-root", dataset_cache / "fleurs-test",
    "--output-root", fleurs_test,
)
run_python(
    "Scripts/prepare-mediaspeech-fr-benchmark.py",
    "--cache-root", dataset_cache / "mediaspeech",
    "--output-root", mediaspeech_test,
)
for benchmark_root in (fleurs_test, mediaspeech_test):
    run_python(
        "Tools/training/freeze_asr_manifest.py",
        "--input", benchmark_root / "manifest-unfrozen.json",
        "--output", benchmark_root / "manifest-frozen.json",
        "--timestamp", "2026-07-26T00:00:00Z",
    )

print("Training and locked evaluation datasets are ready.")
"""
            ),
            code_cell(
                """\
import json
import shutil
import subprocess
import sys

local_experiment_root = SCRATCH_ROOT / "experiments"
durable_candidate_root = DRIVE_ROOT / "candidates"
result_root = DRIVE_ROOT / "results"
local_experiment_root.mkdir(parents=True, exist_ok=True)
durable_candidate_root.mkdir(parents=True, exist_ok=True)
result_root.mkdir(parents=True, exist_ok=True)
completion_path = result_root / "training-complete.json"
print("Training checkpoint version: 2026-07-28-trainable-delta-v1")

def existing_candidate():
    if not completion_path.is_file():
        return None
    completion = json.loads(completion_path.read_text(encoding="utf-8"))
    candidate = Path(completion["candidate"])
    return candidate if candidate.is_file() else None

def stream_process(command, log_path):
    print("+", " ".join(map(str, command)), flush=True)
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            list(map(str, command)),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="")
            log.write(line)
            log.flush()
        return process.wait()

def persist_candidate(source, destination):
    partial_destination = destination.with_suffix(destination.suffix + ".partial")
    with (
        source.open("rb") as source_file,
        partial_destination.open("wb") as destination_file,
    ):
        shutil.copyfileobj(source_file, destination_file, length=8 * 1024 * 1024)
    if partial_destination.stat().st_size != source.stat().st_size:
        raise RuntimeError("The candidate copy to Google Drive is incomplete.")
    partial_destination.replace(destination)
    return destination

candidate = existing_candidate()
if candidate is None:
    fallback = {
        **PROFILE,
        "name": f"{PROFILE['name']}-oom-fallback",
        "batch_size": 1,
        "validation_batch_size": 1,
        "accumulate_grad_batches": 16,
        "max_duration": min(10, PROFILE["max_duration"]),
        "train_top_encoder_layers": min(4, PROFILE["train_top_encoder_layers"]),
    }
    for attempt_number, attempt in enumerate((PROFILE, fallback), 1):
        attempt_experiment_root = (
            local_experiment_root / f"attempt-{attempt_number}"
        )
        command = [
            sys.executable,
            SOURCE_ROOT / "Tools/training/run_voxol_nemo_finetune.py",
            "--train-manifest", training_data / "train.jsonl",
            "--validation-manifest", training_data / "validation.jsonl",
            "--experiment-root", attempt_experiment_root,
            "--precision", attempt["precision"],
            "--batch-size", attempt["batch_size"],
            "--validation-batch-size", attempt["validation_batch_size"],
            "--accumulate-grad-batches", attempt["accumulate_grad_batches"],
            "--max-duration", attempt["max_duration"],
            "--train-top-encoder-layers", attempt["train_top_encoder_layers"],
            "--max-epochs", 5,
            "--learning-rate", "2e-5",
            "--minimum-learning-rate", "2e-6",
            "--warmup-steps", 100,
            "--num-workers", 2,
        ]
        log_path = result_root / f"training-attempt-{attempt_number}.log"
        return_code = stream_process(command, log_path)
        if return_code == 0:
            candidates = sorted(
                attempt_experiment_root.rglob("*.delta.pt"),
                key=lambda path: path.stat().st_mtime,
            )
            if not candidates:
                raise RuntimeError(
                    "Training completed but produced no trainable delta."
                )
            local_candidate = candidates[-1]
            durable_candidate = (
                durable_candidate_root / f"{attempt['name']}.delta.pt"
            )
            candidate = persist_candidate(local_candidate, durable_candidate)
            completion_path.write_text(
                json.dumps(
                    {
                        "candidate": str(candidate),
                        "profile": attempt,
                        "log": str(log_path),
                    },
                    indent=2,
                    sort_keys=True,
                )
                + "\\n",
                encoding="utf-8",
            )
            break
        log_text = log_path.read_text(encoding="utf-8").lower()
        resource_failure = (
            return_code in (-9, 137)
            or "out of memory" in log_text
            or "cuda error: out of memory" in log_text
        )
        if not resource_failure or attempt_number == 2:
            raise RuntimeError(
                f"Training failed with exit code {return_code}; inspect {log_path}"
            )
        print(
            "The training process was killed while exhausting a resource. "
            "Retrying automatically with the safe fallback."
        )
else:
    print(f"Using completed candidate: {candidate}")

print(f"Candidate ready: {candidate}")
"""
            ),
            code_cell(
                """\
import subprocess
import sys

def evaluated_predictions(label, benchmark_label, benchmark_root, model_arguments):
    output_root = result_root / label
    output_root.mkdir(parents=True, exist_ok=True)
    predictions = output_root / f"{benchmark_label}-predictions.jsonl"
    command = [
        sys.executable,
        SOURCE_ROOT / "Tools/training/run_nemo_asr_benchmark.py",
        *model_arguments,
        "--manifest", benchmark_root / "manifest-frozen.json",
        "--audio-root", benchmark_root / "audio",
        "--output", predictions,
        "--batch-size", PROFILE["evaluation_batch_size"],
        "--resume",
    ]
    print("+", " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True)
    report = output_root / f"{benchmark_label}-report.json"
    score_command = [
        sys.executable,
        SOURCE_ROOT / "Tools/training/score_asr_predictions.py",
        "--manifest", benchmark_root / "manifest-frozen.json",
        "--predictions", predictions,
        "--output", report,
    ]
    print("+", " ".join(map(str, score_command)), flush=True)
    subprocess.run(list(map(str, score_command)), check=True)
    return report

reports = {}
for label, model_arguments in (
    ("baseline", ["--pretrained-name", "nvidia/parakeet-tdt-0.6b-v3"]),
    ("candidate", ["--delta", candidate]),
):
    reports[(label, "fleurs")] = evaluated_predictions(
        label,
        "fleurs-fr-en-test",
        fleurs_test,
        model_arguments,
    )
    reports[(label, "mediaspeech")] = evaluated_predictions(
        label,
        "mediaspeech-fr",
        mediaspeech_test,
        model_arguments,
    )

print("Baseline and candidate evaluations are complete.")
"""
            ),
            code_cell(
                """\
import json

def loaded(label, benchmark):
    return json.loads(reports[(label, benchmark)].read_text(encoding="utf-8"))

baseline_fleurs = loaded("baseline", "fleurs")
candidate_fleurs = loaded("candidate", "fleurs")
baseline_media = loaded("baseline", "mediaspeech")
candidate_media = loaded("candidate", "mediaspeech")

checks = {
    "fleursOverallRegressionAtMost0.5Point": (
        candidate_fleurs["microWER"] <= baseline_fleurs["microWER"] + 0.005
    ),
    "fleursFrenchRegressionAtMost0.5Point": (
        candidate_fleurs["byLanguage"]["french"]["microWER"]
        <= baseline_fleurs["byLanguage"]["french"]["microWER"] + 0.005
    ),
    "fleursEnglishRegressionAtMost0.5Point": (
        candidate_fleurs["byLanguage"]["english"]["microWER"]
        <= baseline_fleurs["byLanguage"]["english"]["microWER"] + 0.005
    ),
    "mediaSpeechImprovesAtLeast10PercentRelative": (
        candidate_media["microWER"] <= baseline_media["microWER"] * 0.90
    ),
    "mediaSpeechEmptyOutputsDecrease": (
        candidate_media["emptyOutputCount"] < baseline_media["emptyOutputCount"]
    ),
}
decision = {
    "sourceGatePassed": all(checks.values()),
    "checks": checks,
    "candidate": str(candidate),
    "baseline": {
        "fleurs": baseline_fleurs,
        "mediaspeech": baseline_media,
    },
    "candidateResults": {
        "fleurs": candidate_fleurs,
        "mediaspeech": candidate_media,
    },
    "nextStep": (
        "Export int8 and int4 Core ML candidates, then run the Mac parity/latency gate."
        if all(checks.values())
        else "Reject this candidate; keep the production model and add independent media-domain training data."
    ),
}
decision_path = result_root / "source-gate.json"
decision_path.write_text(
    json.dumps(decision, indent=2, sort_keys=True) + "\\n",
    encoding="utf-8",
)
print(json.dumps(decision, indent=2, sort_keys=True))
print(f"\\nSaved decision: {decision_path}")
"""
            ),
            markdown_cell(
                """\
## Finished

The durable outputs are in `My Drive/VoxoL-Parakeet/results/`. `source-gate.json` contains the
decision and every score; the trainable delta is under `candidates/`. If the gate is false, do not
convert or ship the candidate. If it is true, give Codex the delta and `source-gate.json`; the next
step reconstructs a `.nemo` artifact in a fresh low-memory process before the Mac int8/int4 gate.
"""
            ),
        ],
    }


def rendered_notebook() -> str:
    return json.dumps(notebook(), ensure_ascii=False, indent=1) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    rendered = rendered_notebook()
    if arguments.check:
        if not OUTPUT_PATH.is_file() or OUTPUT_PATH.read_text(encoding="utf-8") != rendered:
            raise SystemExit(f"Generated notebook is stale: {OUTPUT_PATH}")
        print(f"Notebook is current: {OUTPUT_PATH}")
        return
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(rendered, encoding="utf-8")
    print(OUTPUT_PATH)


if __name__ == "__main__":
    main()
