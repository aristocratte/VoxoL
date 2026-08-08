import AppKit
import ApplicationServices
import Foundation

/// Bounded, ephemeral context captured from the focused macOS control.
public struct ContextSnapshot: Equatable, Sendable {
    /// Bundle identifier of the destination application.
    public let bundleIdentifier: String?
    /// Human-readable destination application name.
    public let applicationName: String
    /// Focused window title when Accessibility exposes it.
    public let windowTitle: String?
    /// Accessibility role of the focused control.
    public let controlRole: String?
    /// Selected text, capped by the provider.
    public let selectedText: String
    /// Text immediately before the cursor.
    public let beforeCursor: String
    /// Text immediately after the cursor.
    public let afterCursor: String
    /// Focused document URL when exposed by macOS.
    public let documentURL: URL?
    /// Whether the focused control is security-sensitive.
    public let isSecure: Bool

    /// Creates a bounded context snapshot.
    public init(
        bundleIdentifier: String?,
        applicationName: String,
        windowTitle: String? = nil,
        controlRole: String? = nil,
        selectedText: String = "",
        beforeCursor: String = "",
        afterCursor: String = "",
        documentURL: URL? = nil,
        isSecure: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.controlRole = controlRole
        self.selectedText = selectedText
        self.beforeCursor = beforeCursor
        self.afterCursor = afterCursor
        self.documentURL = documentURL
        self.isSecure = isSecure
    }

    /// Website domain derived from the document URL.
    public var domain: String? {
        documentURL?.host()
    }
}

/// Denies context capture for secure Accessibility roles and subroles.
public enum ContextSecurityPolicy {
    /// Returns whether the supplied Accessibility metadata marks a secure field.
    public static func isSecure(role: String?, subrole: String?) -> Bool {
        role == (kAXSecureTextFieldSubrole as String)
            || subrole == (kAXSecureTextFieldSubrole as String)
    }
}

/// Projects a full control value into bounded cursor context.
public enum ContextWindow {
    /// Returns the selected text and bounded strings around it.
    public static func project(
        text: String,
        selection: Range<String.Index>,
        beforeLimit: Int = 500,
        afterLimit: Int = 300
    ) -> (selected: String, before: String, after: String) {
        let selected = String(text[selection])
        let before = String(text[..<selection.lowerBound].suffix(beforeLimit))
        let after = String(text[selection.upperBound...].prefix(afterLimit))
        return (selected, before, after)
    }
}

/// Captures minimal context from the currently focused macOS application.
@MainActor
public final class MacOSContextProvider {
    /// Creates a context provider.
    public init() {}

    /// Captures a bounded snapshot, omitting text for secure controls.
    public func capture() -> ContextSnapshot {
        let application = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = application?.bundleIdentifier
        let applicationName = application?.localizedName ?? "Unknown"
        guard AXIsProcessTrusted(), let processIdentifier = application?.processIdentifier else {
            return ContextSnapshot(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName
            )
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let focusedElement = elementAttribute(
            kAXFocusedUIElementAttribute as String,
            from: applicationElement
        )
        let role = stringAttribute(kAXRoleAttribute as String, from: focusedElement)
        let subrole = stringAttribute(kAXSubroleAttribute as String, from: focusedElement)
        let secure = ContextSecurityPolicy.isSecure(role: role, subrole: subrole)
        let window = elementAttribute(kAXFocusedWindowAttribute as String, from: applicationElement)
        let title = stringAttribute(kAXTitleAttribute as String, from: window)
        let document = stringAttribute(kAXDocumentAttribute as String, from: window)
            .flatMap(URL.init(string:))

        guard !secure, let focusedElement else {
            return ContextSnapshot(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName,
                windowTitle: title,
                controlRole: role,
                documentURL: document,
                isSecure: secure
            )
        }

        let selected = String(
            (stringAttribute(kAXSelectedTextAttribute as String, from: focusedElement) ?? "")
                .prefix(1_000)
        )
        let nearby = nearbyText(from: focusedElement)
        return ContextSnapshot(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            windowTitle: title,
            controlRole: role,
            selectedText: selected,
            beforeCursor: nearby.before,
            afterCursor: nearby.after,
            documentURL: document
        )
    }
}

@MainActor
private extension MacOSContextProvider {
    func nearbyText(from element: AXUIElement) -> (before: String, after: String) {
        guard
            let selectedRange = rangeAttribute(
                kAXSelectedTextRangeAttribute as String, from: element)
        else {
            return ("", "")
        }

        let beforeLength = min(500, selectedRange.location)
        let beforeRange = CFRange(
            location: selectedRange.location - beforeLength,
            length: beforeLength
        )
        let afterRange = CFRange(
            location: selectedRange.location + selectedRange.length,
            length: 300
        )
        return (
            parameterizedString(range: beforeRange, from: element),
            parameterizedString(range: afterRange, from: element)
        )
    }

    func elementAttribute(_ name: String, from element: AXUIElement?) -> AXUIElement? {
        guard let element else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    func stringAttribute(_ name: String, from element: AXUIElement?) -> String? {
        guard let element else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    func rangeAttribute(_ name: String, from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard
            AXValueGetType(axValue) == .cfRange
        else {
            return nil
        }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    func parameterizedString(range: CFRange, from element: AXUIElement) -> String {
        guard range.length > 0 else {
            return ""
        }
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            return ""
        }
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &value
            ) == .success
        else {
            return ""
        }
        return value as? String ?? ""
    }
}
