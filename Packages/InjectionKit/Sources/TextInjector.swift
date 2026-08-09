import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// The mechanism that successfully delivered text to the focused control.
public enum TextInsertionMethod: Equatable, Sendable {
    case accessibility
    case clipboardFallback
}

/// Safety or system failures that prevent text insertion.
public enum TextInjectionError: Error, Equatable, LocalizedError, Sendable {
    case emptyText
    case accessibilityPermissionMissing
    case focusedElementUnavailable
    case secureField
    case pasteboardWriteFailed
    case pasteEventUnavailable

    /// A user-readable reason insertion could not complete.
    public var errorDescription: String? {
        switch self {
        case .emptyText:
            "There is no text to insert."
        case .accessibilityPermissionMissing:
            "Accessibility permission is required to insert text."
        case .focusedElementUnavailable:
            "No editable field is focused."
        case .secureField:
            "VoxoL will not insert text into a secure field."
        case .pasteboardWriteFailed:
            "The temporary clipboard value could not be written."
        case .pasteEventUnavailable:
            "The system paste command could not be created."
        }
    }
}

/// Pure policy kept separate so clipboard ownership is deterministic and testable.
public enum InsertionPolicy {
    /// Returns whether VoxoL still owns the clipboard value it temporarily wrote.
    public static func shouldRestorePasteboard(
        injectedChangeCount: Int,
        currentChangeCount: Int
    ) -> Bool {
        injectedChangeCount == currentChangeCount
    }
}

/// Keeps the automatic paste fallback bound to the app that owned focus when dictation began.
public enum InsertionDestinationPolicy {
    /// Whether a synthetic paste is safe when Accessibility cannot expose an editable element.
    public static func allowsAutomaticPaste(
        capturedProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t?,
        secureFieldDetected: Bool,
        secureEventInputEnabled: Bool
    ) -> Bool {
        guard
            let capturedProcessIdentifier,
            let currentProcessIdentifier,
            capturedProcessIdentifier == currentProcessIdentifier
        else {
            return false
        }
        return !secureFieldDetected && !secureEventInputEnabled
    }
}

/// Adds only the boundary whitespace required by the text surrounding the cursor.
public enum InsertionTextPolicy {
    /// Returns text with safe leading and trailing spacing for its cursor context.
    public static func adjust(
        _ text: String,
        beforeCursor: String,
        afterCursor: String
    ) -> String {
        guard !text.isEmpty else {
            return text
        }
        var result = text
        if needsLeadingSpace(before: beforeCursor.last, inserted: result.first) {
            result.insert(" ", at: result.startIndex)
        }
        if needsTrailingSpace(inserted: result.last, after: afterCursor.first) {
            result.append(" ")
        }
        return result
    }
}

/// Decides when a failed automatic delivery may safely fall back to a manual paste.
public enum InsertionRecoveryPolicy {
    /// Whether preserving the transcript on the clipboard is an appropriate recovery.
    public static func allowsManualClipboardRecovery(for error: TextInjectionError) -> Bool {
        switch error {
        case .accessibilityPermissionMissing, .focusedElementUnavailable, .pasteEventUnavailable:
            true
        case .emptyText, .secureField, .pasteboardWriteFailed:
            false
        }
    }
}

/// A caret position and selection length, as Accessibility reports them.
public struct TextSelection: Equatable, Sendable {
    /// Caret offset in the field.
    public let location: Int
    /// Number of selected characters at that offset.
    public let length: Int

    /// Creates a selection snapshot.
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// Decides whether an Accessibility write can be believed.
///
/// Some hosts — Chromium web views in particular, which is what a VS Code extension panel is —
/// accept `AXSelectedText`, answer `.success`, and insert nothing. Trusting that answer means the
/// clipboard fallback never runs and the dictation is silently lost, so a write is only believed
/// when the caret is seen to move.
public enum InsertionVerificationPolicy {
    /// Whether the write landed, given the selection before and after it.
    ///
    /// Unreadable selections are trusted: many native fields expose no range, and pasting again
    /// on a write that did work would insert the text twice.
    public static func landed(
        before: TextSelection?,
        after: TextSelection?,
        insertedCharacterCount: Int
    ) -> Bool {
        guard insertedCharacterCount > 0 else { return true }
        guard let before, let after else { return true }
        return after != before
    }
}

/// Destination application and optional Accessibility element captured when dictation begins.
@MainActor
public struct TextInsertionTarget {
    fileprivate let element: AXUIElement?
    fileprivate let processIdentifier: pid_t
}

/// Inserts text into the focused macOS control, with a clipboard-preserving fallback.
@MainActor
public final class TextInjector {
    private let pasteboard: NSPasteboard
    private let restoreDelay: Duration

    /// Creates an injector backed by the system clipboard.
    public init(
        pasteboard: NSPasteboard = .general,
        restoreDelay: Duration = .milliseconds(180)
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
    }

    /// Reads everything the destination control currently holds, when the
    /// application exposes it over Accessibility.
    ///
    /// Nil is a normal answer, not a failure: plenty of destinations — web
    /// views, canvases, apps that decline the attribute — never expose a value,
    /// and the caller's job is to give up quietly rather than to guess.
    public func currentText(of target: TextInsertionTarget) -> String? {
        guard AXIsProcessTrusted(), let element = target.element else {
            return nil
        }
        // These reads are synchronous IPC into another process, made from the
        // main thread, repeatedly, well after the dictation ended. The system
        // default lets each one block for several seconds when the target app
        // is busy — long enough to freeze VoxoL's own UI over a feature the
        // user never asked to wait for. A watcher that misses one poll loses
        // nothing; a beachball costs trust.
        AXUIElementSetMessagingTimeout(element, 0.25)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        guard !isSecure(element: element) else {
            return nil
        }
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                == .success
        else {
            return nil
        }
        return value as? String
    }

    /// Captures the current editable destination before asynchronous transcription starts.
    public func captureTarget() throws -> TextInsertionTarget {
        guard AXIsProcessTrusted() else {
            throw TextInjectionError.accessibilityPermissionMissing
        }
        guard
            let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else {
            throw TextInjectionError.focusedElementUnavailable
        }
        let element = try? focusedUIElement(for: processIdentifier)
        if let element, isSecure(element: element) {
            throw TextInjectionError.secureField
        }
        return TextInsertionTarget(
            element: element,
            processIdentifier: processIdentifier
        )
    }

    /// Inserts text into a captured or currently focused non-secure control.
    public func insert(
        _ text: String,
        target: TextInsertionTarget? = nil
    ) async throws -> TextInsertionMethod {
        guard !text.isEmpty else {
            throw TextInjectionError.emptyText
        }
        guard AXIsProcessTrusted() else {
            throw TextInjectionError.accessibilityPermissionMissing
        }

        let insertionElement = target?.element ?? (try? focusedUIElement())
        if let insertionElement {
            guard !isSecure(element: insertionElement) else {
                throw TextInjectionError.secureField
            }

            // Web content answers this call with `.success` and does nothing, so the write is
            // only attempted where it can be checked, and only believed when the caret moved.
            if !isWebContent(element: insertionElement), canSetSelectedText(on: insertionElement) {
                let before = selection(of: insertionElement)
                let result = AXUIElementSetAttributeValue(
                    insertionElement,
                    "AXSelectedText" as CFString,
                    text as CFString
                )
                if result == .success,
                    InsertionVerificationPolicy.landed(
                        before: before,
                        after: selection(of: insertionElement),
                        insertedCharacterCount: text.count
                    )
                {
                    return .accessibility
                }
            }
        }

        let currentlyFocusedElement = try? focusedUIElement()
        let secureFieldDetected = currentlyFocusedElement.map(isSecure(element:)) ?? false
        let secureEventInputEnabled = IsSecureEventInputEnabled()
        guard !secureFieldDetected, !secureEventInputEnabled else {
            throw TextInjectionError.secureField
        }
        let currentProcessIdentifier =
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard
            InsertionDestinationPolicy.allowsAutomaticPaste(
                capturedProcessIdentifier: target?.processIdentifier,
                currentProcessIdentifier: currentProcessIdentifier,
                secureFieldDetected: secureFieldDetected,
                secureEventInputEnabled: secureEventInputEnabled
            )
        else {
            throw TextInjectionError.focusedElementUnavailable
        }
        try await pasteWithClipboardFallback(text)
        return .clipboardFallback
    }

    /// Leaves text on the clipboard when automatic insertion cannot identify a safe target.
    public func copyForManualPaste(_ text: String) throws {
        guard !text.isEmpty else {
            throw TextInjectionError.emptyText
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInjectionError.pasteboardWriteFailed
        }
    }
}

private extension TextInjector {
    func focusedUIElement(for preferredProcessIdentifier: pid_t? = nil) throws -> AXUIElement {
        let systemWideElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(
            systemWideElement,
            "AXFocusedUIElement" as CFString,
            &value
        )
        if result != .success,
            let processIdentifier = preferredProcessIdentifier
                ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        {
            let applicationElement = AXUIElementCreateApplication(processIdentifier)
            result = AXUIElementCopyAttributeValue(
                applicationElement,
                "AXFocusedUIElement" as CFString,
                &value
            )
        }
        guard
            result == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            throw TextInjectionError.focusedElementUnavailable
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    func isSecure(element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                "AXSubrole" as CFString,
                &value
            ) == .success,
            let subrole = value as? String
        else {
            return false
        }
        return subrole == "AXSecureTextField"
    }

    /// The caret and selection of a field, when Accessibility exposes them.
    func selection(of element: AXUIElement) -> TextSelection? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                "AXSelectedTextRange" as CFString,
                &value
            ) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else {
            return nil
        }
        return TextSelection(location: range.location, length: range.length)
    }

    /// Whether the element lives inside a rendered web page rather than a native control.
    ///
    /// Electron apps host their entire interface this way, so a VS Code editor, a chat panel and
    /// an extension view all land here.
    func isWebContent(element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        // The web area is a handful of levels above a focused field; the walk is bounded so a
        // malformed hierarchy cannot spin.
        for _ in 0..<6 {
            guard let inspected = current else { return false }
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(inspected, "AXRole" as CFString, &roleValue)
                == .success,
                let role = roleValue as? String,
                role == "AXWebArea"
            {
                return true
            }
            var parentValue: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(inspected, "AXParent" as CFString, &parentValue)
                    == .success,
                let parentValue,
                CFGetTypeID(parentValue) == AXUIElementGetTypeID()
            else {
                return false
            }
            current = unsafeDowncast(parentValue, to: AXUIElement.self)
        }
        return false
    }

    func canSetSelectedText(on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            "AXSelectedText" as CFString,
            &settable
        )
        return result == .success && settable.boolValue
    }

    func pasteWithClipboardFallback(_ text: String) async throws {
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInjectionError.pasteboardWriteFailed
        }
        let injectedChangeCount = pasteboard.changeCount

        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: false
            )
        else {
            snapshot.restore(to: pasteboard)
            throw TextInjectionError.pasteEventUnavailable
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        try? await Task.sleep(for: restoreDelay)
        if InsertionPolicy.shouldRestorePasteboard(
            injectedChangeCount: injectedChangeCount,
            currentChangeCount: pasteboard.changeCount
        ) {
            snapshot.restore(to: pasteboard)
        }
    }
}

private extension InsertionTextPolicy {
    static let punctuation = CharacterSet(charactersIn: ".,;:!?…)]}")
    static let opening = CharacterSet(charactersIn: "([{\n")

    static func needsLeadingSpace(before: Character?, inserted: Character?) -> Bool {
        guard let before, let inserted, !before.isWhitespace, !inserted.isWhitespace else {
            return false
        }
        return !contains(opening, before) && !contains(punctuation, inserted)
    }

    static func needsTrailingSpace(inserted: Character?, after: Character?) -> Bool {
        guard let inserted, let after, !inserted.isWhitespace, !after.isWhitespace else {
            return false
        }
        return !contains(opening, inserted) && !contains(punctuation, after)
    }

    static func contains(_ set: CharacterSet, _ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(set.contains)
    }
}

@MainActor
private struct PasteboardSnapshot {
    struct Item {
        let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    let items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(
                values: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                }
            )
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { item in
            let pasteboardItem = NSPasteboardItem()
            for value in item.values {
                pasteboardItem.setData(value.data, forType: value.type)
            }
            return pasteboardItem
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}
