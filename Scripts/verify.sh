#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_directory")
derived_data="$repository_root/.build/DerivedData"

cd "$repository_root"

./Scripts/check-repository-policy.sh
python3 Scripts/build-parakeet-colab-notebook.py --check
python3 Scripts/build-parakeet-gpu-runner.py --check
xcrun swift-format lint --strict --parallel --recursive Package.swift App Packages Tools Tests
swift test
swift run voxol-benchmark --iterations 5 >/dev/null

development_identity=$(
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n '/"Apple Development:/p' \
        | sed -n '1p'
)

set -- CODE_SIGNING_ALLOWED=YES
if [ -z "$development_identity" ]; then
    set -- "$@" 'CODE_SIGN_IDENTITY=-' 'DEVELOPMENT_TEAM='
fi

xcodebuild \
    -project VoxoL.xcodeproj \
    -scheme VoxoL \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    -skipPackagePluginValidation \
    "$@" \
    build

./Scripts/check-localization.sh "$derived_data"

application_path="$derived_data/Build/Products/Debug/VoxoL.app"
if [ ! -d "$application_path" ]; then
    printf '%s\n' "Expected application was not built: $application_path" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$application_path"

if [ -n "$development_identity" ]; then
    designated_requirement=$(codesign -d -r- "$application_path" 2>&1)
    case "$designated_requirement" in
        *"anchor apple generic"*) ;;
        *)
            printf '%s\n' \
                "Debug signing is ephemeral; macOS permissions would be lost after rebuilding." >&2
            exit 1
            ;;
    esac
fi

application_pid=""
launch_log=""
cleanup_launch_smoke() {
    if [ -n "$application_pid" ] && kill -0 "$application_pid" 2>/dev/null; then
        kill "$application_pid" 2>/dev/null || true
        wait "$application_pid" 2>/dev/null || true
    fi
    if [ -n "$launch_log" ] && [ -f "$launch_log" ]; then
        /bin/rm -f "$launch_log"
    fi
}
trap cleanup_launch_smoke EXIT HUP INT TERM

launch_log=$(mktemp -t voxol-launch-smoke.XXXXXX)
"$application_path/Contents/MacOS/VoxoL" >"$launch_log" 2>&1 &
application_pid=$!
sleep 2
if ! kill -0 "$application_pid" 2>/dev/null; then
    printf '%s\n' "VoxoL exited during the launch smoke test:" >&2
    sed -n '1,120p' "$launch_log" >&2
    exit 1
fi
kill "$application_pid" 2>/dev/null || true
wait "$application_pid" 2>/dev/null || true
application_pid=""
/bin/rm -f "$launch_log"
launch_log=""
trap - EXIT HUP INT TERM

printf '%s\n' "VoxoL verification passed."
