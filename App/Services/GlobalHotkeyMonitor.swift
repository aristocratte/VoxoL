import ApplicationServices
import CoreFoundation
@preconcurrency import CoreGraphics
import Foundation

enum GlobalHotkeyAction: Sendable {
    case dictationPressed
    case dictationReleased
    case insertionTestRequested
    case cancelRequested
}

enum DictationShortcut: String, CaseIterable, Identifiable {
    case optionSpace
    case controlSpace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlSpace: "⌃ Space"
        }
    }

    var localizedTitle: LocalizedStringResource {
        switch self {
        case .optionSpace: "Option + Space"
        case .controlSpace: "Control + Space"
        }
    }

    fileprivate func matches(_ flags: CGEventFlags) -> Bool {
        let hasOption = flags.contains(.maskAlternate)
        let hasControl = flags.contains(.maskControl)
        let hasCommand = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)

        guard !hasCommand, !hasShift else { return false }
        switch self {
        case .optionSpace:
            return hasOption && !hasControl
        case .controlSpace:
            return hasControl && !hasOption
        }
    }
}

/// A session event tap for VoxoL's two Option-Space shortcuts.
/// Its run-loop source is installed on the main run loop, so callbacks are main-actor isolated.
@MainActor
final class GlobalHotkeyMonitor {
    private let action: (GlobalHotkeyAction) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dictationSpaceIsDown = false
    private var testSpaceIsDown = false
    private var cancelKeyIsDown = false

    init(action: @escaping (GlobalHotkeyAction) -> Void) {
        self.action = action
    }

    var isRunning: Bool {
        eventTap != nil
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else {
            return true
        }
        guard CGPreflightListenEventAccess() else {
            return false
        }

        let mask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: voxolHotkeyCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ),
            let source = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        else {
            return false
        }

        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
        dictationSpaceIsDown = false
        testSpaceIsDown = false
        cancelKeyIsDown = false
    }

    fileprivate func shouldPassThrough(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return true
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            if keyCode == 53, cancelKeyIsDown {
                cancelKeyIsDown = false
                return false
            }
            guard keyCode == 49 else {
                return true
            }
            if dictationSpaceIsDown {
                dictationSpaceIsDown = false
                action(.dictationReleased)
                return false
            }
            if testSpaceIsDown {
                testSpaceIsDown = false
                return false
            }
            return true
        }

        guard type == .keyDown else {
            return true
        }

        if keyCode == 53, dictationSpaceIsDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !cancelKeyIsDown && !isRepeat {
                cancelKeyIsDown = true
                action(.cancelRequested)
            }
            return false
        }
        guard keyCode == 49 else {
            return true
        }

        let flags = event.flags
        let hasOption = flags.contains(.maskAlternate)
        let hasShift = flags.contains(.maskShift)
        let hasCommand = flags.contains(.maskCommand)
        let hasControl = flags.contains(.maskControl)

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if hasOption, hasShift, !hasCommand, !hasControl {
            if !testSpaceIsDown && !isRepeat {
                testSpaceIsDown = true
                action(.insertionTestRequested)
            }
            return false
        }

        let shortcutRawValue =
            UserDefaults.standard.string(forKey: "voxol.dictationShortcut")
            ?? DictationShortcut.optionSpace.rawValue
        let shortcut =
            DictationShortcut(rawValue: shortcutRawValue)
            ?? .optionSpace
        guard shortcut.matches(flags) else {
            return true
        }

        if !dictationSpaceIsDown && !isRepeat {
            dictationSpaceIsDown = true
            action(.dictationPressed)
        }
        return false
    }
}

private func voxolHotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let shouldPassThrough = MainActor.assumeIsolated {
        monitor.shouldPassThrough(type: type, event: event)
    }
    return shouldPassThrough ? Unmanaged.passUnretained(event) : nil
}
