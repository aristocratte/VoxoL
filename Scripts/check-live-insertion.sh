#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_directory")
application_path=${1:-"$repository_root/.build/DerivedData/Build/Products/Debug/VoxoL.app"}

if [ ! -d "$application_path" ]; then
    printf '%s\n' "VoxoL app not found: $application_path" >&2
    exit 1
fi

probe_document_created=false
cleanup_probe() {
    if [ "$probe_document_created" = true ]; then
        osascript -e 'tell application "TextEdit" to close front document saving no' \
            >/dev/null 2>&1 || true
    fi
}
trap cleanup_probe EXIT HUP INT TERM

pkill -x VoxoL 2>/dev/null || true
sleep 1
open "$application_path"
sleep 2

application_pid=$(pgrep -x VoxoL | sed -n '1p')
if [ -z "$application_pid" ]; then
    printf '%s\n' "VoxoL did not launch." >&2
    exit 1
fi

osascript \
    -e 'tell application "TextEdit"' \
    -e 'activate' \
    -e 'make new document with properties {text:"INSERTION_PROBE_START\n"}' \
    -e 'end tell' >/dev/null
probe_document_created=true
sleep 1

probe_started_at=$(
    perl -MTime::HiRes=time -e 'print time'
)
xcrun swift -e '
    import CoreGraphics
    import Foundation

    let source = CGEventSource(stateID: .hidSystemState)!
    let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)!
    down.flags = [.maskAlternate, .maskShift]
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.1)
    let up = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)!
    up.flags = [.maskAlternate, .maskShift]
    up.post(tap: .cghidEventTap)
' >/dev/null

probe_visible_at=""
attempt=0
while [ "$attempt" -lt 200 ]; do
    document_text=$(osascript -e 'tell application "TextEdit" to get text of front document')
    case "$document_text" in
        *"VoxoL test"*|*"Test VoxoL"*)
            probe_visible_at=$(
                perl -MTime::HiRes=time -e 'print time'
            )
            break
            ;;
    esac
    attempt=$((attempt + 1))
    sleep 0.01
done

if [ -z "$probe_visible_at" ]; then
    printf '%s\n' \
        "VoxoL did not receive or insert the probe text. Grant Input Monitoring and Accessibility in VoxoL Settings, then run this check again." >&2
    exit 1
fi

probe_visible_milliseconds=$(
    perl -e \
        'printf "%.1f", 1000 * ($ARGV[1] - $ARGV[0])' \
        "$probe_started_at" \
        "$probe_visible_at"
)

if ! kill -0 "$application_pid" 2>/dev/null; then
    printf '%s\n' "VoxoL exited during the insertion probe." >&2
    exit 1
fi

cleanup_probe
probe_document_created=false
trap - EXIT HUP INT TERM
printf '%s\n' \
    "VoxoL live insertion probe passed: shortcut-to-visible=${probe_visible_milliseconds}ms."
