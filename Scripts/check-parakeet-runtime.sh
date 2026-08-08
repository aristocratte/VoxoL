#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_directory")
model_root=${VOXOL_ASR_MODEL_ROOT:-"$HOME/Library/Application Support/VoxoL/Models/asr/7c35754d166cca382ad1e53e68b01e7c575f3a1d"}
compute_units=${VOXOL_ASR_COMPUTE_UNITS:-all}

if [ ! -d "$model_root" ]; then
    printf '%s\n' "Installed Parakeet model not found: $model_root" >&2
    exit 1
fi

fixture_directory=$(mktemp -d "${TMPDIR:-/tmp}/voxol-asr-smoke.XXXXXX")
cleanup() {
    /bin/rm -rf "$fixture_directory"
}
trap cleanup EXIT HUP INT TERM

fixture="$fixture_directory/voxol-smoke.aiff"
say -v Samantha -o "$fixture" "Voxol transcription works locally."

output=$(
    cd "$repository_root"
    swift run -c release voxol-asr-smoke \
        --model-root "$model_root" \
        --compute-units "$compute_units" \
        "$fixture"
)

normalized=$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')
case "$normalized" in
    *transcription*locally*) ;;
    *)
        printf '%s\n' "Unexpected Parakeet transcript: $output" >&2
        exit 1
        ;;
esac

printf '%s\n' "Parakeet runtime smoke test passed: $output"
