import AppKit
import SwiftUI

// The Hub's building blocks. The chrome is neutral and native: SF Pro, 28 pt controls, flat tone
// steps instead of borders. Colour is kept for data (cobalt), the live voice (coral) and the
// dithered prints, which are the only pictures the Hub shows.

extension String {
    /// Resolves a string in the language VoxoL's interface is set to.
    ///
    /// `String(localized:)` alone follows the system language, so a Mac set to English showed
    /// English words inside a French interface. The interface language reaches views as the
    /// environment's locale; this carries it into the lookup.
    init(_ resource: LocalizedStringResource, in locale: Locale) {
        var resource = resource
        resource.locale = locale
        self.init(localized: resource)
    }
}

extension String {
    /// "mercredi 4 novembre" → "Mercredi 4 novembre": only the first letter, the way French
    /// writes dates. `capitalized` would also capitalise the month.
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}

enum EditorialMotion {
    static let fluid = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.32)
    static let soft = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.22)
}

// MARK: - Icons

private enum EditorialIconLibrary {
    static let images: [String: NSImage] = {
        let names = [
            "arrow-right", "books", "caret-right", "chart-line-up", "check", "clock",
            "command", "copy", "download-simple", "gear-six", "house", "lock-key",
            "microphone", "pause", "play", "shield-check", "sliders-horizontal",
            "speaker-high", "text-aa", "users-three", "waveform",
        ]
        return Dictionary(
            uniqueKeysWithValues: names.compactMap { name in
                let url =
                    Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "icons")
                    ?? Bundle.main.url(forResource: name, withExtension: "svg")
                guard let url, let image = NSImage(contentsOf: url) else {
                    return nil
                }
                image.isTemplate = true
                return (name, image)
            })
    }()
}

struct EditorialIcon: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image = EditorialIconLibrary.images[name] {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: "questionmark")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}

/// Resolves and remembers destination applications, so lists show the apps the user actually
/// dictated into rather than a generic glyph.
@MainActor
enum ApplicationIconCache {
    private static var cache: [String: NSImage?] = [:]

    /// The name macOS shows for an application, so rules read as apps and not as bundle ids.
    static func name(forBundleIdentifier bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    static func icon(forBundleIdentifier bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if let cached = cache[bundleIdentifier] { return cached }
        let resolved = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        )
        .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleIdentifier] = resolved
        return resolved
    }
}

struct HubAppIcon: View {
    @Environment(VoxoLTheme.self) private var theme

    let bundleIdentifier: String?
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let icon = ApplicationIconCache.icon(forBundleIdentifier: bundleIdentifier) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.light)
                    .foregroundStyle(theme.secondaryInk.opacity(0.6))
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Page

/// A Hub page: a centred reading column that scrolls, the same width on every screen.
struct HubPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

/// The page title, an optional count beside it, and the page's one action on the right.
struct HubPageHeader<Trailing: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    let title: Text
    var meta: Text?
    let trailing: Trailing

    init(title: LocalizedStringKey, meta: Text? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(title)
        self.meta = meta
        self.trailing = trailing()
    }

    /// For screens that word their titles themselves.
    init(verbatim title: String, meta: Text? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(verbatim: title)
        self.meta = meta
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                title
                    .font(VoxoLTypography.font(size: 22, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if let meta {
                    meta
                        .font(VoxoLTypography.font(size: 14))
                        .foregroundStyle(theme.secondaryInk)
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            Spacer(minLength: 16)
            trailing
        }
        .frame(minHeight: 32)
    }
}

extension HubPageHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, meta: Text? = nil) {
        self.init(title: title, meta: meta) { EmptyView() }
    }
}

/// A block's title, with a quiet note or an action at its right end.
struct HubSectionHeader<Trailing: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    let title: Text
    let trailing: Trailing

    init(title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(title)
        self.trailing = trailing()
    }

    init(verbatim title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(verbatim: title)
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            title
                .font(VoxoLTypography.font(size: 15, weight: .semibold))
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            trailing
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.secondaryInk)
                .monospacedDigit()
        }
        .padding(.top, 28)
        .padding(.bottom, 8)
    }
}

extension HubSectionHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey) {
        self.init(title: title) { EmptyView() }
    }

    init(verbatim title: String) {
        self.init(verbatim: title) { EmptyView() }
    }
}

// MARK: - Controls

/// The Hub's buttons: one near-black primary per screen, the rest flat tone steps.
struct HubButtonStyle: ButtonStyle {
    enum Kind {
        /// The page's one action.
        case primary
        /// A plain action on the page.
        case secondary
        /// A plain action sitting on a grouped panel, which is already one tone down.
        case onWell
        /// A quiet action that only shows a fill when pointed at.
        case ghost
    }

    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        HubButtonBody(configuration: configuration, kind: kind)
    }
}

private struct HubButtonBody: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    let configuration: ButtonStyle.Configuration
    let kind: HubButtonStyle.Kind

    var body: some View {
        configuration.label
            .font(VoxoLTypography.font(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, kind == .ghost ? 8 : 12)
            .frame(minHeight: 28)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: theme.surface
        case .ghost: hovering ? theme.ink : theme.secondaryInk
        case .secondary, .onWell: theme.ink
        }
    }

    private var fill: Color {
        let active = hovering && isEnabled
        switch kind {
        case .primary: return theme.ink.opacity(active ? 0.86 : 1)
        case .secondary: return active ? theme.selection : theme.well
        case .onWell: return active ? theme.selection : theme.surface
        case .ghost: return active ? theme.selection : .clear
        }
    }
}

/// A key or a shortcut, drawn as a small keycap.
struct HubKeycap: View {
    @Environment(VoxoLTheme.self) private var theme

    let label: String
    var fill: Color?
    var ink: Color?

    var body: some View {
        Text(verbatim: label)
            .font(VoxoLTypography.font(size: 12, weight: .medium))
            .foregroundStyle(ink ?? theme.ink)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(
                fill ?? theme.selection, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize()
    }
}

/// A segmented control: a recessed track with the selected option raised in white.
struct HubSegmented<Option: Hashable>: View {
    @Environment(VoxoLTheme.self) private var theme
    @Namespace private var namespace

    let options: [Option]
    @Binding var selection: Option
    var track: Color?
    let label: (Option) -> Text

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                Button {
                    withAnimation(EditorialMotion.soft) { selection = option }
                } label: {
                    label(option)
                        .font(VoxoLTypography.font(size: 13, weight: .medium))
                        .foregroundStyle(selected ? theme.ink : theme.secondaryInk)
                        .monospacedDigit()
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.surface)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "thumb", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(track ?? theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }
}

/// A switch in the Hub's ink rather than the system accent.
struct HubSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HubSwitch(configuration: configuration)
    }
}

private struct HubSwitch: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.isEnabled) private var isEnabled

    let configuration: ToggleStyle.Configuration

    var body: some View {
        Button {
            withAnimation(EditorialMotion.soft) { configuration.isOn.toggle() }
        } label: {
            Capsule()
                .fill(configuration.isOn ? theme.ink : theme.selection)
                .frame(width: 30, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// MARK: - Grouped settings

/// The small grey title above a grouped panel.
struct HubGroupTitle: View {
    @Environment(VoxoLTheme.self) private var theme

    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(VoxoLTypography.font(size: 13, weight: .semibold))
            .foregroundStyle(theme.secondaryInk)
            .padding(.leading, 2)
            .padding(.top, 24)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rows grouped on one tone step below the page, like a macOS settings form.
struct HubPanel<Content: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One setting: its name, an optional second line when the name is not enough, the control.
struct HubField<Control: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    let title: Text
    var detail: Text?
    let control: Control

    init(title: LocalizedStringKey, detail: Text? = nil, @ViewBuilder control: () -> Control) {
        self.title = Text(title)
        self.detail = detail
        self.control = control()
    }

    init(verbatim title: String, detail: Text? = nil, @ViewBuilder control: () -> Control) {
        self.title = Text(verbatim: title)
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.ink)
                if let detail {
                    detail
                        .font(VoxoLTypography.font(size: 12))
                        .foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.vertical, detail == nil ? 0 : 10)
        .frame(minHeight: 46)
    }
}

// MARK: - Cards and rows

/// Something VoxoL made for you, with a strip of dithered print along its left edge.
struct HubDitherCard<Content: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    let art: String
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 132)
            .background(alignment: .leading) {
                Image(art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 132)
                    .clipped()
                    .accessibilityHidden(true)
            }
            .background(theme.well)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    /// A row that answers the pointer with one tone step.
    func hubRowHover(_ hovering: Bool, selected: Bool = false) -> some View {
        modifier(HubRowHoverModifier(hovering: hovering, selected: selected))
    }
}

private struct HubRowHoverModifier: ViewModifier {
    @Environment(VoxoLTheme.self) private var theme

    let hovering: Bool
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .background(
                (hovering || selected) ? theme.well : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The field a page searches with; ⌘F focuses it, Escape clears it.
struct HubSearchField: View {
    @Environment(VoxoLTheme.self) private var theme

    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryInk)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.ink)
                .focused(focus)
                .onExitCommand {
                    if text.isEmpty { focus.wrappedValue = false } else { text = "" }
                }
            if text.isEmpty {
                HubKeycap(label: "⌘F", fill: theme.surface)
            } else {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(width: 220, height: 28)
        .background(theme.well, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .background {
            Button("Search") { focus.wrappedValue = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }
}
