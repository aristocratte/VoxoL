#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
app_binary="$repo_root/.build/DerivedData/Build/Products/Debug/VoxoL.app/Contents/MacOS/VoxoL"
model_root="${1:-}"

if [[ -z "$model_root" ]]; then
    model_root="$(find "$HOME/Library/Application Support/VoxoL/Models/polisher" -mindepth 1 -maxdepth 1 -type d -print -quit)"
fi

if [[ ! -x "$app_binary" ]]; then
    print -u2 "Build VoxoL with Xcode before running the Qwen smoke test."
    exit 2
fi
if [[ -z "$model_root" || ! -f "$model_root/config.json" ]]; then
    print -u2 "No installed Qwen model was found."
    exit 2
fi

"$app_binary" \
    --polisher-smoke \
    --model "$model_root" \
    --text "euh envoie le rapport demain matin à VoxoL"
