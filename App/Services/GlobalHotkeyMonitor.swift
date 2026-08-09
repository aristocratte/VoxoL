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
    case rightCommand
    case rightOption
    case rightControl
    case fnKey

    var id: String { rawValue }

    /// Shortcuts that are a single key held on their own, with the key code that reports them.
    ///
    /// A modifier arrives as a `flagsChanged` event rather than a key press, so these are matched
    /// on the physical key rather than on a combination.
    var soloKeyCode: Int64? {
        switch self {
        case .rightCommand: 54
        case .rightOption: 61
        case .rightControl: 62
        case .fnKey: 63
        case .optionSpace, .controlSpace: nil
        }
    }

    var label: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlSpace: "⌃ Space"
        case .rightCommand: "⌘ droite"
        case .rightOption: "⌥ droite"
        case .rightControl: "⌃ droite"
        case .fnKey: "fn"
        }
    }

    var localizedTitle: LocalizedStringResource {
        switch self {
        case .optionSpace: "Option + Space"
        case .controlSpace: "Control + Space"
        case .rightCommand: "Right Command, held alone"
        case .rightOption: "Right Option, held alone"
        case .rightControl: "Right Control, held alone"
        case .fnKey: "Fn, held alone"
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
        case .rightCommand, .rightOption, .rightControl, .fnKey:
            return false
        }
    }

    /// The flag a solo modifier raises, used to tell a press from a release.
    fileprivate var soloFlag: CGEventFlags? {
        switch self {
        case .rightCommand: .maskCommand
        case .rightOption: .maskAlternate
        case .rightControl: .maskControl
        case .fnKey: .maskSecondaryFn
        case .optionSpace, .controlSpace: nil
        }
    }

    /// Reads the user's choice, falling back to the shipping default.
    static var current: DictationShortcut {
        let stored =
            UserDefaults.standard.string(forKey: "voxol.dictationShortcut")
            ?? DictationShortcut.optionSpace.rawValue
        return DictationShortcut(rawValue: stored) ?? .optionSpace
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
    /// True while a solo-modifier shortcut is being held for dictation.
    private var soloModifierIsDown = false
    /// Set when another key is pressed during a solo hold: the user was typing a combination,
    /// not dictating, so the capture is cancelled and not restarted until the key comes back up.
    private var soloModifierAborted = false

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
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
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
        soloModifierIsDown = false
        soloModifierAborted = false
    }

    fileprivate func shouldPassThrough(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return true
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .flagsChanged {
            handleFlagsChanged(keyCode: keyCode, flags: event.flags)
            // Modifiers are never swallowed: holding one must keep working as a modifier.
            return true
        }

        // Any other key pressed during a solo hold means a shortcut was being typed.
        if type == .keyDown, soloModifierIsDown, !soloModifierAborted {
            soloModifierAborted = true
            soloModifierIsDown = false
            action(.cancelRequested)
            return true
        }
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

        guard DictationShortcut.current.matches(flags) else {
            return true
        }

        if !dictationSpaceIsDown && !isRepeat {
            dictationSpaceIsDown = true
            action(.dictationPressed)
        }
        return false
    }
}

extension GlobalHotkeyMonitor {
    /// Turns a modifier press and release into the same hold-to-talk gesture as a key combination.
    fileprivate func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) {
        let shortcut = DictationShortcut.current
        guard let soloKeyCode = shortcut.soloKeyCode, let soloFlag = shortcut.soloFlag else {
            // A combination shortcut: releasing its modifier ends a hold that the space key
            // started, otherwise the capture would run on after the user let go.
            if dictationSpaceIsDown, !shortcut.matches(flags) {
                dictationSpaceIsDown = false
                action(.dictationReleased)
            }
            return
        }

        guard keyCode == soloKeyCode else {
            return
        }

        if flags.contains(soloFlag) {
            // Only a modifier held on its own starts dictation; combined with another modifier it
            // belongs to a shortcut the user is typing.
            var others: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            others.remove(soloFlag)
            guard flags.intersection(others).isEmpty else {
                return
            }
            guard !soloModifierIsDown, !soloModifierAborted else { return }
            soloModifierIsDown = true
            action(.dictationPressed)
        } else {
            let wasHolding = soloModifierIsDown
            soloModifierIsDown = false
            soloModifierAborted = false
            if wasHolding {
                action(.dictationReleased)
            }
        }
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
