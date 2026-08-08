import SwiftUI

struct StudioPage<Content: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    let summary: LocalizedStringKey
    private let content: Content

    init(
        eyebrow: LocalizedStringKey,
        title: LocalizedStringKey,
        summary: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.summary = summary
        self.content = content()
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                StudioHeader(eyebrow: eyebrow, title: title, summary: summary)
                content
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
    }
}

struct StudioSection<Content: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    let title: LocalizedStringKey
    let summary: LocalizedStringKey?
    private let content: Content

    init(
        _ title: LocalizedStringKey,
        summary: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.summary = summary
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.ink)
                if let summary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryInk)
                }
            }
            content
        }
    }
}

struct FeatureStatusCard: View {
    @Environment(VoxoLTheme.self) private var theme

    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let status: LocalizedStringKey
    var tone: Color?

    var body: some View {
        VoxoLCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tone ?? theme.secondaryInk)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(theme.ink)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ShowcaseSurface<Content: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(28)
            .frame(maxWidth: .infinity, minHeight: 240)
            .background(theme.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(theme.line, lineWidth: 1)
            }
    }
}

struct PrototypeWaveform: View {
    @Environment(VoxoLTheme.self) private var theme

    var tone: Color?
    var height: CGFloat = 34

    private let levels: [CGFloat] = [0.35, 0.7, 1, 0.58, 0.82, 0.46, 0.68, 0.3]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(tone ?? theme.ink)
                    .frame(width: 4, height: max(5, height * level))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct DemoCapsule: View {
    @Environment(VoxoLTheme.self) private var theme

    let label: LocalizedStringKey
    var isRecording = true
    var shortcut = "esc"
    var indicatorTone: Color?

    var body: some View {
        HStack(spacing: 13) {
            Circle()
                .fill(indicatorTone ?? (isRecording ? theme.recording : theme.success))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            PrototypeWaveform(tone: theme.ink, height: 26)
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.ink)
            Spacer(minLength: 10)
            KeyboardShortcutBadge(keys: shortcut)
        }
        .padding(.leading, 17)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: 390)
        .background(theme.raisedSurface)
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(theme.line, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 20, y: 10)
    }
}

struct SettingLine<Control: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    private let control: Control

    init(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            control
        }
        .padding(.vertical, 4)
    }
}

struct ComingSoonBanner: View {
    @Environment(VoxoLTheme.self) private var theme

    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Coming soon")
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryInk)
            }
            Spacer()
        }
        .padding(16)
        .background(theme.selection)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct LocalOnlyNote: View {
    @Environment(VoxoLTheme.self) private var theme

    let text: LocalizedStringKey

    var body: some View {
        Label(text, systemImage: "lock")
            .font(.caption)
            .foregroundStyle(theme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Signal editorial components

enum HubSignalMode: Equatable {
    case idle
    case voice
    case processing
    case insights
    case meeting
}

struct SignalCard<Content: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    var tint: Color?
    var padding: CGFloat = 18
    var cornerRadius: CGFloat = 18
    private let content: Content

    init(
        tint: Color? = nil,
        padding: CGFloat = 18,
        cornerRadius: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) {
        self.tint = tint
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(tint ?? theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(theme.line.opacity(0.8), lineWidth: 1)
            }
            .shadow(color: theme.ink.opacity(0.035), radius: 10, y: 4)
    }
}

struct SignalPageHeader<Trailing: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    let summary: LocalizedStringKey
    private let trailing: Trailing

    init(
        eyebrow: LocalizedStringKey,
        title: LocalizedStringKey,
        summary: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.summary = summary
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow)
                    .font(
                        VoxoLTypography.font(
                            size: 11, weight: .semibold, relativeTo: .caption)
                    )
                    .foregroundStyle(theme.secondaryInk)
                    .textCase(.uppercase)
                    .tracking(0.9)

                Text(title)
                    .font(
                        VoxoLTypography.font(
                            size: 34, weight: .semibold, relativeTo: .largeTitle)
                    )
                    .foregroundStyle(theme.ink)
                    .tracking(-0.8)
                    .lineLimit(2)
                    .minimumScaleFactor(0.84)

                Text(summary)
                    .font(VoxoLTypography.font(size: 15, relativeTo: .body))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
    }
}

extension SignalPageHeader where Trailing == EmptyView {
    init(
        eyebrow: LocalizedStringKey,
        title: LocalizedStringKey,
        summary: LocalizedStringKey
    ) {
        self.init(eyebrow: eyebrow, title: title, summary: summary) {
            EmptyView()
        }
    }
}

struct SignalEyebrow: View {
    @Environment(VoxoLTheme.self) private var theme

    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(VoxoLTypography.font(size: 10.5, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(theme.secondaryInk)
            .textCase(.uppercase)
            .tracking(0.8)
    }
}

struct SignalStatusChip: View {
    @Environment(VoxoLTheme.self) private var theme

    let title: LocalizedStringKey
    var color: Color? = nil
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            } else {
                Circle()
                    .fill(color ?? theme.success)
                    .frame(width: 7, height: 7)
            }
            Text(title)
        }
        .font(VoxoLTypography.font(size: 11.5, weight: .semibold, relativeTo: .caption))
        .foregroundStyle(color ?? theme.success)
        .padding(.horizontal, 11)
        .frame(minHeight: 32)
        .background((color ?? theme.success).opacity(0.09))
        .clipShape(Capsule())
    }
}

struct SignalIconButton: View {
    @Environment(VoxoLTheme.self) private var theme

    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: 42, height: 42)
                .background(theme.selection.opacity(0.74))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SignalPressButtonStyle())
        .help(help)
    }
}

struct SignalMetricTile: View {
    @Environment(VoxoLTheme.self) private var theme

    let value: String
    let label: LocalizedStringKey
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(
                    VoxoLTypography.font(size: 25, weight: .semibold, relativeTo: .title2)
                )
                .foregroundStyle(tint ?? theme.ink)
                .monospacedDigit()
            Text(label)
                .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SignalPressButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.48)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

struct SignalPrimaryButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoxoLTypography.font(size: 16, weight: .semibold, relativeTo: .body))
            .foregroundStyle(isEnabled ? theme.surface : theme.secondaryInk)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(isEnabled ? theme.ink : theme.selection)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1)
            .shadow(color: theme.ink.opacity(isEnabled ? 0.14 : 0), radius: 12, y: 8)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

struct SignalSecondaryButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoxoLTypography.font(size: 13, weight: .semibold, relativeTo: .body))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(configuration.isPressed ? theme.selection : theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(theme.line, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.48)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

/// How busy the signal is allowed to be. Kept as the Hub-facing name for `VoxoLSignalCadence`.
typealias HubSignalCadence = VoxoLSignalCadence

/// The Hub's signal band. The field itself lives in `VoxoLSignalField`, drawn by a Metal shader
/// so it can run at display rate instead of being rebuilt on the CPU every frame.
struct HubDitherField: View {
    let mode: HubSignalMode
    var cadence: HubSignalCadence = .ambient

    var body: some View {
        VoxoLSignalField(mode: signalMode, cadence: cadence)
    }

    private var signalMode: VoxoLSignalMode {
        switch mode {
        case .idle: .idle
        case .voice: .voice
        case .processing: .processing
        case .insights: .insights
        case .meeting: .meeting
        }
    }
}

struct SignalPaperTexture: View {
    @Environment(VoxoLTheme.self) private var theme

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 22
            for x in stride(from: CGFloat.zero, through: size.width, by: spacing) {
                for y in stride(from: CGFloat.zero, through: size.height, by: spacing) {
                    let noise = abs(sin(x * 0.37 + y * 0.71))
                    guard noise > 0.66 else {
                        continue
                    }
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: x + noise * 4,
                                y: y + noise * 3,
                                width: 0.8,
                                height: 0.8
                            )
                        ),
                        with: .color(theme.ink.opacity(0.025))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Raw versus final

/// The diff as one flowing paragraph: struck-through what the model dropped, tinted what it added.
struct TranscriptDiffText: View {
    @Environment(VoxoLTheme.self) private var theme

    let tokens: [TranscriptDiff.Token]
    var size: CGFloat = 14

    var body: some View {
        Text(attributed)
            .font(VoxoLTypography.font(size: size, relativeTo: .body))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for token in tokens {
            var piece = AttributedString(token.text)
            switch token.change {
            case .unchanged:
                piece.foregroundColor = theme.ink
            case .removed:
                piece.foregroundColor = theme.secondaryInk
                piece.strikethroughStyle = .single
                piece.backgroundColor = theme.coralSoft.opacity(0.75)
            case .added:
                piece.foregroundColor = theme.ink
                piece.backgroundColor = theme.sageSoft
            }
            result.append(piece)
            result.append(AttributedString(" "))
        }
        return result
    }
}

/// Legend for the diff, so the two tints are never a guess.
struct TranscriptDiffLegend: View {
    @Environment(VoxoLTheme.self) private var theme

    var body: some View {
        HStack(spacing: 14) {
            marker(colour: theme.coralSoft.opacity(0.75), label: "Heard")
            marker(colour: theme.sageSoft, label: "Written by VoxoL")
        }
        .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
        .foregroundStyle(theme.secondaryInk)
    }

    private func marker(colour: Color, label: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(colour)
                .frame(width: 14, height: 10)
            Text(label)
        }
    }
}

// MARK: - Audio input

/// Picks which microphone VoxoL records from.
///
/// The list is read when the menu opens rather than cached, so a headset plugged in a second ago
/// is there and one unplugged a second ago is not. An empty selection means "follow the system
/// default", and a stored device that has since disappeared says so instead of pretending.
struct AudioInputPicker: View {
    @Environment(VoxoLTheme.self) private var theme

    @Binding var selectedUID: String
    /// Compact hides the leading label, for placement beside a primary action.
    var compact = false

    var body: some View {
        Menu {
            Button {
                selectedUID = ""
            } label: {
                menuLabel(String(localized: "System default"), selected: selectedUID.isEmpty)
            }

            let devices = AudioInputDevices.available()
            if !devices.isEmpty {
                Divider()
                ForEach(devices) { device in
                    Button {
                        selectedUID = device.id
                    } label: {
                        menuLabel(device.name, selected: device.id == selectedUID)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic")
                    .font(.system(size: 11, weight: .medium))
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.secondaryInk)
            }
            .font(VoxoLTypography.font(size: 11.5, weight: .medium, relativeTo: .caption))
            .foregroundStyle(isMissing ? theme.warning : theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: compact ? 196 : 260, alignment: .leading)
            .background(theme.selection)
            .clipShape(Capsule())
        }
        // .borderlessButton replaces the custom label with its own tinted text; .button plus a
        // plain button style renders the capsule as written.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Input device"))
        .accessibilityLabel(Text("Input device"))
    }

    /// What the button shows: the chosen device, or the one macOS is currently defaulting to.
    private var title: String {
        guard !selectedUID.isEmpty else {
            let devices = AudioInputDevices.available()
            let fallback = devices.first { $0.isDefault } ?? devices.first
            return fallback?.name ?? String(localized: "System default")
        }
        guard let device = AudioInputDevices.available().first(where: { $0.id == selectedUID })
        else {
            return String(localized: "Microphone disconnected")
        }
        return device.name
    }

    private var isMissing: Bool {
        !selectedUID.isEmpty
            && !AudioInputDevices.available().contains { $0.id == selectedUID }
    }

    @ViewBuilder
    private func menuLabel(_ name: String, selected: Bool) -> some View {
        if selected {
            Label {
                Text(verbatim: name)
            } icon: {
                Image(systemName: "checkmark")
            }
        } else {
            Text(verbatim: name)
        }
    }
}
