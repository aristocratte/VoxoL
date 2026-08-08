#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_directory")

forbidden_files=$(
    find "$repository_root" \
        \( -path "$repository_root/.git" \
        -o -path "$repository_root/.build" \
        -o -path "$repository_root/DerivedData" \
        -o -path "$repository_root/Artifacts" \
        -o -path "$repository_root/Models/artifacts" \) -prune \
        -o -type f \
        \( -name '*.bin' \
        -o -name '*.ckpt' \
        -o -name '*.gguf' \
        -o -name '*.mlmodel' \
        -o -name '*.nemo' \
        -o -name '*.onnx' \
        -o -name '*.pt' \
        -o -name '*.pth' \
        -o -name '*.safetensors' \) -print
)

forbidden_directories=$(
    find "$repository_root" \
        \( -path "$repository_root/.git" \
        -o -path "$repository_root/.build" \
        -o -path "$repository_root/DerivedData" \
        -o -path "$repository_root/Artifacts" \
        -o -path "$repository_root/Models/artifacts" \) -prune \
        -o -type d \( -name '*.mlmodelc' -o -name '*.mlpackage' \) -print
)

if [ -n "$forbidden_files" ] || [ -n "$forbidden_directories" ]; then
    printf '%s\n' "Model weights or generated model artifacts are forbidden in Git:" >&2
    if [ -n "$forbidden_files" ]; then
        printf '%s\n' "$forbidden_files" >&2
    fi
    if [ -n "$forbidden_directories" ]; then
        printf '%s\n' "$forbidden_directories" >&2
    fi
    exit 1
fi

large_files=$(
    find "$repository_root" \
        \( -path "$repository_root/.git" \
        -o -path "$repository_root/.build" \
        -o -path "$repository_root/DerivedData" \
        -o -path "$repository_root/Artifacts" \
        -o -path "$repository_root/Models/artifacts" \) -prune \
        -o -type f -size +50M -print
)

if [ -n "$large_files" ]; then
    printf '%s\n' "Files larger than 50 MiB require an explicit repository-policy review:" >&2
    printf '%s\n' "$large_files" >&2
    exit 1
fi

if /usr/bin/grep -Eiq \
    'OpenAI|Anthropic|GoogleGenerativeAI|Ollama|Whisper|Qwen3[-_]?ASR' \
    "$repository_root/Package.swift"; then
    printf '%s\n' "Package.swift contains a forbidden runtime dependency." >&2
    exit 1
fi

if ! /usr/bin/grep -Fq \
    'url: "https://github.com/ml-explore/mlx-swift-lm.git"' \
    "$repository_root/Package.swift" \
    || ! /usr/bin/grep -Fq 'exact: "2.31.3"' "$repository_root/Package.swift"; then
    printf '%s\n' "The only model runtime dependency must remain exactly pinned." >&2
    exit 1
fi

printf '%s\n' "Repository policy checks passed."
