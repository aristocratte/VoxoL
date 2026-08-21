import AppKit
import PersonalizationKit
import SwiftUI
import TextProcessingKit

// MARK: - Prototype-parity foundations

enum EditorialMotion {
    static let fluid = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.32)
    static let stagger = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.48)
    static let soft = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.22)
}

/// The Hub's density. Everything on a screen is measured from here, so the whole interface can be
/// tightened or loosened in one place rather than screen by screen.
private struct EditorialMetrics {
    let compact: Bool

    init(_ size: CGSize) {
        compact = size.width < 760
    }

    /// Margins are the design: the page breathes at its edges before anything else does.
    var pagePadding: CGFloat { compact ? 26 : 38 }
    /// Space under a page header, before the first block.
    var headingGap: CGFloat { compact ? 26 : 34 }
    /// Space between two blocks of the same page.
    var cardGap: CGFloat { compact ? 20 : 26 }
    var titleSize: CGFloat { compact ? 23 : 26 }
    var summarySize: CGFloat { compact ? 12.5 : 13 }
    var eyebrowSize: CGFloat { 10.5 }
    var bodySize: CGFloat { compact ? 13 : 13.5 }
    /// Blocks no longer sit in boxes, so the old card padding is only used where a real surface
    /// remains (menus, sheets, controls).
    var cardPadding: CGFloat { compact ? 14 : 16 }
    /// A list row you can read without leaning in.
    var rowHeight: CGFloat { compact ? 46 : 52 }
}

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

private struct EditorialPageHeader<Trailing: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    let metrics: EditorialMetrics
    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    let summary: LocalizedStringKey
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: metrics.compact ? 16 : 28) {
            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow)
                    .font(
                        VoxoLTypography.font(
                            size: metrics.eyebrowSize, weight: .semibold, relativeTo: .caption)
                    )
                    .foregroundStyle(theme.secondaryInk)
                    .textCase(.uppercase)
                    .tracking(1)

                Text(title)
                    .font(
                        VoxoLTypography.font(
                            size: metrics.titleSize,
                            weight: .semibold,
                            relativeTo: .title
                        )
                    )
                    .foregroundStyle(theme.ink)
                    .tracking(-0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 6)

                Text(summary)
                    .font(VoxoLTypography.font(size: metrics.summarySize, relativeTo: .body))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
                    .padding(.top, 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
    }
}

private extension EditorialPageHeader where Trailing == EmptyView {
    init(
        metrics: EditorialMetrics,
        eyebrow: LocalizedStringKey,
        title: LocalizedStringKey,
        summary: LocalizedStringKey
    ) {
        self.init(metrics: metrics, eyebrow: eyebrow, title: title, summary: summary) {
            EmptyView()
        }
    }
}

/// A block of a page.
///
/// It used to draw a filled, bordered, shadowed box — on a detail panel that is itself a filled,
/// bordered surface. Two levels of container around every paragraph is what made the interface
/// feel cramped no matter how small the type got. A block is now just its content: separation
/// comes from the space around it, and from `editorialRule()` when a real boundary is needed.
private struct EditorialCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
    }
}

/// The one-pixel boundary the design allows itself.
private struct EditorialRule: View {
    @Environment(VoxoLTheme.self) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.line)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A titled block: a quiet label, an optional action on the right, then the content.
private struct EditorialSection<Content: View, Trailing: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    let metrics: EditorialMetrics
    let title: LocalizedStringKey
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(
                        VoxoLTypography.font(
                            size: metrics.eyebrowSize, weight: .semibold, relativeTo: .caption)
                    )
                    .foregroundStyle(theme.secondaryInk)
                    .textCase(.uppercase)
                    .tracking(1)
                Spacer(minLength: 8)
                trailing
            }
            .frame(minHeight: 24)

            content
                .padding(.top, metrics.compact ? 10 : 12)
        }
    }
}

extension EditorialSection where Trailing == EmptyView {
    fileprivate init(
        metrics: EditorialMetrics,
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.init(metrics: metrics, title: title, trailing: { EmptyView() }, content: content)
    }
}

private struct EditorialStaggerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let visible: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(visible || reduceMotion ? 1 : 0)
            .blur(radius: visible || reduceMotion ? 0 : 4)
            .offset(y: visible || reduceMotion ? 0 : 16)
            .animation(
                reduceMotion ? nil : EditorialMotion.stagger.delay(Double(index) * 0.08),
                value: visible
            )
    }
}

private extension View {
    func editorialStagger(_ index: Int, visible: Bool) -> some View {
        modifier(EditorialStaggerModifier(visible: visible, index: index))
    }

    /// A page band that keeps a floor at the minimum window size and then grows with the window,
    /// instead of holding a fixed height and leaving dead space under the content.
    func editorialBand(min floor: CGFloat, max ceiling: CGFloat = .infinity) -> some View {
        frame(minHeight: floor, maxHeight: ceiling)
    }
}

private struct EditorialIconButton: View {
    @Environment(VoxoLTheme.self) private var theme

    let icon: String
    let label: LocalizedStringKey
    var size: CGFloat = 44
    /// Drawn from SF Symbols instead of the editorial set, for actions the set has no glyph for.
    var systemSymbol = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            glyph
                .foregroundStyle(theme.ink)
                .frame(width: size, height: size)
                .background(theme.selection)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .stroke(Color.black.opacity(0.04), lineWidth: 1)
                }
        }
        .buttonStyle(SignalPressButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var glyph: some View {
        if systemSymbol {
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .medium))
        } else {
            EditorialIcon(name: icon, size: size * 0.48)
        }
    }
}

/// A label-plus-glyph button for card actions that need to name themselves.
private struct EditorialActionChip: View {
    @Environment(VoxoLTheme.self) private var theme

    let title: LocalizedStringKey
    let systemSymbol: String
    var tone: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemSymbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(VoxoLTypography.font(size: 11.5, weight: .semibold, relativeTo: .caption))
            }
            .foregroundStyle(tone ?? theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(theme.selection)
            .clipShape(Capsule())
            .overlay { Capsule().stroke(Color.black.opacity(0.05), lineWidth: 1) }
        }
        .buttonStyle(SignalPressButtonStyle())
        .accessibilityLabel(title)
    }
}

private struct EditorialStatusChip: View {
    @Environment(VoxoLTheme.self) private var theme

    let title: LocalizedStringKey
    var tone: Color? = nil
    var filledDot = true

    var body: some View {
        HStack(spacing: 8) {
            if filledDot {
                Circle()
                    .fill(tone ?? theme.success)
                    .frame(width: 8, height: 8)
            }
            Text(title)
        }
        .font(VoxoLTypography.font(size: 10.5, weight: .semibold, relativeTo: .caption))
        .foregroundStyle(tone ?? theme.success)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .frame(minHeight: 24)
        .background((tone ?? theme.success).opacity(0.09))
        .clipShape(Capsule())
    }
}

private struct EditorialSegmentedControl<Option: Hashable, Label: View>: View {
    @Environment(VoxoLTheme.self) private var theme
    @Namespace private var namespace

    let options: [Option]
    @Binding var selection: Option
    @ViewBuilder let label: (Option) -> Label

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(EditorialMotion.soft) {
                        selection = option
                    }
                } label: {
                    label(option)
                        .font(VoxoLTypography.font(size: 14, weight: .medium, relativeTo: .body))
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(theme.surface)
                                    .shadow(color: Color.black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                }
                .buttonStyle(SignalPressButtonStyle())
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(4)
        .background(theme.selection)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EditorialWaveMini: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let heights: [CGFloat] = [12, 20, 16, 22, 10]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                    Capsule()
                        .fill(theme.coral)
                        .frame(width: 2, height: height)
                        .scaleEffect(
                            x: 1,
                            y: reduceMotion
                                ? 1
                                : 0.725 + 0.275 * sin(time * 6.55 + Double(index) * 0.82)
                        )
                }
            }
            .frame(height: 24)
        }
        .accessibilityHidden(true)
    }
}

private struct EditorialDictationTriggerModifier: ViewModifier {
    @Environment(DictationSessionCoordinator.self) private var dictationSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let setupReady: Bool
    let openSetup: () -> Void

    @State private var pointerDown = false
    @State private var sentPress = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pointerDown && !reduceMotion ? 0.97 : 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pointerDown else { return }
                        pointerDown = true
                        guard setupReady else { return }
                        sentPress = true
                        dictationSession.pressDictationTrigger()
                    }
                    .onEnded { _ in
                        if sentPress {
                            dictationSession.releaseDictationTrigger()
                        } else {
                            openSetup()
                        }
                        sentPress = false
                        pointerDown = false
                    }
            )
            .animation(reduceMotion ? nil : EditorialMotion.soft, value: pointerDown)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if setupReady {
                    dictationSession.toggleDictationFromInterface()
                } else {
                    openSetup()
                }
            }
    }
}

private extension View {
    func editorialDictationTrigger(setupReady: Bool, openSetup: @escaping () -> Void) -> some View {
        modifier(EditorialDictationTriggerModifier(setupReady: setupReady, openSetup: openSetup))
    }
}

// MARK: - Today

struct EditorialTodayView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts
    @Environment(DictationSessionCoordinator.self) private var dictationSession
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let setupReady: Bool
    let openInsights: () -> Void
    let openSettings: () -> Void
    let openSetup: () -> Void

    @AppStorage("voxol.activationMode") private var activationMode = ActivationMode.hold
    @AppStorage("voxol.dictationShortcut") private var shortcut = DictationShortcut.optionSpace
    @AppStorage("voxol.inputDeviceUID") private var inputDeviceUID = ""
    @State private var visible = false
    @State private var inspectedRecord: TranscriptRecord?
    @State private var recentCardIsHovered = false
    @State private var hoveredRecordID: UUID?

    var body: some View {
        GeometryReader { geometry in
            let metrics = EditorialMetrics(geometry.size)
            let sidebarWidth: CGFloat = metrics.compact ? 0 : 232

            HStack(alignment: .top, spacing: metrics.compact ? 0 : 26) {
                VStack(alignment: .leading, spacing: 0) {
                    welcomeHeader(metrics: metrics)
                        .editorialStagger(0, visible: visible)

                    triggerRow(metrics: metrics)
                        .padding(.top, metrics.compact ? 18 : 24)
                        .editorialStagger(1, visible: visible)

                    if metrics.compact {
                        statsRow(metrics: metrics)
                            .padding(.top, 18)
                            .editorialStagger(2, visible: visible)
                    }

                    historyFeed(metrics: metrics)
                        .padding(.top, metrics.compact ? 22 : 30)
                        .frame(maxHeight: .infinity)
                        .editorialStagger(2, visible: visible)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !metrics.compact {
                    statsColumn(metrics: metrics)
                        .frame(width: sidebarWidth)
                        .editorialStagger(3, visible: visible)
                }
            }
            .padding(.horizontal, metrics.pagePadding)
            .padding(.top, metrics.pagePadding)
            .padding(.bottom, metrics.compact ? 16 : 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { reveal() }
        .onDisappear { visible = false }
        .sheet(item: $inspectedRecord) { record in
            TranscriptDetailSheet(record: record, store: transcripts)
                .environment(theme)
        }
    }

    /// A home page should say hello and name the day, not open on a control panel.
    private func welcomeHeader(metrics: EditorialMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey("Welcome back, \(accountName)"))
                .font(
                    VoxoLTypography.font(
                        size: metrics.compact ? 25 : 30, weight: .semibold, relativeTo: .largeTitle)
                )
                .foregroundStyle(theme.ink)
                .tracking(-0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// The macOS account's first name, which is the only name VoxoL knows without asking.
    private var accountName: String {
        let full = NSFullUserName()
        let first = full.split(separator: " ").first.map(String.init) ?? full
        return first.isEmpty ? NSUserName() : first
    }

    /// The one action of the page, its live state, and the microphone it will use.
    private func triggerRow(metrics: EditorialMetrics) -> some View {
        HStack(spacing: metrics.compact ? 12 : 16) {
            HStack(spacing: 9) {
                EditorialIcon(
                    name: setupReady ? "microphone" : "sliders-horizontal", size: 16)
                Text(setupReady ? primaryActionLabel : LocalizedStringKey("Finish setup"))
                    .lineLimit(1)
                    .fixedSize()
                if setupReady {
                    Text(verbatim: shortcut.label)
                        .font(
                            VoxoLTypography.font(size: 11, weight: .medium, relativeTo: .caption)
                        )
                        .foregroundStyle(theme.surface.opacity(0.7))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .font(VoxoLTypography.font(size: 14, weight: .semibold, relativeTo: .body))
            .foregroundStyle(theme.surface)
            .padding(.horizontal, 18)
            .frame(height: 46)
            .background(theme.ink)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .fixedSize()
            .layoutPriority(1)
            .editorialDictationTrigger(setupReady: setupReady, openSetup: openSetup)
            .help(setupReady ? Text(primaryActionLabel) : Text("Open guided setup"))
            .accessibilityLabel(setupReady ? Text(primaryActionLabel) : Text("Finish setup"))

            // The live state lives here and nowhere else: it used to be repeated in the window
            // bar, which said the same thing twice in two different wordings.
            if setupReady {
                EditorialStatusChip(title: runtimeStatus, tone: runtimeTone)
                    .help(Text(runtimeStatusHelp ?? runtimeStatus))
            } else {
                Button(action: openSetup) {
                    EditorialStatusChip(title: "Setup required", tone: theme.warning)
                }
                .buttonStyle(SignalPressButtonStyle())
                .help("Open guided setup")
            }

            Spacer(minLength: 8)

            AudioInputPicker(selectedUID: $inputDeviceUID, compact: metrics.compact)
        }
    }

    /// The history, grouped by day, as the substance of the page rather than a footnote.
    private func historyFeed(metrics: EditorialMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if transcripts.records.isEmpty {
                Text("Your next local result will appear here.")
                    .font(VoxoLTypography.font(size: metrics.bodySize, relativeTo: .body))
                    .foregroundStyle(theme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(historyDays, id: \.day) { group in
                            Section {
                                VStack(spacing: 0) {
                                    ForEach(group.records) { record in
                                        historyRow(record, metrics: metrics)
                                    }
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(theme.canvas.opacity(0.5))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(theme.line, lineWidth: 1)
                                )
                                .padding(.bottom, metrics.compact ? 18 : 24)
                            } header: {
                                Text(verbatim: group.title)
                                    .font(
                                        VoxoLTypography.font(
                                            size: metrics.eyebrowSize,
                                            weight: .semibold,
                                            relativeTo: .caption
                                        )
                                    )
                                    .foregroundStyle(theme.secondaryInk)
                                    .textCase(.uppercase)
                                    .tracking(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                                    .background(theme.surface)
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
    }

    /// Records newest first, split into calendar days with a readable heading.
    private var historyDays: [(day: Date, title: String, records: [TranscriptRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: transcripts.records) {
            calendar.startOfDay(for: $0.createdAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            (
                day: day,
                title: day.formatted(
                    .dateTime.weekday(.wide).day().month(.wide).locale(locale)
                ).uppercased(with: locale),
                records: grouped[day]?.sorted { $0.createdAt > $1.createdAt } ?? []
            )
        }
    }

    private func historyRow(_ record: TranscriptRecord, metrics: EditorialMetrics) -> some View {
        let hovered = hoveredRecordID == record.id
        return HStack(alignment: .top, spacing: 16) {
            Text(record.createdAt, format: .dateTime.hour().minute())
                .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
                .monospacedDigit()
                .frame(width: 52, alignment: .leading)
                .padding(.top, 2)

            Text(verbatim: record.text)
                .font(VoxoLTypography.font(size: metrics.compact ? 13.5 : 14.5, relativeTo: .body))
                .foregroundStyle(theme.ink)
                .lineSpacing(3)
                .lineLimit(hovered ? 6 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if hovered {
                    if record.canUndo {
                        EditorialIconButton(
                            icon: "arrow.uturn.backward",
                            label: "Restore the raw text",
                            size: 26,
                            systemSymbol: true
                        ) {
                            Task { await transcripts.undoLastEdit(for: record.id) }
                        }
                    }
                    // The counterpart to the button above. Without it, seeing
                    // the raw text cost you the polished one permanently, so
                    // the honest thing was never to look.
                    if record.canRedo {
                        EditorialIconButton(
                            icon: "arrow.uturn.forward",
                            label: "Restore the cleaned-up text",
                            size: 26,
                            systemSymbol: true
                        ) {
                            Task { await transcripts.redoLastEdit(for: record.id) }
                        }
                    }
                    EditorialIconButton(
                        icon: "doc.on.doc",
                        label: "Copy transcription",
                        size: 26,
                        systemSymbol: true
                    ) {
                        transcripts.copy(record)
                    }
                    EditorialIconButton(
                        icon: "text.magnifyingglass",
                        label: "Result detail",
                        size: 26,
                        systemSymbol: true
                    ) {
                        inspectedRecord = record
                    }
                } else {
                    Text(verbatim: record.applicationName)
                        .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                        .lineLimit(1)
                }
            }
            .frame(width: metrics.compact ? 96 : 108, alignment: .trailing)
        }
        .padding(.horizontal, metrics.compact ? 14 : 18)
        .padding(.vertical, metrics.compact ? 12 : 14)
        .background(hovered ? theme.selection.opacity(0.45) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { transcripts.copy(record) }
        .onHover { hovering in
            withAnimation(EditorialMotion.soft) {
                if hovering {
                    hoveredRecordID = record.id
                } else if hoveredRecordID == record.id {
                    hoveredRecordID = nil
                }
            }
        }
        .overlay(alignment: .bottom) {
            if record.id != lastRecordID(inSameDayAs: record) {
                EditorialRule().padding(.leading, metrics.compact ? 14 : 18)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Copy transcription")) { transcripts.copy(record) }
        .accessibilityAction(named: Text("Result detail")) { inspectedRecord = record }
    }

    private func lastRecordID(inSameDayAs record: TranscriptRecord) -> UUID? {
        let calendar = Calendar.current
        return
            historyDays
            .first { calendar.isDate($0.day, inSameDayAs: record.createdAt) }?
            .records.last?.id
    }

    /// The same numbers as the column, on one line, for windows too narrow to carry a column.
    private func statsRow(metrics: EditorialMetrics) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            statTile(value: totalWords.formatted(), label: "total words")
            statTile(value: averageWordsPerMinute.formatted(), label: "wpm")
            statTile(value: todayRecovered, label: "recovered")
            Spacer(minLength: 8)
            Button(action: openInsights) {
                HStack(spacing: 5) {
                    Text("View insights")
                    EditorialIcon(name: "arrow-right", size: 12)
                }
                .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .body))
                .foregroundStyle(theme.cobalt)
            }
            .buttonStyle(SignalPressButtonStyle())
            .fixedSize()
        }
    }

    /// The numbers, kept out of the reading column.
    private func statsColumn(metrics: EditorialMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            statTile(value: totalWords.formatted(), label: "total words")
            EditorialRule().padding(.vertical, 14)
            statTile(value: averageWordsPerMinute.formatted(), label: "wpm")
            EditorialRule().padding(.vertical, 14)
            statTile(value: todayRecovered, label: "recovered")

            Button(action: openInsights) {
                HStack(spacing: 5) {
                    Text("View insights")
                    EditorialIcon(name: "arrow-right", size: 12)
                }
                .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .body))
                .foregroundStyle(theme.cobalt)
                .frame(minHeight: 30)
            }
            .buttonStyle(SignalPressButtonStyle())
            .padding(.top, 16)

            Spacer(minLength: 0)
        }
        .padding(metrics.compact ? 16 : 20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.canvas.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.line, lineWidth: 1)
        )
    }

    private func statTile(value: String, label: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(verbatim: value)
                .font(VoxoLTypography.font(size: 21, weight: .semibold, relativeTo: .title2))
                .foregroundStyle(theme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
        }
    }

    private var totalWords: Int {
        usesPrototypeFixture ? 20_837 : TranscriptHistoryMetrics(records: transcripts.records).words
    }

    private var averageWordsPerMinute: Int {
        usesPrototypeFixture
            ? 148 : TranscriptHistoryMetrics(records: transcripts.records).averageWordsPerMinute
    }

    /// The record behind the card, when it is a real dictation rather than the prototype copy.
    private var inspectableRecord: TranscriptRecord? {
        usesPrototypeFixture ? nil : latestRecord
    }

    /// Whether a raw transcript was kept for this result and actually differs from what shipped.
    private var hasComparison: Bool {
        guard let record = inspectableRecord, let raw = record.revisions.first?.text else {
            return false
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            != record.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inspectLatest() {
        inspectedRecord = inspectableRecord
    }

    private func editorialEyebrow(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(VoxoLTypography.font(size: 10.5, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(theme.secondaryInk)
            .textCase(.uppercase)
            .tracking(0.96)
    }

    private func reveal() {
        guard !visible else { return }
        if reduceMotion {
            visible = true
        } else {
            Task { @MainActor in
                await Task.yield()
                visible = true
            }
        }
    }

    private var todayLabel: String {
        Date.now.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(locale)
        ).capitalized(with: locale)
    }

    private var latestRecord: TranscriptRecord? { transcripts.records.first }

    private var usesPrototypeFixture: Bool {
        transcripts.usesExampleData || transcripts.records.isEmpty
    }

    private var latestText: String {
        if usesPrototypeFixture {
            return String(
                localized:
                    "The budget is 4,500 euros and delivery is scheduled for Wednesday morning.")
        }
        return latestRecord?.text ?? String(localized: "Your next local result will appear here.")
    }

    private var latestSubtitle: LocalizedStringKey {
        if usesPrototypeFixture {
            return "8 minutes ago in Notes"
        }
        guard let record = latestRecord else { return "No retained result yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        let relative = formatter.localizedString(for: record.createdAt, relativeTo: .now)
        return LocalizedStringKey("\(relative) · \(record.applicationName)")
    }

    private var latestDuration: String {
        if usesPrototypeFixture { return "6.4 s" }
        return (latestRecord?.durationSeconds ?? 0).formatted(
            .number.precision(.fractionLength(1))) + " s"
    }

    private var todayRecords: [TranscriptRecord] {
        let calendar = Calendar.current
        return transcripts.records.filter { calendar.isDateInToday($0.createdAt) }
    }

    private var todayWords: Int {
        usesPrototypeFixture ? 182 : TranscriptHistoryMetrics(records: todayRecords).words
    }

    private var todaySessions: Int {
        usesPrototypeFixture ? 12 : todayRecords.count
    }

    private var todayRecovered: String {
        if usesPrototypeFixture { return String(localized: "3 min") }
        let metrics = TranscriptHistoryMetrics(records: todayRecords)
        let typedSeconds = Double(metrics.words) / 40 * 60
        let recovered = max(0, typedSeconds - metrics.speakingSeconds)
        return String(localized: "\(Int((recovered / 60).rounded())) min")
    }

    private func copyLatest() {
        if !usesPrototypeFixture, let record = latestRecord {
            transcripts.copy(record)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestText, forType: .string)
        transcripts.toast = .copied
    }

    private var signalMode: HubSignalMode {
        switch dictationSession.state {
        case .listening, .speechDetected: .voice
        case .transcribing, .polishing, .inserting: .processing
        default: .idle
        }
    }

    private var dictationInstruction: LocalizedStringKey {
        activationMode == .hold
            ? "Hold the shortcut, speak naturally, then release."
            : "Press the shortcut to start, then press it again to finish."
    }

    private var primaryActionLabel: LocalizedStringKey {
        switch dictationSession.state {
        case .listening, .speechDetected:
            activationMode == .hold ? "Release to finish" : "Press to stop"
        case .transcribing, .polishing, .inserting:
            "Preparing locally"
        default:
            activationMode == .hold ? "Hold to dictate" : "Press to dictate"
        }
    }

    /// What the runtime is doing, named for what it is.
    ///
    /// A dictation that failed is not a broken setup: saying "setup required" after one bad
    /// insertion sends the user hunting through permissions for a problem that is not there.
    private var runtimeStatus: LocalizedStringKey {
        switch dictationSession.state {
        case .listening, .speechDetected: "Listening"
        case .transcribing, .polishing, .inserting: "Preparing locally"
        case .insertionSucceeded: "Inserted"
        case .copiedForManualPaste: "Copied · press ⌘V"
        case .failed: "Last dictation failed"
        case .captureNeedsModel: "Model unavailable"
        case .waitingForInputMonitoring: "Setup required"
        default: "Ready to listen"
        }
    }

    /// The reason behind a failure, shown on hover rather than hidden in a log.
    private var runtimeStatusHelp: LocalizedStringKey? {
        switch dictationSession.state {
        case .failed:
            dictationSession.lastError.map { LocalizedStringKey($0) }
                ?? LocalizedStringKey("The last dictation did not complete.")
        case .captureNeedsModel:
            "The transcription model is not available."
        case .waitingForInputMonitoring:
            "Allow Input Monitoring so the shortcut works everywhere."
        default:
            nil
        }
    }

    private var runtimeTone: Color {
        switch dictationSession.state {
        case .listening, .speechDetected: theme.coral
        case .transcribing, .polishing, .inserting: theme.cobalt
        case .failed, .captureNeedsModel, .waitingForInputMonitoring: theme.warning
        default: theme.success
        }
    }
}

// MARK: - Dictation

struct EditorialDictationView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(DictationSessionCoordinator.self) private var dictationSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let setupReady: Bool
    let openSetup: () -> Void

    @AppStorage("voxol.activationMode") private var activationMode = ActivationMode.hold
    @AppStorage("voxol.dictationShortcut") private var shortcut = DictationShortcut.optionSpace
    @AppStorage("voxol.dictationLanguage") private var language =
        DictationLanguagePreference.preferred
    @AppStorage("voxol.cleanupMode") private var cleanup = DictationCleanupMode.faithful
    @State private var visible = false

    var body: some View {
        GeometryReader { geometry in
            let metrics = EditorialMetrics(geometry.size)

            VStack(alignment: .leading, spacing: 0) {
                EditorialPageHeader(
                    metrics: metrics,
                    eyebrow: "Dictation",
                    title: "Your voice, ready everywhere.",
                    summary: "Choose a language, then use your shortcut."
                ) {
                    EditorialSegmentedControl(
                        options: DictationLanguagePreference.allCases,
                        selection: $language
                    ) { option in
                        Text(option.title)
                    }
                }
                .padding(.bottom, metrics.headingGap)
                .editorialStagger(0, visible: visible)

                dictationStage(metrics: metrics)
                    .editorialBand(min: metrics.compact ? 292 : 320)
                    .editorialStagger(1, visible: visible)

                settingsStrip(metrics: metrics)
                    .frame(height: metrics.compact ? 68 : 72)
                    .padding(.top, 12)
                    .editorialStagger(2, visible: visible)
            }
            .padding(metrics.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { reveal() }
        .onDisappear { visible = false }
    }

    private func dictationStage(metrics: EditorialMetrics) -> some View {
        ZStack(alignment: .top) {
            theme.canvas

            VStack(spacing: 0) {
                // The signal band takes the height the window offers; the transcript comparison
                // keeps a readable size instead of stretching into an empty box.
                ZStack {
                    HubDitherField(
                        mode: runtimeSignalMode,
                        cadence: runtimeIsActive ? .live : .ambient
                    )
                    capsuleTrigger
                }
                .frame(
                    minHeight: metrics.compact ? 132 : 152,
                    maxHeight: metrics.compact ? 240 : 300
                )

                // The signal band is capped so it stays a banner (and stays cheap to draw); the
                // transcript comparison takes whatever height is left.
                comparisonRow(metrics: metrics)
                    .frame(
                        minHeight: metrics.compact ? 116 : 124,
                        maxHeight: .infinity
                    )
                    .padding(metrics.compact ? 16 : 20)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        }
    }

    private var capsuleTrigger: some View {
        HStack(spacing: 12) {
            EditorialWaveMini()
            Text(setupReady ? runtimeLabel : LocalizedStringKey("Finish setup"))
                .font(VoxoLTypography.font(size: 14, weight: .semibold, relativeTo: .body))
            Text(verbatim: setupReady ? (runtimeIsActive ? "esc" : shortcut.label) : "Review")
                .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(theme.selection)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 48)
        .background(theme.surface.opacity(0.92))
        .clipShape(Capsule())
        .overlay { Capsule().stroke(Color.black.opacity(0.08), lineWidth: 1) }
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 4)
        .editorialDictationTrigger(setupReady: setupReady, openSetup: openSetup)
        .accessibilityLabel(setupReady ? Text("Dictate") : Text("Finish setup"))
    }

    private func comparisonRow(metrics: EditorialMetrics) -> some View {
        HStack(spacing: 0) {
            comparisonPanel(
                title: "Heard",
                text: rawText,
                ready: false,
                compact: metrics.compact
            )
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.secondaryInk.opacity(0.6))
                .frame(width: metrics.compact ? 32 : 48)
            comparisonPanel(
                title: "Ready to insert",
                text: finalText,
                ready: true,
                compact: metrics.compact
            )
        }
    }

    private func comparisonPanel(
        title: LocalizedStringKey,
        text: String,
        ready: Bool,
        compact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
                .textCase(.uppercase)
                .tracking(0.48)
            Text(verbatim: text)
                .font(VoxoLTypography.font(size: compact ? 14 : 16, relativeTo: .body))
                .foregroundStyle(theme.ink)
                .lineLimit(compact ? 3 : 4)
                .padding(.top, 8)
                .textSelection(.enabled)
        }
        .padding(compact ? 14 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface.opacity(ready ? 1 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    ready ? theme.cobalt.opacity(0.16) : Color.black.opacity(0.06), lineWidth: 1)
        }
        .shadow(
            color: ready ? theme.cobalt.opacity(0.08) : Color.black.opacity(0.04),
            radius: ready ? 12 : 2,
            y: ready ? 4 : 1
        )
    }

    private func settingsStrip(metrics: EditorialMetrics) -> some View {
        HStack(spacing: 12) {
            Button {
                activationMode = activationMode == .hold ? .toggle : .hold
            } label: {
                settingTile(
                    icon: "waveform",
                    label: "Activation",
                    value: activationMode == .hold ? "Hold to speak" : "Press to toggle",
                    compact: metrics.compact
                )
            }
            .buttonStyle(SignalPressButtonStyle())

            Button {
                cleanup =
                    switch cleanup {
                    case .faithful: .rewrite
                    case .rewrite: .raw
                    case .raw: .faithful
                    }
            } label: {
                settingTile(
                    icon: "text-aa",
                    label: "Preparation",
                    value: cleanup.title,
                    compact: metrics.compact
                )
            }
            .buttonStyle(SignalPressButtonStyle())

            Button {
                shortcut = shortcut == .optionSpace ? .controlSpace : .optionSpace
            } label: {
                settingTile(
                    icon: "command",
                    label: "Shortcut",
                    value: LocalizedStringKey(shortcut.label),
                    compact: metrics.compact
                )
            }
            .buttonStyle(SignalPressButtonStyle())
            .help("Change shortcut")
        }
    }

    private func settingTile(
        icon: String,
        label: LocalizedStringKey,
        value: LocalizedStringKey,
        compact: Bool
    ) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            EditorialIcon(name: icon, size: compact ? 16 : 20)
                .foregroundStyle(theme.ink)
                .frame(width: compact ? 32 : 40, height: compact ? 32 : 40)
                .background(theme.selection)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                Text(value)
                    .font(VoxoLTypography.font(size: 14, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(theme.ink)
                    .lineLimit(compact ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
            if !compact {
                EditorialIcon(name: "caret-right", size: 16)
                    .foregroundStyle(theme.ink.opacity(0.6))
            }
        }
        .padding(.horizontal, compact ? 8 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }

    private func reveal() {
        guard !visible else { return }
        if reduceMotion {
            visible = true
        } else {
            Task { @MainActor in
                await Task.yield()
                visible = true
            }
        }
    }

    private var latestTrace: DictationPipelineTrace? { dictationSession.pipelineTraces.first }

    private var rawText: String {
        latestTrace?.rawTranscript
            ?? String(localized: "Um, send it Tuesday—no, sorry, Wednesday morning.")
    }

    private var finalText: String {
        // Raw shows the transcript untouched; both cleanup modes show the
        // processed result — rewrite is more processing, not less.
        guard cleanup != .raw else { return rawText }
        return latestTrace?.finalText ?? String(localized: "Send it Wednesday morning.")
    }

    private var runtimeIsActive: Bool {
        switch dictationSession.state {
        case .listening, .speechDetected, .transcribing, .polishing, .inserting: true
        default: false
        }
    }

    private var runtimeSignalMode: HubSignalMode {
        switch dictationSession.state {
        case .transcribing, .polishing, .inserting: .processing
        default: .voice
        }
    }

    private var runtimeLabel: LocalizedStringKey {
        switch dictationSession.state {
        case .listening, .speechDetected:
            activationMode == .hold ? "Release to finish" : "Press to stop"
        case .transcribing: "Transcribing"
        case .polishing: "Preparing text"
        case .inserting: "Inserting"
        case .insertionSucceeded: "Inserted"
        case .copiedForManualPaste: "Copied · press ⌘V"
        case .failed, .captureNeedsModel, .waitingForInputMonitoring: "Finish setup"
        default: activationMode == .hold ? "Hold to dictate" : "Press to dictate"
        }
    }
}

// MARK: - Insights

private enum EditorialInsightPeriod: String, CaseIterable, Hashable {
    case week
    case month
    case all

    var title: LocalizedStringKey {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All"
        }
    }

    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .all: nil
        }
    }
}

private struct EditorialAppShare: Identifiable {
    let id: String
    let name: String
    let share: Int
    let tone: Color
    /// The destination's real icon, when the record kept a bundle identifier we can resolve.
    var icon: NSImage?
}

/// Resolves and remembers destination application icons, so a list of results can show the apps
/// the user actually dictated into rather than a generic glyph.
@MainActor
private enum ApplicationIconCache {
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

/// A half-circle gauge for speaking pace, scaled against a typing baseline.
private struct EditorialPaceGauge: View {
    @Environment(VoxoLTheme.self) private var theme

    /// Words per minute.
    let value: Int
    /// The top of the scale: fast dictation, not a world record.
    private let ceiling = 200.0

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear) { context, size in
            let radius = min(size.width / 2, size.height) - 6
            guard radius > 8 else { return }
            let centre = CGPoint(x: size.width / 2, y: size.height - 2)
            let width = max(6, radius * 0.22)

            var track = Path()
            track.addArc(
                center: centre, radius: radius,
                startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            context.stroke(
                track, with: .color(theme.selection),
                style: StrokeStyle(lineWidth: width, lineCap: .round))

            // The fill traces the same path as the track — 180° to 360° — rather than sweeping
            // the other way round the circle, where it would be drawn below the centre and clipped.
            let fraction = min(1, max(0.02, Double(value) / ceiling))
            var filled = Path()
            filled.addArc(
                center: centre, radius: radius,
                startAngle: .degrees(180), endAngle: .degrees(180 + 180 * fraction),
                clockwise: false)
            context.stroke(
                filled, with: .color(theme.cobalt),
                style: StrokeStyle(lineWidth: width, lineCap: .round))

            // The typing baseline, so the number has a reference rather than a vibe.
            let typingAngle = Angle.degrees(180 + 180 * (40.0 / ceiling)).radians
            var marker = Path()
            marker.move(
                to: CGPoint(
                    x: centre.x + cos(typingAngle) * (radius - width / 2 - 2),
                    y: centre.y + sin(typingAngle) * (radius - width / 2 - 2)))
            marker.addLine(
                to: CGPoint(
                    x: centre.x + cos(typingAngle) * (radius + width / 2 + 2),
                    y: centre.y + sin(typingAngle) * (radius + width / 2 + 2)))
            context.stroke(marker, with: .color(theme.ink.opacity(0.45)), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}

/// Ninety days of activity, one cell per day, in the product's ink.
private struct EditorialStreakCalendar: View {
    @Environment(VoxoLTheme.self) private var theme

    let days: [(date: Date, count: Int)]

    var body: some View {
        GeometryReader { geometry in
            let columns = max(1, Int(ceil(Double(days.count) / 7)))
            let spacing: CGFloat = 3
            let cell = max(
                6,
                min(13, (geometry.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            )

            HStack(alignment: .top, spacing: spacing) {
                ForEach(0..<columns, id: \.self) { column in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            let index = column * 7 + row
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(tone(forDayAt: index))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 13 * 7 + 3 * 6)
        .accessibilityHidden(true)
    }

    private func tone(forDayAt index: Int) -> Color {
        guard days.indices.contains(index) else { return theme.selection.opacity(0.4) }
        switch days[index].count {
        case 0: return theme.selection
        case 1...2: return theme.cobalt.opacity(0.35)
        case 3...5: return theme.cobalt.opacity(0.65)
        default: return theme.cobalt
        }
    }
}

/// A bar chart drawn in the same grain as the rest of VoxoL: each column is a stack of ink cells
/// rather than a solid rectangle, so the data reads as the product's own material.
private struct EditorialGrainBars: View {
    @Environment(VoxoLTheme.self) private var theme

    /// Normalized 0…1 heights, oldest first.
    let values: [CGFloat]
    let labels: [String]

    var body: some View {
        GeometryReader { geometry in
            let labelHeight: CGFloat = 14
            let plotHeight = max(16, geometry.size.height - labelHeight - 4)
            let columnWidth = geometry.size.width / CGFloat(max(1, values.count))

            ZStack(alignment: .bottom) {
                Canvas(opaque: false, colorMode: .nonLinear) { context, size in
                    let cell = max(3, min(5, columnWidth / 6))
                    let barWidth = min(columnWidth - cell * 1.6, cell * 5)

                    for (index, value) in values.enumerated() {
                        let centre = columnWidth * (CGFloat(index) + 0.5)
                        let height = max(cell, value * plotHeight)
                        let isLast = index == values.count - 1
                        var dots = Path()

                        var y = plotHeight
                        while y > plotHeight - height {
                            var x = centre - barWidth / 2
                            while x < centre + barWidth / 2 {
                                defer { x += cell }
                                let dot = cell * 0.62
                                dots.addEllipse(
                                    in: CGRect(
                                        x: x + (cell - dot) / 2,
                                        y: y - cell + (cell - dot) / 2,
                                        width: dot,
                                        height: dot
                                    )
                                )
                            }
                            y -= cell
                        }
                        context.fill(
                            dots,
                            with: .color(isLast ? theme.coral : theme.ink.opacity(0.55))
                        )
                    }

                    // The floor the columns stand on.
                    var baseline = Path()
                    baseline.move(to: CGPoint(x: 0, y: plotHeight + 0.5))
                    baseline.addLine(to: CGPoint(x: size.width, y: plotHeight + 0.5))
                    context.stroke(baseline, with: .color(theme.line), lineWidth: 1)
                }

                HStack(spacing: 0) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        Text(verbatim: label)
                            .font(VoxoLTypography.font(size: 10, relativeTo: .caption))
                            .foregroundStyle(
                                index == labels.count - 1 ? theme.coral : theme.secondaryInk
                            )
                            .frame(width: columnWidth)
                    }
                }
                .frame(height: labelHeight)
                .offset(y: 0)
            }
        }
        .accessibilityHidden(true)
    }
}

struct EditorialInsightsView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var period = EditorialInsightPeriod.week
    @State private var visible = false

    var body: some View {
        GeometryReader { geometry in
            let metrics = EditorialMetrics(geometry.size)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    EditorialPageHeader(
                        metrics: metrics,
                        eyebrow: "Insights",
                        title: "Your voice at a glance.",
                        summary: periodSummary
                    ) {
                        EditorialSegmentedControl(
                            options: EditorialInsightPeriod.allCases,
                            selection: $period
                        ) { option in
                            Text(option.title)
                        }
                    }
                    .padding(.bottom, metrics.headingGap)
                    .editorialStagger(0, visible: visible)

                    HStack(alignment: .top, spacing: metrics.cardGap) {
                        paceCard(metrics: metrics)
                        correctionsCard(metrics: metrics)
                        volumeCard(metrics: metrics)
                    }
                    .editorialStagger(1, visible: visible)

                    HStack(alignment: .top, spacing: metrics.cardGap) {
                        appsCard(metrics: metrics)
                        streakCard(metrics: metrics)
                    }
                    .padding(.top, metrics.cardGap)
                    .editorialStagger(2, visible: visible)
                }
                .padding(.horizontal, metrics.pagePadding)
                .padding(.top, metrics.pagePadding)
                .padding(.bottom, metrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
        }
        .onAppear { reveal() }
        .onDisappear { visible = false }
    }

    // MARK: Cards

    private func dashboardCard<Content: View>(
        metrics: EditorialMetrics,
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(
                    VoxoLTypography.font(
                        size: metrics.eyebrowSize, weight: .semibold, relativeTo: .caption)
                )
                .foregroundStyle(theme.secondaryInk)
                .textCase(.uppercase)
                .tracking(1)

            content()
                .padding(.top, 12)
        }
        .padding(metrics.compact ? 16 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.canvas.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.line, lineWidth: 1)
        )
    }

    private func paceCard(metrics: EditorialMetrics) -> some View {
        dashboardCard(metrics: metrics, title: "Words per minute") {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: averageWPM.formatted())
                    .font(
                        VoxoLTypography.font(size: 40, weight: .semibold, relativeTo: .largeTitle)
                    )
                    .foregroundStyle(theme.ink)
                    .monospacedDigit()
                    .tracking(-1.4)

                EditorialPaceGauge(value: averageWPM)
                    .frame(height: 58)
                    .padding(.top, 10)

                Text("Typing sits around 40.")
                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .padding(.top, 8)
            }
        }
    }

    private func correctionsCard(metrics: EditorialMetrics) -> some View {
        dashboardCard(metrics: metrics, title: "Fixes made by VoxoL") {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: correctedWordCount.formatted())
                    .font(
                        VoxoLTypography.font(size: 40, weight: .semibold, relativeTo: .largeTitle)
                    )
                    .foregroundStyle(theme.ink)
                    .monospacedDigit()
                    .tracking(-1.4)

                Text("words rewritten after the microphone")
                    .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                EditorialRule().padding(.vertical, 12)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: correctedResultCount.formatted())
                        .font(VoxoLTypography.font(size: 16, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(theme.ink)
                        .monospacedDigit()
                    Text("results cleaned up")
                        .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                }
            }
        }
    }

    private func volumeCard(metrics: EditorialMetrics) -> some View {
        dashboardCard(metrics: metrics, title: "Total words dictated") {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: metrics.compact ? shortWordCount : metrics2.words.formatted())
                    .font(
                        VoxoLTypography.font(size: 40, weight: .semibold, relativeTo: .largeTitle)
                    )
                    .foregroundStyle(theme.ink)
                    .monospacedDigit()
                    .tracking(-1.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(volumeComparison)
                    .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                EditorialRule().padding(.vertical, 12)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: recoveredMinutes.formatted())
                        .font(VoxoLTypography.font(size: 16, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(theme.ink)
                        .monospacedDigit()
                    Text("minutes recovered")
                        .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                }
            }
        }
    }

    private func appsCard(metrics: EditorialMetrics) -> some View {
        dashboardCard(metrics: metrics, title: "Where you dictate") {
            VStack(spacing: metrics.compact ? 12 : 14) {
                ForEach(appShares) { item in
                    HStack(spacing: 12) {
                        Group {
                            if let icon = item.icon {
                                Image(nsImage: icon).resizable().interpolation(.high)
                            } else {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(theme.selection)
                            }
                        }
                        .frame(width: 22, height: 22)

                        Text(verbatim: item.name)
                            .frame(width: metrics.compact ? 78 : 104, alignment: .leading)
                            .lineLimit(1)

                        GeometryReader { geometry in
                            Capsule()
                                .fill(theme.selection)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(item.tone)
                                        .frame(
                                            width: geometry.size.width * CGFloat(item.share) / 100)
                                }
                        }
                        .frame(height: 8)

                        Text(verbatim: "\(item.share) %")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                    .foregroundStyle(theme.ink)
                }

                if appShares.isEmpty {
                    Text("Your apps will appear here.")
                        .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                        .foregroundStyle(theme.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func streakCard(metrics: EditorialMetrics) -> some View {
        dashboardCard(metrics: metrics, title: "Streak") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(verbatim: currentStreak.formatted())
                        .font(
                            VoxoLTypography.font(size: 22, weight: .semibold, relativeTo: .title2)
                        )
                        .foregroundStyle(theme.ink)
                        .monospacedDigit()
                    Text("days in a row")
                        .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                    Spacer(minLength: 8)
                    Text(LocalizedStringKey("Longest \(longestStreak)"))
                        .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                }

                EditorialStreakCalendar(days: streakDays)
                    .padding(.top, 14)
            }
        }
    }

    // MARK: Numbers

    /// `metrics` is the period summary; this alias keeps the volume card readable.
    private var metrics2: TranscriptHistoryMetrics { metrics }

    private var shortWordCount: String {
        let words = metrics.words
        guard words >= 10_000 else { return words.formatted() }
        return (Double(words) / 1_000).formatted(.number.precision(.fractionLength(1))) + "K"
    }

    private var volumeComparison: LocalizedStringKey {
        // A page of prose is about 500 words; it is a scale people actually have a feel for.
        let pages = max(0, metrics.words / 500)
        return pages > 0
            ? LocalizedStringKey("About \(pages) pages of writing.")
            : "Every word stays on this Mac."
    }

    /// Results the model actually rewrote, and how many words changed in them.
    private var correctionSummary: (results: Int, words: Int) {
        if usesPrototypeFixture { return (307, 846) }
        var results = 0
        var words = 0
        for record in filteredRecords {
            guard let raw = record.revisions.first?.text,
                let tokens = TranscriptDiff.tokens(raw: raw, final: record.text)
            else {
                continue
            }
            results += 1
            words += tokens.filter { $0.change != .unchanged }.count
        }
        return (results, words)
    }

    private var correctedResultCount: Int { correctionSummary.results }
    private var correctedWordCount: Int { correctionSummary.words }

    /// Days with at least one dictation, oldest first, over the plotted window.
    private var streakDays: [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let counts = Dictionary(grouping: transcripts.records) {
            calendar.startOfDay(for: $0.createdAt)
        }
        .mapValues(\.count)
        return (0..<91).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            return (date: date, count: counts[date] ?? 0)
        }
    }

    private var currentStreak: Int {
        var streak = 0
        for day in streakDays.reversed() {
            guard day.count > 0 else { break }
            streak += 1
        }
        return streak
    }

    private var longestStreak: Int {
        var best = 0
        var running = 0
        for day in streakDays {
            if day.count > 0 {
                running += 1
                best = max(best, running)
            } else {
                running = 0
            }
        }
        return best
    }

    private func editorialEyebrow(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(theme.secondaryInk)
            .textCase(.uppercase)
            .tracking(0.96)
    }

    private func reveal() {
        guard !visible else { return }
        if reduceMotion {
            visible = true
        } else {
            Task { @MainActor in
                await Task.yield()
                visible = true
            }
        }
    }

    private var filteredRecords: [TranscriptRecord] {
        guard let days = period.days,
            let start = Calendar.current.date(byAdding: .day, value: -days, to: .now)
        else {
            return transcripts.records
        }
        return transcripts.records.filter { $0.createdAt >= start }
    }

    private var usesPrototypeFixture: Bool {
        transcripts.usesExampleData || transcripts.records.isEmpty
    }

    private var metrics: TranscriptHistoryMetrics {
        TranscriptHistoryMetrics(records: filteredRecords)
    }

    private var periodSummary: LocalizedStringKey {
        switch period {
        case .week: "Seven days of dictation, measured only on this Mac."
        case .month: "Thirty days of dictation, measured only on this Mac."
        case .all: "Every retained dictation, measured only on this Mac."
        }
    }

    private var periodEyebrow: LocalizedStringKey {
        switch period {
        case .week: "This week"
        case .month: "Last 30 days"
        case .all: "All time"
        }
    }

    private var recoveredMinutes: Int {
        if usesPrototypeFixture { return 8 }
        let typedSeconds = Double(metrics.words) / 40 * 60
        return max(0, Int(((typedSeconds - metrics.speakingSeconds) / 60).rounded()))
    }

    /// The day with the most words in the plotted week, named the way the chart labels it.
    private var busiestDayLabel: String {
        guard let index = dayBars.firstIndex(of: dayBars.max() ?? 0),
            dayLabels.indices.contains(index), (dayBars.max() ?? 0) > 0
        else {
            return "—"
        }
        return dayLabels[index]
    }

    private var dailyAverageWords: Int {
        Int((Double(periodWords) / 7).rounded())
    }

    /// Words dictated over the last seven days, the span the rhythm chart plots.
    private var periodWords: Int {
        if usesPrototypeFixture { return 883 }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        guard let floor = calendar.date(byAdding: .day, value: -6, to: start) else {
            return metrics.words
        }
        return
            filteredRecords
            .filter { $0.createdAt >= floor }
            .reduce(0) { $0 + $1.wordCount }
    }

    private var recoveredHeadline: LocalizedStringKey {
        LocalizedStringKey("\(recoveredMinutes) minutes recovered.")
    }

    private var heroSummary: LocalizedStringKey {
        let words = usesPrototypeFixture ? 883 : metrics.words
        let sessions = usesPrototypeFixture ? 55 : metrics.sessions
        return LocalizedStringKey(
            "\(words) words prepared in \(sessions) dictations, without leaving your apps."
        )
    }

    private var averageWPM: Int { usesPrototypeFixture ? 149 : metrics.averageWordsPerMinute }

    private var wordsPerSession: String {
        let value =
            usesPrototypeFixture
            ? 11.4
            : metrics.sessions > 0 ? Double(metrics.words) / Double(metrics.sessions) : 0
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private var appCount: Int {
        usesPrototypeFixture
            ? 4
            : Set(filteredRecords.map(\.applicationName)).count
    }

    private var dayBars: [CGFloat] {
        if usesPrototypeFixture { return [0.42, 0.74, 0.58, 0.84, 0.68, 0.92, 0.76] }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        let counts = (-6...0).map { offset -> Int in
            let date =
                calendar.date(byAdding: .day, value: offset, to: startOfToday) ?? startOfToday
            return
                filteredRecords
                .filter { calendar.isDate($0.createdAt, inSameDayAs: date) }
                .reduce(0) { $0 + $1.wordCount }
        }
        let maximum = max(1, counts.max() ?? 1)
        return counts.map { CGFloat($0) / CGFloat(maximum) }
    }

    private var dayLabels: [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "EEEEE"
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        return (-6...0).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            return formatter.string(from: date).uppercased()
        }
    }

    private var trendLabel: LocalizedStringKey {
        if usesPrototypeFixture { return "+18 %" }
        return filteredRecords.isEmpty ? "0 %" : "+0 %"
    }

    private var appShares: [EditorialAppShare] {
        if usesPrototypeFixture {
            return [
                EditorialAppShare(id: "Notes", name: "Notes", share: 41, tone: theme.cobalt),
                EditorialAppShare(
                    id: "Mail", name: "Mail", share: 28, tone: theme.cobalt.opacity(0.76)),
                EditorialAppShare(
                    id: "Cursor", name: "Cursor", share: 19, tone: theme.cobalt.opacity(0.5)),
                EditorialAppShare(
                    id: "Other", name: String(localized: "Other"), share: 12, tone: theme.coral),
            ]
        }

        let grouped = Dictionary(grouping: filteredRecords, by: \.applicationName)
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }
        let total = max(1, filteredRecords.count)
        let top = Array(grouped.prefix(3))
        // Any record for an application carries the same bundle identifier, so the first one
        // found is enough to resolve the icon macOS has for it.
        let bundleIdentifiers = Dictionary(
            filteredRecords.compactMap { record in
                record.applicationBundleIdentifier.map { (record.applicationName, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        var result = top.enumerated().map { index, item in
            EditorialAppShare(
                id: item.key,
                name: item.key,
                share: Int((Double(item.value) / Double(total) * 100).rounded()),
                tone: theme.cobalt.opacity(1 - Double(index) * 0.24),
                icon: ApplicationIconCache.icon(forBundleIdentifier: bundleIdentifiers[item.key])
            )
        }
        // "Other" only earns a row when something is actually in it, and empty placeholder rows
        // are not padding worth showing: a short honest list beats a padded one.
        let topCount = top.reduce(0) { $0 + $1.value }
        let otherShare = Int((Double(total - topCount) / Double(total) * 100).rounded())
        if otherShare > 0 {
            result.append(
                EditorialAppShare(
                    id: "other",
                    name: String(localized: "Other"),
                    share: otherShare,
                    tone: theme.coral
                )
            )
        }
        return Array(result.prefix(4))
    }

    private var appHeadline: LocalizedStringKey {
        if usesPrototypeFixture { return "Notes remains your first reflex." }
        guard let first = appShares.first, first.name != "—" else {
            return "Your apps will appear here."
        }
        return LocalizedStringKey("\(first.name) is your first reflex.")
    }
}

// MARK: - Meetings

private enum EditorialMeetingTab: String, CaseIterable, Hashable {
    case summary
    case decisions
    case actions
    case transcript

    var title: LocalizedStringKey {
        switch self {
        case .summary: "Summary"
        case .decisions: "Decisions"
        case .actions: "Actions"
        case .transcript: "Transcript"
        }
    }

    var count: Int? {
        switch self {
        case .decisions: 2
        case .actions: 3
        default: nil
        }
    }
}

private struct EditorialMeetingItem: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
}

struct EditorialMeetingsView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedTab = EditorialMeetingTab.summary
    @State private var visible = false

    var body: some View {
        GeometryReader { geometry in
            let metrics = EditorialMetrics(geometry.size)
            let showsFutureFlow = geometry.size.height > 624

            VStack(alignment: .leading, spacing: 0) {
                meetingHeader(metrics: metrics)
                    .padding(.bottom, metrics.headingGap)
                    .editorialStagger(0, visible: visible)

                meetingPreview(metrics: metrics)
                    .editorialBand(min: metrics.compact ? 300 : 320)
                    .editorialStagger(1, visible: visible)

                if showsFutureFlow {
                    futureFlow
                        .frame(height: 48)
                        .padding(.top, 12)
                        .editorialStagger(2, visible: visible)
                }
            }
            .padding(metrics.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { reveal() }
        .onDisappear { visible = false }
    }

    private func meetingHeader(metrics: EditorialMetrics) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Meetings")
                        .font(
                            VoxoLTypography.font(
                                size: 12,
                                weight: .semibold,
                                relativeTo: .caption
                            )
                        )
                        .foregroundStyle(theme.secondaryInk)
                        .textCase(.uppercase)
                        .tracking(0.96)
                    Text("Soon")
                        .font(
                            VoxoLTypography.font(
                                size: 12,
                                weight: .semibold,
                                relativeTo: .caption
                            )
                        )
                        .foregroundStyle(Color(red: 0.53, green: 0.21, blue: 0.12))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(theme.coralSoft)
                        .clipShape(Capsule())
                }
                .frame(height: 32)

                Text("Your meetings, summarized on this Mac.")
                    .font(
                        VoxoLTypography.font(
                            size: metrics.titleSize,
                            weight: .semibold,
                            relativeTo: .largeTitle
                        )
                    )
                    .foregroundStyle(theme.ink)
                    .tracking(-0.96)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.top, 4)

                Text(
                    "The future workspace is already visible, without simulating unavailable capture."
                )
                .font(VoxoLTypography.font(size: 14, relativeTo: .body))
                .foregroundStyle(theme.secondaryInk)
                .lineLimit(2)
                .padding(.top, metrics.compact ? 4 : 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                EditorialIcon(name: "lock-key", size: 16)
                Text("Local capture")
            }
            .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(theme.secondaryInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(width: metrics.compact ? 116 : nil)
            .frame(minHeight: 32)
            .background(theme.selection)
            .clipShape(Capsule())
        }
    }

    private func meetingPreview(metrics: EditorialMetrics) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Result preview")
                        .font(
                            VoxoLTypography.font(
                                size: 12,
                                weight: .semibold,
                                relativeTo: .caption
                            )
                        )
                        .foregroundStyle(theme.secondaryInk)
                        .textCase(.uppercase)
                        .tracking(0.96)
                    Text("Product sync")
                        .font(
                            VoxoLTypography.font(
                                size: 20,
                                weight: .semibold,
                                relativeTo: .title3
                            )
                        )
                        .foregroundStyle(theme.ink)
                        .padding(.top, 4)
                    Text("Google Meet · 42 min · Unrecorded example")
                        .font(VoxoLTypography.font(size: 14, relativeTo: .body))
                        .foregroundStyle(theme.secondaryInk)
                }
                Spacer()
                HStack(spacing: 8) {
                    Circle()
                        .fill(theme.coral)
                        .frame(width: 8, height: 8)
                    Text(verbatim: "42:18")
                }
                .font(VoxoLTypography.font(size: 14, relativeTo: .body))
                .foregroundStyle(theme.secondaryInk)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(theme.selection)
                .clipShape(Capsule())
            }
            .padding(.horizontal, metrics.compact ? 16 : 20)
            .padding(.top, metrics.compact ? 12 : 16)
            .padding(.bottom, metrics.compact ? 8 : 12)

            ZStack(alignment: .bottom) {
                theme.canvas
                HubDitherField(mode: .meeting)
                GeometryReader { geometry in
                    Rectangle()
                        .fill(theme.ink.opacity(0.2))
                        .frame(width: max(0, geometry.size.width - 48), height: 2)
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 20)
                    ForEach([0.16, 0.39, 0.67, 0.88], id: \.self) { position in
                        Circle()
                            .fill(theme.surface)
                            .overlay {
                                Circle()
                                    .stroke(
                                        position == 0.88 ? theme.coral : theme.ink,
                                        lineWidth: 2
                                    )
                            }
                            .frame(width: 8, height: 8)
                            .position(
                                x: 24 + (geometry.size.width - 48) * position,
                                y: geometry.size.height - 20
                            )
                    }
                }
            }
            .frame(height: metrics.compact ? 64 : 76)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.black.opacity(0.1), lineWidth: 1)
            }
            .padding(.horizontal, metrics.compact ? 16 : 20)

            HStack(spacing: 4) {
                ForEach(EditorialMeetingTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(EditorialMotion.soft) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(tab.title)
                            if let count = tab.count {
                                Text(verbatim: count.formatted())
                                    .font(
                                        VoxoLTypography.font(
                                            size: 12,
                                            relativeTo: .caption
                                        )
                                    )
                                    .frame(minWidth: 20, minHeight: 20)
                                    .background(theme.ink.opacity(0.08))
                                    .clipShape(Circle())
                            }
                        }
                        .font(
                            VoxoLTypography.font(
                                size: 14,
                                weight: .medium,
                                relativeTo: .body
                            )
                        )
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, metrics.compact ? 10 : 12)
                        .frame(minHeight: 40)
                        .background(selectedTab == tab ? theme.selection : .clear)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(SignalPressButtonStyle())
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, metrics.compact ? 16 : 20)
            .padding(.top, metrics.compact ? 8 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            meetingOutput(metrics: metrics)
                .id(selectedTab)
                .transition(.opacity.combined(with: .offset(y: 5)))
                .padding(.horizontal, metrics.compact ? 16 : 20)
                .padding(.top, metrics.compact ? 8 : 10)
                .padding(.bottom, metrics.compact ? 12 : 16)
                .frame(height: metrics.compact ? 130 : 120, alignment: .top)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
    }

    @ViewBuilder
    private func meetingOutput(metrics: EditorialMetrics) -> some View {
        switch selectedTab {
        case .summary:
            meetingColumns(
                items: [
                    EditorialMeetingItem(
                        id: "01",
                        title: "Dictation remains the priority.",
                        detail:
                            "The team validates quality and latency before opening long capture."
                    ),
                    EditorialMeetingItem(
                        id: "02",
                        title: "Processing remains entirely local.",
                        detail: "Summaries, decisions and actions follow the same privacy promise."
                    ),
                ],
                compact: metrics.compact
            )
        case .decisions:
            meetingColumns(
                items: [
                    EditorialMeetingItem(
                        id: "01",
                        title: "Validate dictation before long capture.",
                        detail: "Meetings open only after quality and performance gates."
                    ),
                    EditorialMeetingItem(
                        id: "02",
                        title: "Do not promise speaker attribution.",
                        detail: "The first version stays faithful to available capabilities."
                    ),
                ],
                compact: metrics.compact
            )
        case .actions:
            meetingColumns(
                items: [
                    EditorialMeetingItem(
                        id: "01",
                        title: "Test macOS source selection.",
                        detail: "Owner: product · After dictation validation."
                    ),
                    EditorialMeetingItem(
                        id: "02",
                        title: "Measure long-session summaries.",
                        detail: "Owner: model · Latency gate to define."
                    ),
                ],
                compact: metrics.compact
            )
        case .transcript:
            VStack(spacing: 12) {
                transcriptLine(
                    time: "10:04",
                    text: "The priority remains making dictation flawless before expanding capture."
                )
                transcriptLine(
                    time: "10:05",
                    text:
                        "The first Meetings mode must stay local and transparent about its limits."
                )
            }
        }
    }

    private func meetingColumns(
        items: [EditorialMeetingItem],
        compact: Bool
    ) -> some View {
        HStack(spacing: 12) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Text(verbatim: item.id)
                        .font(
                            VoxoLTypography.font(
                                size: 12,
                                weight: .semibold,
                                relativeTo: .caption
                            )
                        )
                        .foregroundStyle(theme.cobalt)
                        .frame(width: 32, height: 32)
                        .background(theme.cobaltSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(
                                VoxoLTypography.font(
                                    size: compact ? 14 : 16,
                                    weight: .semibold,
                                    relativeTo: .body
                                )
                            )
                            .foregroundStyle(theme.ink)
                            .lineLimit(2)
                        Text(item.detail)
                            .font(
                                VoxoLTypography.font(
                                    size: 12,
                                    relativeTo: .caption
                                )
                            )
                            .foregroundStyle(theme.secondaryInk)
                            .lineLimit(3)
                    }
                }
                .padding(compact ? 10 : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(theme.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func transcriptLine(time: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(verbatim: time)
                .foregroundStyle(theme.secondaryInk)
                .frame(width: 48, alignment: .leading)
            Text(text)
                .foregroundStyle(theme.ink)
        }
        .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var futureFlow: some View {
        HStack(spacing: 8) {
            futureStep(index: "1", title: "Choose a source")
            Rectangle().fill(theme.ink.opacity(0.14)).frame(maxWidth: 64, maxHeight: 1)
            futureStep(index: "2", title: "Capture locally")
            Rectangle().fill(theme.ink.opacity(0.14)).frame(maxWidth: 64, maxHeight: 1)
            futureStep(index: "3", title: "Review the report")
        }
        .padding(.horizontal, 16)
        .background(theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func futureStep(index: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: index)
                .font(
                    VoxoLTypography.font(
                        size: 12,
                        weight: .semibold,
                        relativeTo: .caption
                    )
                )
                .frame(width: 28, height: 28)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                }
            Text(title)
                .font(VoxoLTypography.font(size: 14, weight: .medium, relativeTo: .body))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func reveal() {
        guard !visible else { return }
        if reduceMotion {
            visible = true
        } else {
            Task { @MainActor in
                await Task.yield()
                visible = true
            }
        }
    }
}

// MARK: - Library

/// The Library holds what the user teaches VoxoL. The dictation history moved to the home page,
/// where it is the substance of the screen rather than a fourth tab showing the same records.
private enum EditorialLibraryTab: String, CaseIterable, Hashable {
    case dictionary
    case snippets
    case profiles

    var title: LocalizedStringKey {
        switch self {
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .profiles: "Profiles"
        }
    }
}

private enum EditorialLibrarySheet: Identifiable {
    case transcript(TranscriptRecord)
    case dictionary(DictionaryEntry?)
    case snippet(VoiceSnippet?)
    case profile

    var id: String {
        switch self {
        case .transcript(let record): "transcript-\(record.id)"
        case .dictionary(let entry): "dictionary-\(entry?.id.uuidString ?? "new")"
        case .snippet(let snippet): "snippet-\(snippet?.id.uuidString ?? "new")"
        case .profile: "profile-new"
        }
    }
}

struct EditorialLibraryView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts
    @Environment(PersonalizationStore.self) private var personalization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("voxol.writingProfile") private var writingProfile = WritingProfile.automatic
        .rawValue
    @AppStorage("voxol.learningEnabled") private var learningEnabled = true
    @AppStorage("voxol.privateMode") private var privateMode = false

    @State private var selectedTab = EditorialLibraryTab.dictionary
    @State private var presentedSheet: EditorialLibrarySheet?
    @State private var visible = false
    /// Bumped when a suggestion is ignored, so the strip recomputes — the
    /// ignore list lives in UserDefaults, which SwiftUI does not observe.
    @State private var suggestionRefresh = 0

    var body: some View {
        GeometryReader { geometry in
            let metrics = EditorialMetrics(geometry.size)

            VStack(alignment: .leading, spacing: 0) {
                EditorialPageHeader(
                    metrics: metrics,
                    eyebrow: "Library",
                    title: "Your words, always within reach.",
                    summary: "History, vocabulary and shortcuts stay organized in one place."
                )
                .padding(.bottom, metrics.headingGap)
                .editorialStagger(0, visible: visible)

                EditorialSegmentedControl(
                    options: EditorialLibraryTab.allCases,
                    selection: $selectedTab
                ) { option in
                    Text(option.title)
                }
                .fixedSize()
                .editorialStagger(1, visible: visible)

                libraryContent(metrics: metrics)
                    .padding(.top, 16)
                    .frame(maxHeight: .infinity)
                    .editorialStagger(2, visible: visible)
            }
            .padding(metrics.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { reveal() }
        .onDisappear { visible = false }
        .sheet(item: $presentedSheet) { sheet in
            sheetContent(sheet)
                .environment(theme)
        }
    }

    @ViewBuilder
    private func libraryContent(metrics: EditorialMetrics) -> some View {
        switch selectedTab {
        case .dictionary:
            dictionaryList(metrics: metrics)
        case .snippets:
            snippetsList(metrics: metrics)
        case .profiles:
            profilesList(metrics: metrics)
        }
    }

    /// Suggestions the learning pipeline is one correction short of adopting.
    private var pendingDictionarySuggestions: [DictionaryEntry] {
        guard learningEnabled, !privateMode else { return [] }
        let ignored = Set(
            UserDefaults.standard.stringArray(forKey: "voxol.dictionarySuggestionIgnores") ?? []
        )
        return DictionaryLearning.pendingSuggestions(
            from: personalization.corrections,
            existing: personalization.snapshot.dictionary
        )
        .filter { !ignored.contains(DictionaryLearning.suggestionKey($0)) }
    }

    private func ignoreDictionarySuggestion(_ entry: DictionaryEntry) {
        let key = "voxol.dictionarySuggestionIgnores"
        var ignored = UserDefaults.standard.stringArray(forKey: key) ?? []
        ignored.append(DictionaryLearning.suggestionKey(entry))
        UserDefaults.standard.set(ignored, forKey: key)
        suggestionRefresh += 1
    }

    private func dictionaryList(metrics: EditorialMetrics) -> some View {
        EditorialCard {
            VStack(spacing: 0) {
                libraryToolbar(
                    title: "Personal vocabulary",
                    detail: "Exact forms recognized locally",
                    actionTitle: "Add",
                    action: { presentedSheet = .dictionary(nil) }
                )
                Divider().overlay(theme.line)

                // One correction is not yet a rule — but it is worth showing.
                // The add button supplies the confidence a second occurrence
                // would have; ignore makes the proposal stay dismissed.
                let suggestions = pendingDictionarySuggestions
                if !suggestions.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(suggestions) { suggestion in
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.cobalt)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: suggestion.canonical)
                                        .font(
                                            VoxoLTypography.font(
                                                size: 13, weight: .medium, relativeTo: .body)
                                        )
                                        .foregroundStyle(theme.ink)
                                    Text(
                                        "Corrected once from “\(suggestion.spokenForms.first ?? "")”"
                                    )
                                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                                    .foregroundStyle(theme.secondaryInk)
                                }
                                Spacer()
                                Button("Ignore") { ignoreDictionarySuggestion(suggestion) }
                                    .buttonStyle(EditorialSettingsButtonStyle())
                                Button("Add") {
                                    Task {
                                        await personalization.addDictionaryEntry(suggestion)
                                    }
                                }
                                .buttonStyle(EditorialSettingsButtonStyle())
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(theme.cobaltSoft.opacity(0.25))
                            Divider().overlay(theme.line)
                        }
                    }
                    .id(suggestionRefresh)
                }

                if personalization.snapshot.dictionary.isEmpty, suggestions.isEmpty {
                    emptyLibraryState(
                        title: "No dictionary entries yet",
                        detail: "Add names and terms that VoxoL must write exactly."
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(personalization.snapshot.dictionary) { entry in
                                libraryDataRow(
                                    leading: entry.canonical,
                                    detail: entry.spokenForms.isEmpty
                                        ? String(localized: "Exact form")
                                        : entry.spokenForms.joined(separator: ", "),
                                    trailing: !entry.isEnabled
                                        ? String(localized: "Paused")
                                        : entry.origin == .learned
                                            ? String(localized: "Learned")
                                            : String(localized: "Active")
                                )
                                .contextMenu {
                                    Button("Edit") { presentedSheet = .dictionary(entry) }
                                    Button("Delete", role: .destructive) {
                                        Task {
                                            await personalization.removeDictionaryEntry(
                                                id: entry.id)
                                        }
                                    }
                                }
                                Divider().overlay(theme.line)
                            }
                        }
                    }
                }
            }
        }
    }

    private func snippetsList(metrics: EditorialMetrics) -> some View {
        EditorialCard {
            VStack(spacing: 0) {
                libraryToolbar(
                    title: "Voice snippets",
                    detail: "A spoken cue becomes your exact text",
                    actionTitle: "Add",
                    action: { presentedSheet = .snippet(nil) }
                )
                Divider().overlay(theme.line)

                if personalization.snapshot.snippets.isEmpty {
                    emptyLibraryState(
                        title: "No snippets yet",
                        detail: "Create a short voice cue for text you use often."
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(personalization.snapshot.snippets) { snippet in
                                libraryDataRow(
                                    leading: snippet.trigger,
                                    detail: snippet.expansion,
                                    trailing: snippet.isEnabled
                                        ? String(localized: "Active")
                                        : String(localized: "Paused")
                                )
                                .contextMenu {
                                    Button("Edit") { presentedSheet = .snippet(snippet) }
                                    Button("Delete", role: .destructive) {
                                        Task { await personalization.removeSnippet(id: snippet.id) }
                                    }
                                }
                                Divider().overlay(theme.line)
                            }
                        }
                    }
                }
            }
        }
    }

    private func profilesList(metrics: EditorialMetrics) -> some View {
        EditorialCard {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Choose how VoxoL writes")
                        .font(
                            VoxoLTypography.font(
                                size: metrics.eyebrowSize, weight: .semibold, relativeTo: .caption)
                        )
                        .foregroundStyle(theme.secondaryInk)
                        .textCase(.uppercase)
                        .tracking(1)

                    Text("Every profile keeps your meaning and your facts. Only the shape changes.")
                        .font(VoxoLTypography.font(size: metrics.summarySize, relativeTo: .body))
                        .foregroundStyle(theme.secondaryInk)
                        .padding(.top, 4)

                    // What each profile actually does, with the sentence it would produce.
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 12),
                            count: metrics.compact ? 2 : 3
                        ),
                        spacing: 12
                    ) {
                        ForEach(WritingProfile.allCases) { profile in
                            profileCard(profile, metrics: metrics)
                        }
                    }
                    .padding(.top, 16)

                    EditorialRule().padding(.vertical, 22)

                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Per-app rules")
                                .font(
                                    VoxoLTypography.font(
                                        size: metrics.eyebrowSize,
                                        weight: .semibold,
                                        relativeTo: .caption
                                    )
                                )
                                .foregroundStyle(theme.secondaryInk)
                                .textCase(.uppercase)
                                .tracking(1)
                            Text(
                                "Without a rule, VoxoL reads the destination: Mail writes an email, Slack a message, Xcode code."
                            )
                            .font(
                                VoxoLTypography.font(size: metrics.summarySize, relativeTo: .body)
                            )
                            .foregroundStyle(theme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button("Add") { presentedSheet = .profile }
                            .buttonStyle(SignalQuietButtonStyle())
                    }
                    .padding(.top, 2)

                    if personalization.snapshot.applicationProfiles.isEmpty {
                        Text("No rule yet — the profile above applies everywhere.")
                            .font(VoxoLTypography.font(size: metrics.bodySize, relativeTo: .body))
                            .foregroundStyle(theme.secondaryInk)
                            .padding(.top, 14)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(personalization.snapshot.applicationProfiles) { rule in
                                profileRuleRow(rule, metrics: metrics)
                                if rule.id != personalization.snapshot.applicationProfiles.last?.id
                                {
                                    EditorialRule()
                                }
                            }
                        }
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, metrics.compact ? 16 : 24)
                .padding(.vertical, metrics.compact ? 16 : 22)
            }
            .scrollIndicators(.visible)
        }
    }

    /// One profile, its promise and the sentence it produces, selectable as the default.
    private func profileCard(_ profile: WritingProfile, metrics: EditorialMetrics) -> some View {
        let selected = writingProfile == profile.rawValue
        return Button {
            withAnimation(EditorialMotion.soft) { writingProfile = profile.rawValue }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(profileTitle(profile))
                        .font(
                            VoxoLTypography.font(size: 13.5, weight: .semibold, relativeTo: .body)
                        )
                        .foregroundStyle(theme.ink)
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.cobalt)
                    }
                }

                Text(profileDetail(profile))
                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3)

                Text(profileExample(profile))
                    .font(VoxoLTypography.font(size: 11.5, relativeTo: .body))
                    .foregroundStyle(theme.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(theme.canvas.opacity(0.7))
                    )
                    .padding(.top, 10)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(selected ? theme.cobaltSoft.opacity(0.35) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(selected ? theme.cobalt.opacity(0.5) : theme.line, lineWidth: 1)
            )
        }
        .buttonStyle(SignalPressButtonStyle())
    }

    private func profileRuleRow(
        _ rule: ApplicationProfileRule,
        metrics: EditorialMetrics
    ) -> some View {
        HStack(spacing: 12) {
            Group {
                if let icon = ApplicationIconCache.icon(forBundleIdentifier: rule.bundleIdentifier)
                {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.selection)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(
                    verbatim: ApplicationIconCache.name(forBundleIdentifier: rule.bundleIdentifier)
                        ?? rule.bundleIdentifier
                )
                .font(VoxoLTypography.font(size: 13, weight: .medium, relativeTo: .body))
                .foregroundStyle(theme.ink)
                .lineLimit(1)

                Text(verbatim: rule.domain ?? String(localized: "Every domain"))
                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(profileTitle(rule.profile))
                .font(VoxoLTypography.font(size: 11.5, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(theme.selection))

            Button {
                Task { await personalization.removeProfileRule(id: rule.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryInk)
            }
            .buttonStyle(SignalPressButtonStyle())
            .help("Delete")
        }
        .padding(.vertical, 10)
    }

    /// What the profile changes, in one line.
    private func profileDetail(_ profile: WritingProfile) -> LocalizedStringKey {
        switch profile {
        case .automatic: "Reads the destination app and picks one of the others."
        case .chat: "Short, spoken, light punctuation."
        case .email: "Structured sentences and a clean sign-off."
        case .document: "Full paragraphs and real punctuation."
        case .developer: "Identifiers, paths and technical terms kept exact."
        case .prompt: "A clear instruction, no filler."
        case .raw: "Exactly what was heard, untouched."
        }
    }

    /// The same dictation, as each profile would write it.
    private func profileExample(_ profile: WritingProfile) -> LocalizedStringKey {
        switch profile {
        case .automatic: "Whatever the app in front of you expects."
        case .chat: "works for me, thursday 9?"
        case .email: "Hello, could we move it to Thursday at 9 a.m.? Best,"
        case .document: "The check-in is moved to Thursday at 9 a.m."
        case .developer: "Rename `authToken` to `sessionToken` in src/auth.ts."
        case .prompt: "Move the check-in to Thursday 9 a.m. and tell the team."
        case .raw: "uh we move the check-in thursday no thursday 9"
        }
    }

    private func libraryToolbar(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        actionTitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(VoxoLTypography.font(size: 16, weight: .medium, relativeTo: .body))
                    .foregroundStyle(theme.ink)
                Text(detail)
                    .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
            }
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(SignalSecondaryButtonStyle())
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 72)
    }

    private func libraryDataRow(
        leading: String,
        detail: String,
        trailing: String
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: leading)
                    .font(VoxoLTypography.font(size: 16, weight: .medium, relativeTo: .body))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(verbatim: detail)
                    .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer()
            Text(verbatim: trailing)
                .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
    }

    private func emptyLibraryState(
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(VoxoLTypography.font(size: 16, weight: .medium, relativeTo: .body))
                .foregroundStyle(theme.ink)
            Text(detail)
                .font(VoxoLTypography.font(size: 14, relativeTo: .body))
                .foregroundStyle(theme.secondaryInk)
        }
        .frame(maxWidth: .infinity, minHeight: 144)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: EditorialLibrarySheet) -> some View {
        switch sheet {
        case .transcript(let record):
            TranscriptEditor(text: record.text) { editedText in
                Task {
                    guard let edit = await transcripts.replaceText(for: record.id, with: editedText)
                    else { return }
                    guard learningEnabled, !privateMode else { return }
                    let detected = LanguageDetector.detect(edit.correctedText)
                    await personalization.addCorrection(
                        CorrectionPair(
                            rawTranscript: edit.rawTranscript,
                            correctedText: edit.correctedText,
                            bundleIdentifier: edit.applicationBundleIdentifier,
                            profile: .automatic,
                            language: detected == .french ? .french : .english
                        )
                    )
                }
            }
        case .dictionary(let entry):
            DictionaryEntryEditor(entry: entry) { saved in
                Task {
                    if entry == nil {
                        await personalization.addDictionaryEntry(saved)
                    } else {
                        await personalization.updateDictionaryEntry(saved)
                    }
                }
            }
        case .snippet(let snippet):
            SnippetEditor(
                snippet: snippet,
                existingTriggers: personalization.snapshot.snippets
                    .filter { $0.id != snippet?.id }
                    .map(\.trigger)
            ) { saved in
                Task {
                    if snippet == nil {
                        await personalization.addSnippet(saved)
                    } else {
                        await personalization.updateSnippet(saved)
                    }
                }
            }
        case .profile:
            EditorialProfileRuleEditor { bundle, domain, profile in
                Task { await personalization.setProfile(profile, for: bundle, domain: domain) }
            }
        }
    }

    private func profileTitle(_ profile: WritingProfile) -> LocalizedStringKey {
        switch profile {
        case .automatic: "Automatic"
        case .chat: "Chat"
        case .email: "Email"
        case .document: "Document"
        case .developer: "Developer"
        case .prompt: "Prompt"
        case .raw: "Raw"
        }
    }

    private func profileTitleString(_ profile: WritingProfile) -> String {
        switch profile {
        case .automatic: String(localized: "Automatic")
        case .chat: String(localized: "Chat")
        case .email: String(localized: "Email")
        case .document: String(localized: "Document")
        case .developer: String(localized: "Developer")
        case .prompt: String(localized: "Prompt")
        case .raw: String(localized: "Raw")
        }
    }

    private func reveal() {
        guard !visible else { return }
        if reduceMotion {
            visible = true
        } else {
            Task { @MainActor in
                await Task.yield()
                visible = true
            }
        }
    }
}

private struct EditorialProfileRuleEditor: View {
    @Environment(\.dismiss) private var dismiss

    let save: (String, String?, WritingProfile) -> Void
    @State private var bundleIdentifier = ""
    @State private var domain = ""
    @State private var profile = WritingProfile.email

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Automatic profile")
                .font(VoxoLTypography.font(size: 24, weight: .semibold, relativeTo: .title2))
            TextField("Bundle identifier", text: $bundleIdentifier)
            TextField("Domain (optional)", text: $domain)
            Picker("Profile", selection: $profile) {
                ForEach(WritingProfile.allCases.filter { $0 != .automatic }) { option in
                    Text(option.rawValue.capitalized).tag(option)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let bundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                    let site = domain.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(bundle, site.isEmpty ? nil : site, profile)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

// MARK: - Settings

enum EditorialSettingsSection: String, CaseIterable, Hashable {
    case general
    case audio
    case engines
    case setup
    case privacy
    case about

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .audio: "Dictation"
        case .engines: "Local engines"
        case .setup: "Permissions"
        case .privacy: "Privacy"
        case .about: "About & support"
        }
    }

    /// SF Symbol shown beside the section, so the list reads at a glance.
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .audio: "mic"
        case .engines: "cpu"
        case .setup: "lock.shield"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }

    /// Sections about how VoxoL behaves come first; sections about the machine follow.
    var group: LocalizedStringKey {
        switch self {
        case .general, .audio, .engines: "Settings"
        case .setup, .privacy, .about: "This Mac"
        }
    }
}

/// Says what the capture stores and why the public benchmarks cannot replace it.
let personalCaptureDetail = """
    Keeps each dictation's audio locally so accuracy on your own voice can be \
    measured — the public benchmarks cannot see technical vocabulary or how \
    numbers are written. Correction learning below stores the text; this adds \
    the audio a re-run needs. Nothing leaves this Mac, capped at 500 MB, off \
    in private mode.
    """

struct EditorialSettingsView: View {
    @AppStorage("voxol.correctionCapture") private var correctionCapture = false
    @Environment(VoxoLTheme.self) private var theme
    @Environment(ModelInstallationStore.self) private var models
    @Environment(PermissionCoordinator.self) private var permissions
    @Environment(PersonalizationStore.self) private var personalization
    @Environment(DictationSessionCoordinator.self) private var dictationSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var languageCode: String
    @Binding var section: EditorialSettingsSection
    let replayPreflight: () -> Void

    @AppStorage("voxol.activationMode") private var activationMode = ActivationMode.hold
    @AppStorage("voxol.dictationShortcut") private var shortcut = DictationShortcut.optionSpace
    @AppStorage("voxol.dictationLanguage") private var language =
        DictationLanguagePreference.preferred
    @AppStorage("voxol.cleanupMode") private var cleanup = DictationCleanupMode.faithful
    @AppStorage("voxol.inputDeviceUID") private var inputDeviceUID = ""
    @AppStorage("voxol.voiceProcessingMode") private var voiceProcessingMode = "disabled"
    @AppStorage("voxol.privateMode") private var privateMode = false
    @AppStorage("voxol.historyEnabled") private var historyEnabled = true
    @AppStorage("voxol.contextEnabled") private var contextEnabled = true
    @AppStorage("voxol.learningEnabled") private var learningEnabled = true

    @State private var visible = false
    @State private var showsAppearanceNote = false
    @State private var updateCheckInFlight = false
    @State private var updateCheckedOnce = false
    @State private var availableUpdate: UpdateCheck.Release?

    var body: some View {
        GeometryReader { geometry in
            let metrics = EditorialMetrics(geometry.size)

            VStack(alignment: .leading, spacing: 0) {
                EditorialPageHeader(
                    metrics: metrics,
                    eyebrow: "Settings",
                    title: "Simple every day, precise when needed.",
                    summary: "System preferences, engines and privacy live here."
                )
                .padding(.bottom, metrics.headingGap)
                .editorialStagger(0, visible: visible)

                HStack(alignment: .top, spacing: metrics.compact ? 16 : 24) {
                    settingsNavigation(metrics: metrics)
                        .frame(width: metrics.compact ? 164 : 216)
                    settingsCard(metrics: metrics)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .id(section)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                .frame(maxHeight: .infinity)
                .editorialStagger(1, visible: visible)
            }
            .padding(metrics.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .editorialDropdownHost()
        .onAppear { reveal() }
        .onDisappear { visible = false }
        .onChange(of: privateMode) { _, enabled in
            if enabled {
                historyEnabled = false
                learningEnabled = false
            }
        }
    }

    private func settingsNavigation(metrics: EditorialMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(settingsGroups.enumerated()), id: \.offset) { index, group in
                Text(group.title)
                    .font(
                        VoxoLTypography.font(
                            size: metrics.eyebrowSize, weight: .semibold, relativeTo: .caption)
                    )
                    .foregroundStyle(theme.secondaryInk)
                    .textCase(.uppercase)
                    .tracking(1)
                    .padding(.leading, 10)
                    .padding(.top, index == 0 ? 0 : 20)
                    .padding(.bottom, 6)

                ForEach(group.sections, id: \.self) { item in
                    Button {
                        withAnimation(EditorialMotion.soft) { section = item }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(section == item ? theme.ink : theme.secondaryInk)
                                .frame(width: 16)
                            Text(item.title)
                                .font(
                                    VoxoLTypography.font(
                                        size: 13, weight: .medium, relativeTo: .body)
                                )
                                .foregroundStyle(theme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(section == item ? theme.selection : .clear)
                        )
                    }
                    .buttonStyle(SignalPressButtonStyle())
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var settingsGroups: [(title: LocalizedStringKey, sections: [EditorialSettingsSection])]
    {
        [
            ("Settings", [.general, .audio, .engines]),
            ("This Mac", [.setup, .privacy, .about]),
        ]
    }

    @ViewBuilder
    private func settingsCard(metrics: EditorialMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(VoxoLTypography.font(size: 17, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(theme.ink)
                .padding(.bottom, 12)

            // Sections outgrew the window once dictation moved in here, so the panel scrolls
            // rather than clipping its last row.
            ScrollView {
                VStack(spacing: 0) {
                    switch section {
                    case .setup:
                        setupRows(metrics: metrics)
                    case .general:
                        generalRows(metrics: metrics)
                    case .audio:
                        audioRows(metrics: metrics)
                    case .engines:
                        engineRows(metrics: metrics)
                    case .privacy:
                        privacyRows(metrics: metrics)
                    case .about:
                        aboutRows(metrics: metrics)
                    }
                }
                .padding(.horizontal, metrics.compact ? 16 : 20)
            }
            .scrollIndicators(.visible)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.canvas.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.line, lineWidth: 1)
            )
        }
    }

    private func setupRows(metrics: EditorialMetrics) -> some View {
        Group {
            permissionRow(
                .microphone,
                title: "Microphone",
                detail: "Hear the words you choose to dictate",
                metrics: metrics
            )
            settingsDivider
            permissionRow(
                .accessibility,
                title: "Accessibility",
                detail: "Insert prepared text into the active app",
                metrics: metrics
            )
            settingsDivider
            permissionRow(
                .inputMonitoring,
                title: "Input Monitoring",
                detail: "Detect your shortcut in other apps",
                metrics: metrics
            )
            settingsDivider
            settingsRow(
                title: "Local engines · settings",
                detail: LocalizedStringKey(
                    "\(models.installedCount) of \(models.items.count) installed"
                ),
                metrics: metrics
            ) {
                if models.allInstalled {
                    Label("Ready", systemImage: "checkmark")
                        .font(VoxoLTypography.font(size: 14, weight: .medium, relativeTo: .body))
                        .foregroundStyle(theme.success)
                } else {
                    Button("Review") {
                        withAnimation(EditorialMotion.soft) { section = .engines }
                    }
                    .buttonStyle(EditorialSettingsButtonStyle())
                }
            }
        }
    }

    private func generalRows(metrics: EditorialMetrics) -> some View {
        Group {
            settingsRow(
                title: "Interface language",
                detail: languageCode == AppLanguage.french.rawValue ? "Français" : "English",
                metrics: metrics
            ) {
                EditorialDropdown(
                    options: AppLanguage.allCases.map {
                        EditorialDropdownOption(id: $0.rawValue, verbatim: $0.displayName)
                    },
                    selectedID: languageCode,
                    select: { languageCode = $0 }
                )
                .fixedSize()
            }
            settingsDivider
            settingsRow(
                title: "Appearance",
                detail: "Light",
                metrics: metrics
            ) {
                Button("Change") { showsAppearanceNote.toggle() }
                    .buttonStyle(EditorialSettingsButtonStyle())
                    .popover(isPresented: $showsAppearanceNote, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Signal editorial is light by design.")
                                .font(
                                    VoxoLTypography.font(
                                        size: 16,
                                        weight: .semibold,
                                        relativeTo: .headline
                                    )
                                )
                            Text(
                                "Replay the product tour to revisit the interface and local setup."
                            )
                            .font(VoxoLTypography.font(size: 13, relativeTo: .body))
                            .foregroundStyle(theme.secondaryInk)
                        }
                        .padding(18)
                        .frame(width: 300)
                        .background(theme.surface)
                    }
            }
            settingsDivider
            // Replaying the tour was buried inside the appearance popover, where nobody would
            // think to look for it.
            settingsRow(
                title: "Guided setup",
                detail: "Replay the tour and re-check this Mac",
                metrics: metrics
            ) {
                Button("Replay", action: replayPreflight)
                    .buttonStyle(EditorialSettingsButtonStyle())
            }
        }
    }

    private func audioRows(metrics: EditorialMetrics) -> some View {
        Group {
            permissionRow(
                .microphone, title: "Microphone", detail: "Hear the words you choose to dictate",
                metrics: metrics)
            settingsDivider
            permissionRow(
                .accessibility, title: "Accessibility",
                detail: "Insert prepared text into the active app", metrics: metrics)
            settingsDivider
            permissionRow(
                .inputMonitoring, title: "Input Monitoring",
                detail: "Detect your shortcut in other apps", metrics: metrics)
            settingsDivider
            settingsRow(
                title: "Dictation shortcut",
                detail: LocalizedStringKey(shortcut.label),
                metrics: metrics
            ) {
                shortcutMenu
            }
            settingsDivider
            settingsRow(
                title: "Activation",
                detail: activationMode == .hold ? "Hold to speak" : "Press to toggle",
                metrics: metrics
            ) {
                EditorialDropdown(
                    options: ActivationMode.allCases.map {
                        EditorialDropdownOption(id: $0.rawValue, $0.title)
                    },
                    selectedID: activationMode.rawValue,
                    select: { activationMode = ActivationMode(rawValue: $0) ?? .hold }
                )
            }
            settingsDivider
            settingsRow(
                title: "Input device",
                detail: "Which microphone VoxoL records from",
                metrics: metrics
            ) {
                AudioInputPicker(selectedUID: $inputDeviceUID)
            }
            settingsDivider
            settingsRow(
                title: "Dictation language",
                detail: language.title,
                metrics: metrics
            ) {
                EditorialDropdown(
                    options: DictationLanguagePreference.allCases.map {
                        EditorialDropdownOption(id: $0.rawValue, $0.title)
                    },
                    selectedID: language.rawValue,
                    select: { language = DictationLanguagePreference(rawValue: $0) ?? .preferred }
                )
            }
            settingsDivider
            settingsRow(
                title: "Preparation",
                detail: preparationDetail,
                metrics: metrics
            ) {
                EditorialDropdown(
                    options: DictationCleanupMode.allCases.map {
                        EditorialDropdownOption(id: $0.rawValue, $0.title)
                    },
                    selectedID: cleanup.rawValue,
                    select: { cleanup = DictationCleanupMode(rawValue: $0) ?? .faithful }
                )
            }
        }
    }

    private var preparationDetail: LocalizedStringKey {
        switch cleanup {
        case .faithful: "Faithful cleanup of what you said"
        case .rewrite: "Rewritten to read like written text"
        case .raw: "Raw transcript, untouched"
        }
    }

    private var shortcutMenu: some View {
        EditorialDropdown(
            options: DictationShortcut.allCases.map {
                EditorialDropdownOption(id: $0.rawValue, verbatim: String(localized: $0.localizedTitle))
            },
            selectedID: shortcut.rawValue,
            select: { shortcut = DictationShortcut(rawValue: $0) ?? .optionSpace }
        )
    }

    @ViewBuilder
    private func engineRows(metrics: EditorialMetrics) -> some View {
        if models.items.isEmpty {
            settingsRow(
                title: "Local engines · settings",
                detail: models.manifestLoadFailed
                    ? "The verified manifest could not be loaded"
                    : "Checking verified artifacts…",
                metrics: metrics
            ) {
                ProgressView().controlSize(.small)
            }
        } else {
            ForEach(Array(models.items.enumerated()), id: \.element.id) { index, item in
                settingsRow(
                    title: item.model.role == .asr ? "Parakeet" : "Qwen",
                    detail: modelDetail(item),
                    metrics: metrics
                ) {
                    modelAction(item)
                }
                if index < models.items.count - 1 {
                    settingsDivider
                }
            }
            settingsDivider
            settingsRow(
                title: "Content-free diagnostics",
                detail: "Timings and failure codes, without text or audio",
                metrics: metrics
            ) {
                Button("Export") { exportDiagnostics() }
                    .buttonStyle(EditorialSettingsButtonStyle())
                    .disabled(dictationSession.lastReport == nil)
            }
        }
    }

    private func privacyRows(metrics: EditorialMetrics) -> some View {
        Group {
            settingsRow(
                title: "Private mode",
                detail: "Overrides history and learning",
                metrics: metrics
            ) {
                Toggle("Private mode", isOn: $privateMode).labelsHidden()
            }
            settingsDivider
            settingsRow(
                title: "Local history",
                detail: "Keep successful transcriptions on this Mac",
                metrics: metrics
            ) {
                Toggle("Local history", isOn: $historyEnabled)
                    .labelsHidden()
                    .disabled(privateMode)
            }
            settingsDivider
            settingsRow(
                title: "Bounded context",
                detail: "Use nearby text only for the current dictation",
                metrics: metrics
            ) {
                Toggle("Bounded context", isOn: $contextEnabled).labelsHidden()
            }
            settingsDivider
            settingsRow(
                title: "Personal benchmark capture",
                detail: LocalizedStringKey(personalCaptureDetail),
                metrics: metrics
            ) {
                Toggle("Personal benchmark capture", isOn: $correctionCapture)
                    .labelsHidden()
                    .disabled(privateMode)
            }
            settingsDivider
            settingsRow(
                title: "Correction learning",
                detail: "\(personalization.corrections.count) approved local pairs",
                metrics: metrics
            ) {
                HStack(spacing: 8) {
                    Toggle("Correction learning", isOn: $learningEnabled)
                        .labelsHidden()
                        .disabled(privateMode)
                    Menu {
                        Button("Export reviewed pairs") { exportCorrections() }
                            .disabled(personalization.corrections.isEmpty)
                        Button("Delete correction data", role: .destructive) {
                            Task { await personalization.removeAllCorrections() }
                        }
                        .disabled(personalization.corrections.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 32, height: 32)
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        }
    }

    private func permissionRow(
        _ permission: VoxoLPermission,
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        metrics: EditorialMetrics
    ) -> some View {
        settingsRow(title: title, detail: detail, metrics: metrics) {
            let status = permissions.status(for: permission)
            // Accessibility and Input Monitoring are only ever completed in System Settings, so a
            // pending request keeps a live route there rather than an inert "Waiting…".
            let settlesInSettings = permission != .microphone
            Button(permissionActionTitle(status, permission: permission)) {
                if status == .denied || status == .restricted
                    || (status == .requesting && settlesInSettings)
                {
                    permissions.openSystemSettings(for: permission)
                } else if status != .granted {
                    Task { await permissions.request(permission) }
                }
            }
            .buttonStyle(EditorialSettingsButtonStyle())
            .disabled(status == .granted || (status == .requesting && !settlesInSettings))
        }
    }

    /// Update check and bug reporting.
    ///
    /// Both exist because a shipped build is otherwise a dead end: a user has
    /// no way to learn a fix exists, and no way to tell anyone it is needed.
    /// Neither sends anything on its own — the check reads a public release
    /// list, and the report opens a prefilled issue the user submits.
    private func aboutRows(metrics: EditorialMetrics) -> some View {
        Group {
            settingsRow(
                title: "Version",
                detail: LocalizedStringKey(
                    "\(BugReportComposer.Environment.current().applicationVersion) · macOS only"
                ),
                metrics: metrics
            ) {
                Button(updateStatusTitle) {
                    Task { await checkForUpdate() }
                }
                .buttonStyle(SignalPressButtonStyle())
                .disabled(updateCheckInFlight)
            }
            settingsDivider
            settingsRow(
                title: "Report a problem",
                detail: "Opens a prefilled issue · timings only, never your text",
                metrics: metrics
            ) {
                Button("Report") { openBugReport() }
                    .buttonStyle(SignalPressButtonStyle())
            }
        }
    }

    private var updateStatusTitle: LocalizedStringKey {
        if updateCheckInFlight { return "Checking…" }
        if let available = availableUpdate { return "Update to \(available.version)" }
        return updateCheckedOnce ? "Up to date" : "Check for updates"
    }

    private func checkForUpdate() async {
        updateCheckInFlight = true
        defer { updateCheckInFlight = false; updateCheckedOnce = true }
        // Delegated rather than duplicated: this used to run its own copy of
        // the same fetch and comparison, so the row here and the sidebar badge
        // could disagree about whether an update existed. One reader, one
        // answer. `announce: false` keeps the alert out of the way of someone
        // who is already looking at the result.
        await UpdateNotifier.shared.check(announce: false)
        availableUpdate = UpdateNotifier.shared.available
        if availableUpdate != nil {
            UpdateNotifier.shared.installAvailableUpdate()
        }
    }

    private func openBugReport() {
        let diagnostics = try? DictationSessionCoordinator.shared.diagnosticsExportData()
        let body = BugReportComposer.body(
            summary: "",
            steps: "",
            environment: .current(),
            diagnostics: diagnostics.flatMap { String(data: $0, encoding: .utf8) }
        )
        guard let url = BugReportComposer.issueURL(title: "", body: body) else { return }
        NSWorkspace.shared.open(url)
    }

    private func settingsRow<Control: View>(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        metrics: EditorialMetrics,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(VoxoLTypography.font(size: 13.5, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(theme.ink)
                Text(detail)
                    .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, metrics.compact ? 12 : 14)
        .frame(minHeight: metrics.compact ? 56 : 62)
    }

    private var settingsDivider: some View {
        Divider().overlay(theme.line)
    }

    @ViewBuilder
    private func modelAction(_ item: ModelInstallationItem) -> some View {
        switch item.phase {
        case .loading, .verifying:
            ProgressView().controlSize(.small)
        case .downloading:
            Button("Pause") { models.pause(item.id) }
                .buttonStyle(EditorialSettingsButtonStyle())
        case .readyToDownload, .paused, .failed:
            Button(item.phase == .failed ? "Retry" : "Install") { models.install(item.id) }
                .buttonStyle(EditorialSettingsButtonStyle())
        case .installed:
            HStack(spacing: 6) {
                EditorialIcon(name: "check", size: 16)
                Text("Ready")
            }
            .font(VoxoLTypography.font(size: 14, weight: .medium, relativeTo: .body))
            .foregroundStyle(theme.success)
        case .awaitingVerifiedArtifact:
            Text("Unavailable")
                .font(VoxoLTypography.font(size: 14, relativeTo: .body))
                .foregroundStyle(theme.secondaryInk)
        }
    }

    private func modelDetail(_ item: ModelInstallationItem) -> LocalizedStringKey {
        switch item.phase {
        case .loading: "Checking the local artifact"
        case .awaitingVerifiedArtifact: "No release artifact has passed verification"
        case .readyToDownload: "Verified artifact ready to install"
        case .downloading:
            LocalizedStringKey("Downloading · \(Int((item.progress * 100).rounded())) %")
        case .paused:
            LocalizedStringKey("Paused · \(Int((item.progress * 100).rounded())) %")
        case .verifying: "Verifying checksum and runtime"
        case .installed: "Installed and verified on this Mac"
        case .failed:
            LocalizedStringKey(item.failureReason ?? String(localized: "Installation failed"))
        }
    }

    private func permissionActionTitle(
        _ status: VoxoLPermissionStatus,
        permission: VoxoLPermission
    ) -> LocalizedStringKey {
        switch status {
        case .granted: "Allowed"
        case .requesting: permission == .microphone ? "Waiting…" : "Open Settings"
        case .denied, .restricted: "Open Settings"
        case .notRequested: "Allow"
        }
    }

    private func exportCorrections() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voxol-reviewed-corrections.jsonl"
        guard panel.runModal() == .OK, let url = panel.url,
            let data = try? personalization.correctionExportData()
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voxol-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url,
            let data = try? dictationSession.diagnosticsExportData()
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func reveal() {
        guard !visible else { return }
        if reduceMotion {
            visible = true
        } else {
            Task { @MainActor in
                await Task.yield()
                visible = true
            }
        }
    }
}

private struct EditorialSettingsButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoxoLTypography.font(size: 14, weight: .medium, relativeTo: .body))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(configuration.isPressed ? theme.cobaltSoft : theme.selection)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.48)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}
