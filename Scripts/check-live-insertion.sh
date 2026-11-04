#!/bin/sh
# Compiled, opt-in TextEdit insertion diagnostic; not a microphone/shortcut benchmark.
set -eu
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_directory")
application_path=${1:-"$repository_root/.build/DerivedData/Build/Products/Debug/VoxoL.app"}
binary="$application_path/Contents/MacOS/VoxoL"
if [ ! -x "$binary" ]; then
    printf '%s\n' "Build the candidate first; executable not found: $binary" >&2
    exit 2
fi
# The candidate opens and closes only its own empty document. No pkill, no
# replacement of /Applications/VoxoL.app, and no compilation inside the timer.
exec "$binary" --polisher-smoke --insertion-only
