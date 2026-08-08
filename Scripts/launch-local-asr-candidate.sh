#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_directory")
model_root=${1:-"$repository_root/Artifacts/Training/2026-08-01-wispr-replay-v5/coreml-candidates/nemo-direct-waveform-int8"}
derived_data="$repository_root/.build/DerivedData"
application_path="$derived_data/Build/Products/Debug/VoxoL.app"

for file in encoder.mlpackage decoder.mlpackage joint.mlpackage tokenizer.json; do
    if [ ! -e "$model_root/$file" ]; then
        printf 'Missing candidate file: %s\n' "$model_root/$file" >&2
        exit 1
    fi
done

xcodebuild \
    -project "$repository_root/VoxoL.xcodeproj" \
    -scheme VoxoL \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=YES \
    build

pkill -x VoxoL 2>/dev/null || true
launchctl setenv VOXOL_ASR_MODEL_ROOT "$model_root"
trap 'launchctl unsetenv VOXOL_ASR_MODEL_ROOT' EXIT HUP INT TERM
open -n "$application_path"
sleep 2
launchctl unsetenv VOXOL_ASR_MODEL_ROOT
trap - EXIT HUP INT TERM

printf 'VoxoL launched with ASR candidate: %s\n' "$model_root"
