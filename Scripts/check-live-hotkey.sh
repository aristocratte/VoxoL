#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_directory")
application_path=${1:-"$repository_root/.build/DerivedData/Build/Products/Debug/VoxoL.app"}

if [ ! -d "$application_path" ]; then
    printf '%s\n' "VoxoL app not found: $application_path" >&2
    exit 1
fi

pkill -x VoxoL 2>/dev/null || true
sleep 1
open "$application_path"
sleep 1

application_pid=$(pgrep -x VoxoL | sed -n '1p')
if [ -z "$application_pid" ]; then
    printf '%s\n' "VoxoL did not launch." >&2
    exit 1
fi

window_counts=$(VOXOL_TEST_PID="$application_pid" xcrun swift -e '
    import CoreGraphics
    import Foundation

    let pid = Int32(ProcessInfo.processInfo.environment["VOXOL_TEST_PID"]!)!
    func countWindows() -> Int {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.count { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
    }

    let windowsBefore = countWindows()
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)!
    down.flags = .maskAlternate
    down.post(tap: .cghidEventTap)
    var maximumWindowCount = windowsBefore
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.05)
        maximumWindowCount = max(maximumWindowCount, countWindows())
    }
    let up = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)!
    up.flags = .maskAlternate
    up.post(tap: .cghidEventTap)
    print("\(windowsBefore) \(maximumWindowCount)")
')
sleep 1

if ! kill -0 "$application_pid" 2>/dev/null; then
    printf '%s\n' "VoxoL crashed after the live dictation shortcut." >&2
    exit 1
fi

set -- $window_counts
windows_before=$1
windows_during=$2
if [ "$windows_during" -le "$windows_before" ]; then
    printf '%s\n' "The live shortcut did not display the voice capsule." >&2
    exit 1
fi

printf '%s\n' "VoxoL live hotkey smoke test passed."
