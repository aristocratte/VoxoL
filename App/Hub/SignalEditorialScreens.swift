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

struct EditorialStatusChip: View {
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

struct EditorialWaveMini: View {
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

struct EditorialDictationTriggerModifier: ViewModifier {
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

extension View {
    func editorialDictationTrigger(setupReady: Bool, openSetup: @escaping () -> Void) -> some View {
        modifier(EditorialDictationTriggerModifier(setupReady: setupReady, openSetup: openSetup))
    }
}

// MARK: - Today

/// One dictation's date and length, computed once so the charts and totals never split the same
/// text twice.
private struct EditorialWordEntry {
    let date: Date
    let words: Int
    let seconds: TimeInterval

    init(_ record: TranscriptRecord) {
        date = record.createdAt
        words = record.wordCount
        seconds = max(0, record.durationSeconds)
    }
}

private struct EditorialHistoryDay: Identifiable {
    let day: Date
    let title: String
    let records: [TranscriptRecord]

    var id: Date { day }
    var lastID: UUID? { records.last?.id }
}

/// Everything Today reads from the history, rebuilt only when the history changes.
///
/// It used to be recomputed on every hover — the grouping, every word count, the week, even the
/// last row of each day for every row. With a few hundred dictations that was the lag.
private struct EditorialTodaySnapshot {
    var days: [EditorialHistoryDay] = []
    var weekBars: [CGFloat] = Array(repeating: 0, count: 7)
    var weekLabels: [String] = []
    var totalWords = 0
    var averageWordsPerMinute = 0
    var todayRecoveredMinutes = 0

    init() {}

    init(records: [TranscriptRecord], usesFixture: Bool, locale: Locale) {
        var calendar = Calendar.current
        calendar.locale = locale
        days = Self.group(records, calendar: calendar, locale: locale)
        weekLabels = EditorialActivitySeries.weekdayInitials(days: 7, calendar: calendar)
        if usesFixture {
            weekBars = EditorialActivitySeries.fixtureWeek
            totalWords = 20_837
            averageWordsPerMinute = 148
            todayRecoveredMinutes = 3
            return
        }

        let entries = records.map(EditorialWordEntry.init)
        let words = entries.reduce(0) { $0 + $1.words }
        let seconds = entries.reduce(0) { $0 + $1.seconds }
        totalWords = words
        averageWordsPerMinute = seconds > 0 ? Int((Double(words) / seconds * 60).rounded()) : 0
        weekBars = EditorialActivitySeries.normalized(
            EditorialActivitySeries.dailyWords(entries, days: 7, calendar: calendar))

        let today = entries.filter { calendar.isDateInToday($0.date) }
        let todayWords = today.reduce(0) { $0 + $1.words }
        let todaySeconds = today.reduce(0) { $0 + $1.seconds }
        let typedSeconds = Double(todayWords) / 40 * 60
        todayRecoveredMinutes = max(0, Int(((typedSeconds - todaySeconds) / 60).rounded()))
    }

    /// Newest first, split into calendar days with a readable heading.
    static func group(
        _ records: [TranscriptRecord], calendar: Calendar, locale: Locale
    ) -> [EditorialHistoryDay] {
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) {
                title = String(localized: "Today")
            } else if calendar.isDateInYesterday(day) {
                title = String(localized: "Yesterday")
            } else {
                title = day.formatted(
                    .dateTime.weekday(.wide).day().month(.wide).locale(locale))
            }
            return EditorialHistoryDay(
                day: day,
                title: title.uppercased(with: locale),
                records: grouped[day]?.sorted { $0.createdAt > $1.createdAt } ?? []
            )
        }
    }
}

/// How the runtime's state reads on screen: one wording and one colour, shared by every surface
/// that shows it, so Today and the sidebar can never disagree.
@MainActor
struct EditorialRuntimePresentation {
    let state: DictationRuntimeState
    let lastError: String?

    init(_ session: DictationSessionCoordinator) {
        state = session.state
        lastError = session.lastError
    }

    var isListening: Bool {
        switch state {
        case .listening, .speechDetected: true
        default: false
        }
    }

    var isActive: Bool {
        switch state {
        case .listening, .speechDetected, .transcribing, .polishing, .inserting: true
        default: false
        }
    }

    var signalMode: HubSignalMode {
        switch state {
        case .listening, .speechDetected: .voice
        case .transcribing, .polishing, .inserting: .processing
        default: .idle
        }
    }

    /// What the runtime is doing, named for what it is.
    ///
    /// A dictation that failed is not a broken setup: saying "setup required" after one bad
    /// insertion sends the user hunting through permissions for a problem that is not there.
    var title: LocalizedStringKey {
        switch state {
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
    var help: LocalizedStringKey? {
        switch state {
        case .failed:
            lastError.map { LocalizedStringKey($0) }
                ?? LocalizedStringKey("The last dictation did not complete.")
        case .captureNeedsModel:
            "The transcription model is not available."
        case .waitingForInputMonitoring:
            "Allow Input Monitoring so the shortcut works everywhere."
        default:
            nil
        }
    }

    func tone(_ theme: VoxoLTheme) -> Color {
        switch state {
        case .listening, .speechDetected: theme.coral
        case .transcribing, .polishing, .inserting: theme.cobalt
        case .failed, .captureNeedsModel, .waitingForInputMonitoring: theme.warning
        default: theme.success
        }
    }
}

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
    @AppStorage("voxol.privateMode") private var privateMode = false
    @AppStorage("voxol.historyEnabled") private var historyEnabled = true
    @State private var visible = false
    @State private var inspectedRecord: TranscriptRecord?
    @State private var recentCardIsHovered = false
    @State private var snapshot = EditorialTodaySnapshot()
    @State private var query = ""
    @State private var displayedDays: [EditorialHistoryDay] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let metrics = EditorialMetrics(geometry.size)
            let sidebarWidth: CGFloat = metrics.compact ? 0 : 232

            HStack(alignment: .top, spacing: metrics.compact ? 0 : 26) {
                VStack(alignment: .leading, spacing: 0) {
                    welcomeHeader(metrics: metrics)
                        .editorialStagger(0, visible: visible)

                    stage(metrics: metrics)
                        .padding(.top, metrics.compact ? 18 : 24)
                        .editorialStagger(1, visible: visible)

                    if metrics.compact {
                        statsRow(metrics: metrics)
                            .padding(.top, 18)
                            .editorialStagger(2, visible: visible)
                    }

                    historyFeed(metrics: metrics)
                        .padding(.top, metrics.compact ? 22 : 30)
                        .frame(maxHeight: .infinity, alignment: .top)
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
        .onChange(of: transcripts.records, initial: true) { _, _ in rebuildSnapshot() }
        .onChange(of: transcripts.usesExampleData) { _, _ in rebuildSnapshot() }
        .onChange(of: locale) { _, _ in rebuildSnapshot() }
        .task(id: query) {
            if !query.isEmpty {
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            rebuildSearchResults()
        }
        .background {
            Button("Search dictations") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
        .sheet(item: $inspectedRecord) { record in
            TranscriptDetailSheet(record: record, store: transcripts)
                .environment(theme)
        }
    }

    private func rebuildSnapshot() {
        snapshot = EditorialTodaySnapshot(
            records: transcripts.records,
            usesFixture: usesPrototypeFixture,
            locale: locale
        )
        rebuildSearchResults()
    }

    /// A home page should say hello and name the day, not open on a control panel.
    private func welcomeHeader(metrics: EditorialMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: todayLabel)
                .font(
                    VoxoLTypography.font(
                        size: metrics.eyebrowSize, weight: .semibold, relativeTo: .caption)
                )
                .foregroundStyle(theme.secondaryInk)
                .textCase(.uppercase)
                .tracking(1)
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

    /// The page's one action, set in the signal it drives: the live state on top, the promise
    /// in the middle, the trigger and the microphone below, and the dither answering the runtime.
    private func stage(metrics: EditorialMetrics) -> some View {
        ZStack(alignment: .leading) {
            theme.canvas

            HubDitherField(mode: runtime.signalMode, cadence: runtime.isActive ? .live : .still)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: metrics.compact ? 0.3 : 0.38),
                            .init(color: .black, location: metrics.compact ? 0.8 : 0.78),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    statusChip

                    Text(stageHeadline)
                        .font(
                            VoxoLTypography.font(
                                size: metrics.compact ? 21 : 24, weight: .semibold,
                                relativeTo: .title)
                        )
                        .foregroundStyle(theme.ink)
                        .tracking(-0.6)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 12)

                    Text(stageInstruction)
                        .font(VoxoLTypography.font(size: metrics.bodySize, relativeTo: .body))
                        .foregroundStyle(theme.secondaryInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)

                    HStack(spacing: metrics.compact ? 10 : 12) {
                        triggerButton
                        AudioInputPicker(selectedUID: $inputDeviceUID, compact: metrics.compact)
                    }
                    .padding(.top, metrics.compact ? 14 : 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !metrics.compact {
                    VoxoLMark(size: 44)
                        .frame(width: 84, height: 84)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.black.opacity(0.05), lineWidth: 1)
                        }
                        .shadow(color: theme.ink.opacity(0.08), radius: 16, y: 8)
                        .padding(.trailing, 36)
                }
            }
            .padding(metrics.compact ? 20 : 26)
        }
        // The canvas and the field are both greedy; the band is exactly as tall as its words.
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        }
    }

    private var triggerButton: some View {
        HStack(spacing: 9) {
            EditorialIcon(name: setupReady ? "microphone" : "sliders-horizontal", size: 16)
            Text(setupReady ? primaryActionLabel : LocalizedStringKey("Finish setup"))
                .lineLimit(1)
                .fixedSize()
            if setupReady {
                Text(verbatim: shortcut.label)
                    .font(VoxoLTypography.font(size: 11, weight: .medium, relativeTo: .caption))
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
        .shadow(color: theme.ink.opacity(0.14), radius: 12, y: 8)
        .fixedSize()
        .layoutPriority(1)
        .editorialDictationTrigger(setupReady: setupReady, openSetup: openSetup)
        .help(setupReady ? Text(primaryActionLabel) : Text("Open guided setup"))
        .accessibilityLabel(setupReady ? Text(primaryActionLabel) : Text("Finish setup"))
    }

    /// The live state lives here and nowhere else: it used to be repeated in the window bar,
    /// which said the same thing twice in two different wordings.
    @ViewBuilder
    private var statusChip: some View {
        if setupReady {
            EditorialStatusChip(title: runtime.title, tone: runtime.tone(theme))
                .help(Text(runtime.help ?? runtime.title))
        } else {
            Button(action: openSetup) {
                EditorialStatusChip(title: "Setup required", tone: theme.warning)
            }
            .buttonStyle(SignalPressButtonStyle())
            .help("Open guided setup")
        }
    }

    /// The history, grouped by day, as the substance of the page rather than a footnote.
    private func historyFeed(metrics: EditorialMetrics) -> some View {
        let days = displayedDays
        return VStack(alignment: .leading, spacing: 0) {
            historyHeader(metrics: metrics)

            if let issue = transcripts.historyIssue {
                historyRecoveryNotice(issue)
                    .padding(.top, 12)
            }
            if privateMode || !historyEnabled {
                Label(
                    privateMode
                        ? LocalizedStringKey("Private mode is on · new dictations are not saved")
                        : LocalizedStringKey("History is paused · new dictations are not saved"),
                    systemImage: privateMode ? "lock" : "pause.circle"
                )
                .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                .foregroundStyle(theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .help("Existing history stays on this Mac. Change this in Settings → Privacy.")
                .padding(.top, 12)
            }

            if transcripts.isLoading && transcripts.records.isEmpty {
                ProgressView("Loading history…")
                    .controlSize(.small)
                    .padding(.top, 18)
            } else if transcripts.records.isEmpty && transcripts.historyIssue != nil {
                EmptyView()
            } else if transcripts.records.isEmpty && (privateMode || !historyEnabled) {
                Text("Existing history stays on this Mac. Change this in Settings → Privacy.")
                    .font(VoxoLTypography.font(size: metrics.bodySize, relativeTo: .body))
                    .foregroundStyle(theme.secondaryInk)
                    .padding(.top, 12)
            } else if transcripts.records.isEmpty {
                Text("Your next local result will appear here.")
                    .font(VoxoLTypography.font(size: metrics.bodySize, relativeTo: .body))
                    .foregroundStyle(theme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)
            } else if days.isEmpty {
                Text(LocalizedStringKey("No dictation matches “\(query)”."))
                    .font(VoxoLTypography.font(size: metrics.bodySize, relativeTo: .body))
                    .foregroundStyle(theme.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days) { group in
                            Section {
                                LazyVStack(spacing: 0) {
                                    ForEach(group.records) { record in
                                        EditorialHistoryRow(
                                            record: record,
                                            compact: metrics.compact,
                                            isLastOfDay: record.id == group.lastID
                                        ) { inspectedRecord = $0 }
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
                .padding(.top, 6)
            }
        }
    }

    /// The label of the feed and, beside it, the way through a long history.
    private func historyHeader(metrics: EditorialMetrics) -> some View {
        HStack(alignment: .center, spacing: 12) {
            editorialEyebrow("History")
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryInk)
                TextField("Search dictations", text: $query)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                    .foregroundStyle(theme.ink)
                    .focused($searchFocused)
                    .accessibilityIdentifier("voxol.history.search")
                    .onExitCommand {
                        if query.isEmpty { searchFocused = false } else { query = "" }
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear search"))
                }
            }
            .padding(.horizontal, 10)
            .frame(width: metrics.compact ? 180 : 220, height: 30)
            .background(theme.selection)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(searchFocused ? theme.cobalt : .clear, lineWidth: 1.5)
            }
            .help("Search dictations · ⌘F")
        }
    }

    /// Reuse the grouped history; runtime and hover redraws never repeat a text search.
    private func rebuildSearchResults() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            displayedDays = snapshot.days
            return
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        displayedDays = snapshot.days.compactMap { group in
            let matches = group.records.filter {
                $0.text.range(of: needle, options: options) != nil
                    || $0.applicationName.range(of: needle, options: options) != nil
            }
            return matches.isEmpty
                ? nil : EditorialHistoryDay(day: group.day, title: group.title, records: matches)
        }
    }

    private func historyRecoveryNotice(_ issue: TranscriptHistoryIssue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    issue == .loadFailed
                        ? "History could not be loaded" : "History could not be saved"
                )
                .font(VoxoLTypography.font(size: 13, weight: .semibold, relativeTo: .body))
                .foregroundStyle(theme.ink)
                Text(
                    issue == .loadFailed
                        ? "Your existing archive has not been replaced. Keep VoxoL open and retry to save any new results."
                        : "Recent changes are not saved. Keep VoxoL open and retry."
                )
                .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                .foregroundStyle(theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 8) {
                Button("Retry") { Task { await transcripts.retryHistory() } }
                    .buttonStyle(EditorialSettingsButtonStyle())
                    .disabled(transcripts.isLoading)
                    .accessibilityIdentifier("voxol.history.retry")
                if !transcripts.records.isEmpty {
                    Button("Export recovery copy") {
                        Task { await transcripts.chooseRecoveryDestination() }
                    }
                    .buttonStyle(EditorialSettingsButtonStyle())
                    .help(
                        "Saves a separate JSON copy so you can quit safely. Your existing archive is unchanged."
                    )
                }
            }
        }
        .padding(14)
        .background(theme.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(theme.warning.opacity(0.25), lineWidth: 1)
        }
    }

    /// The same numbers as the column, on one line, for windows too narrow to carry a column.
    private func statsRow(metrics: EditorialMetrics) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            statTile(value: snapshot.totalWords.formatted(), label: "total words")
            statTile(value: snapshot.averageWordsPerMinute.formatted(), label: "wpm")
            statTile(value: todayRecovered, label: "recovered")
                .help("Estimate based on typing at 40 words per minute, before review time.")
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
            editorialEyebrow("Activity")
            Text("Last 7 days")
                .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
                .padding(.top, 8)
            EditorialGrainBars(values: snapshot.weekBars, labels: snapshot.weekLabels)
                .frame(height: 78)
                .padding(.top, 10)
            EditorialRule().padding(.vertical, 14)
            statTile(value: snapshot.totalWords.formatted(), label: "total words")
            EditorialRule().padding(.vertical, 14)
            statTile(value: snapshot.averageWordsPerMinute.formatted(), label: "wpm")
            EditorialRule().padding(.vertical, 14)
            statTile(value: todayRecovered, label: "recovered")
            Text("Estimated at 40 typed words/min")
                .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .help("Estimate based on typing at 40 words per minute, before review time.")

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
        transcripts.usesExampleData
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
        String(localized: "\(snapshot.todayRecoveredMinutes) min")
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

    private var runtime: EditorialRuntimePresentation {
        EditorialRuntimePresentation(dictationSession)
    }

    /// The promise of the page, in the runtime's own words.
    private var stageHeadline: LocalizedStringKey {
        guard setupReady else { return "Finish setup, then speak." }
        switch dictationSession.state {
        case .listening, .speechDetected: return "Listening. Speak naturally."
        case .transcribing, .polishing, .inserting: return "Preparing your text."
        default: return "Speak. Your text is ready."
        }
    }

    private var stageInstruction: LocalizedStringKey {
        guard setupReady else { return "VoxoL needs a few permissions and its local models." }
        switch dictationSession.state {
        case .listening, .speechDetected:
            return activationMode == .hold
                ? "Release the shortcut when you are done."
                : "Press the shortcut again to finish."
        case .transcribing, .polishing, .inserting:
            return "Nothing leaves this Mac."
        default:
            return dictationInstruction
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
}

/// One dictation in the feed. Its hover lives here, so pointing at a row redraws the row and
/// not the page around it.
private struct EditorialHistoryRow: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts

    let record: TranscriptRecord
    let compact: Bool
    let isLastOfDay: Bool
    let inspect: (TranscriptRecord) -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(record.createdAt, format: .dateTime.hour().minute())
                .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
                .monospacedDigit()
                .frame(width: 52, alignment: .leading)
                .padding(.top, 2)

            Text(verbatim: record.text)
                .font(VoxoLTypography.font(size: compact ? 13.5 : 14.5, relativeTo: .body))
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
                        inspect(record)
                    }
                } else {
                    HStack(spacing: 6) {
                        if let icon = ApplicationIconCache.icon(
                            forBundleIdentifier: record.applicationBundleIdentifier)
                        {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 14, height: 14)
                        }
                        Text(verbatim: record.applicationName)
                            .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                            .foregroundStyle(theme.secondaryInk)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: compact ? 96 : 108, alignment: .trailing)
        }
        .padding(.horizontal, compact ? 14 : 18)
        .padding(.vertical, compact ? 12 : 14)
        .background {
            // Only the tint animates. Animating the text's line count re-laid out every row
            // below it on every hover, which is most of what made the feed feel slow.
            Rectangle()
                .fill(hovered ? theme.selection.opacity(0.45) : Color.clear)
                .animation(EditorialMotion.soft, value: hovered)
        }
        .contentShape(Rectangle())
        .onTapGesture { transcripts.copy(record) }
        .onHover { hovered = $0 }
        .overlay(alignment: .bottom) {
            if !isLastOfDay {
                EditorialRule().padding(.leading, compact ? 14 : 18)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Copy transcription")) { transcripts.copy(record) }
        .accessibilityAction(named: Text("Result detail")) { inspect(record) }
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

    var eyebrow: LocalizedStringKey {
        switch self {
        case .week: "This week"
        case .month: "Last 30 days"
        case .all: "All time"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .week: "Seven days of dictation, measured only on this Mac."
        case .month: "Thirty days of dictation, measured only on this Mac."
        case .all: "Every retained dictation, measured only on this Mac."
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

/// Words per calendar day, oldest first, for the small rhythm charts Today and Insights share.
private enum EditorialActivitySeries {
    static func dailyWords(
        _ entries: [EditorialWordEntry], days: Int, calendar: Calendar
    ) -> [Int] {
        let today = calendar.startOfDay(for: .now)
        var buckets: [Date: Int] = [:]
        for entry in entries {
            buckets[calendar.startOfDay(for: entry.date), default: 0] += entry.words
        }
        return (0..<days).map { offset in
            guard
                let date = calendar.date(byAdding: .day, value: offset - (days - 1), to: today)
            else {
                return 0
            }
            return buckets[date] ?? 0
        }
    }

    /// One-letter weekday labels for the last `days` days, oldest first.
    static func weekdayInitials(days: Int, calendar: Calendar) -> [String] {
        let today = calendar.startOfDay(for: .now)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<days).map { offset in
            guard
                let date = calendar.date(byAdding: .day, value: offset - (days - 1), to: today)
            else {
                return ""
            }
            return symbols[calendar.component(.weekday, from: date) - 1].uppercased()
        }
    }

    static func normalized(_ counts: [Int]) -> [CGFloat] {
        let maximum = max(1, counts.max() ?? 1)
        return counts.map { CGFloat($0) / CGFloat(maximum) }
    }

    /// The prototype's week, so an empty history still shows what the chart will look like.
    static let fixtureWeek: [CGFloat] = [0.42, 0.74, 0.58, 0.84, 0.68, 0.92, 0.76]

    static func fixture(count: Int) -> [CGFloat] {
        (0..<count).map { CGFloat(0.3 + 0.65 * abs(sin(Double($0) * 1.7 + 0.4))) }
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
            if value > 0 {
                let fraction = min(1, Double(value) / ceiling)
                var filled = Path()
                filled.addArc(
                    center: centre, radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(180 + 180 * fraction),
                    clockwise: false)
                context.stroke(
                    filled, with: .color(theme.cobalt),
                    style: StrokeStyle(lineWidth: width, lineCap: .round))
            }

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

                    for (index, value) in values.enumerated() where value > 0 {
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
                            .lineLimit(1)
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

/// Hours of the day against days of the week: where in the week the voice actually gets used.
private struct EditorialHeatmap: View {
    @Environment(VoxoLTheme.self) private var theme

    /// Rows of normalized 0…1 values, one row per hour band, one column per weekday.
    let rows: [[Double]]
    let rowLabels: [String]
    let columnLabels: [String]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 3) {
                    Text(verbatim: rowLabels[row])
                        .font(VoxoLTypography.font(size: 10, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 40, alignment: .trailing)
                        .padding(.trailing, 4)
                    ForEach(rows[row].indices, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tone(rows[row][column]))
                            .frame(maxWidth: .infinity)
                            .frame(height: 15)
                    }
                }
            }

            HStack(spacing: 3) {
                Color.clear.frame(width: 40, height: 1).padding(.trailing, 4)
                ForEach(columnLabels.indices, id: \.self) { column in
                    Text(verbatim: columnLabels[column])
                        .font(VoxoLTypography.font(size: 10, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 3)
        }
        .accessibilityHidden(true)
    }

    private func tone(_ value: Double) -> Color {
        guard value > 0 else { return theme.selection.opacity(0.7) }
        return theme.cobalt.opacity(0.14 + 0.86 * min(1, value))
    }
}

/// A signed percentage against the previous period, in the colour of its direction.
private struct EditorialTrendChip: View {
    @Environment(VoxoLTheme.self) private var theme

    let percent: Int

    var body: some View {
        Text(verbatim: (percent >= 0 ? "+" : "−") + abs(percent).formatted() + " %")
            .font(VoxoLTypography.font(size: 10.5, weight: .semibold, relativeTo: .caption))
            .monospacedDigit()
            .foregroundStyle(percent >= 0 ? theme.success : theme.warning)
            .padding(.horizontal, 9)
            .frame(minHeight: 24)
            .background((percent >= 0 ? theme.success : theme.warning).opacity(0.09))
            .clipShape(Capsule())
    }
}

/// Every number the Insights page shows, computed once per period instead of once per card.
///
/// The prototype fixture is honoured the way the rest of the Hub honours it: with no history, the
/// page shows the design's numbers so the layout can be judged. Charts get a deterministic pattern
/// for the same reason; the log, which would have to invent dictations, stays honest and empty.
private struct EditorialInsightsModel {
    let words: Int
    let sessions: Int
    let averageWPM: Int
    let wordsPerSession: Double
    let appCount: Int
    let recoveredMinutes: Int
    let correctedResults: Int
    let correctedWords: Int
    /// Words against the previous period of the same length. Nil when there is nothing to compare.
    let trendPercent: Int?
    let bars: [CGFloat]
    let barLabels: [String]
    /// The busiest day of the period, named for the rhythm headline.
    let busiestDay: String?
    let heat: [[Double]]
    let heatRowLabels: [String]
    let heatColumnLabels: [String]
    /// The busiest weekday and hour band, for the heatmap headline.
    let busiestSlot: (day: String, hour: String)?
    let apps: [EditorialAppShare]
    let activeDays: Int
    let spanDays: Int
    let longestRun: Int
    let calendarDays: [(date: Date, count: Int)]
    let log: [TranscriptRecord]

    @MainActor
    init(
        records: [TranscriptRecord],
        period: EditorialInsightPeriod,
        usesFixture: Bool,
        locale: Locale,
        theme: VoxoLTheme
    ) {
        var calendar = Calendar.current
        calendar.locale = locale
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let start = period.days.flatMap { calendar.date(byAdding: .day, value: -$0, to: now) }
        let filtered = start.map { start in records.filter { $0.createdAt >= start } } ?? records

        // Word counts split the text; done once here and reused by every chart below.
        let allEntries = records.map(EditorialWordEntry.init)
        let entries = start.map { start in allEntries.filter { $0.date >= start } } ?? allEntries
        let totalWords = entries.reduce(0) { $0 + $1.words }
        let speaking = entries.reduce(0) { $0 + $1.seconds }
        words = usesFixture ? 883 : totalWords
        sessions = usesFixture ? 55 : filtered.count
        averageWPM =
            usesFixture
            ? 149 : speaking > 0 ? Int((Double(totalWords) / speaking * 60).rounded()) : 0
        wordsPerSession =
            usesFixture
            ? 11.4
            : filtered.isEmpty ? 0 : Double(totalWords) / Double(filtered.count)
        appCount = usesFixture ? 4 : Set(filtered.map(\.applicationName)).count
        let speakingSeconds = usesFixture ? 55 * 6.4 : speaking
        recoveredMinutes =
            usesFixture
            ? 8 : max(0, Int(((Double(words) / 40 * 60 - speakingSeconds) / 60).rounded()))

        // Results the model actually rewrote, and how many words changed in them.
        if usesFixture {
            correctedResults = 307
            correctedWords = 846
        } else {
            var results = 0
            var changed = 0
            for record in filtered {
                guard let raw = record.revisions.first?.text,
                    let tokens = TranscriptDiff.tokens(raw: raw, final: record.text)
                else {
                    continue
                }
                results += 1
                changed += tokens.filter { $0.change != .unchanged }.count
            }
            correctedResults = results
            correctedWords = changed
        }

        if usesFixture {
            trendPercent = period == .all ? nil : 18
        } else if let days = period.days, let start,
            let previousStart = calendar.date(byAdding: .day, value: -days, to: start)
        {
            let previous =
                allEntries
                .filter { $0.date >= previousStart && $0.date < start }
                .reduce(0) { $0 + $1.words }
            trendPercent =
                previous > 0
                ? Int((Double(words - previous) / Double(previous) * 100).rounded()) : nil
        } else {
            trendPercent = nil
        }

        // Rhythm: one column per day for a week or a month, one per week beyond that.
        switch period {
        case .week, .month:
            let days = period.days ?? 7
            let counts = EditorialActivitySeries.dailyWords(entries, days: days, calendar: calendar)
            bars =
                usesFixture
                ? (period == .week
                    ? EditorialActivitySeries.fixtureWeek
                    : EditorialActivitySeries.fixture(count: days))
                : EditorialActivitySeries.normalized(counts)
            if period == .week {
                barLabels = EditorialActivitySeries.weekdayInitials(days: days, calendar: calendar)
            } else {
                barLabels = (0..<days).map { offset in
                    guard offset % 5 == (days - 1) % 5,
                        let date = calendar.date(
                            byAdding: .day, value: offset - (days - 1), to: today)
                    else {
                        return ""
                    }
                    return calendar.component(.day, from: date).formatted()
                }
            }
            let busiest = counts.indices.max { counts[$0] < counts[$1] }
            if usesFixture, let date = calendar.date(byAdding: .day, value: -1, to: today) {
                busiestDay = Self.dayName(date, weekdayOnly: period == .week, locale: locale)
            } else if let busiest, counts[busiest] > 0,
                let date = calendar.date(byAdding: .day, value: busiest - (days - 1), to: today)
            {
                busiestDay = Self.dayName(date, weekdayOnly: period == .week, locale: locale)
            } else {
                busiestDay = nil
            }
        case .all:
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            let earliest = records.map(\.createdAt).min() ?? today
            let span =
                calendar.dateComponents([.weekOfYear], from: earliest, to: thisWeek).weekOfYear
                ?? 0
            let weeks = usesFixture ? 12 : min(12, max(4, span + 1))
            let counts = (0..<weeks).map { offset -> Int in
                guard
                    let weekStart = calendar.date(
                        byAdding: .weekOfYear, value: offset - (weeks - 1), to: thisWeek),
                    let interval = calendar.dateInterval(of: .weekOfYear, for: weekStart)
                else {
                    return 0
                }
                return
                    allEntries
                    .filter { interval.contains($0.date) }
                    .reduce(0) { $0 + $1.words }
            }
            bars =
                usesFixture
                ? EditorialActivitySeries.fixture(count: weeks)
                : EditorialActivitySeries.normalized(counts)
            barLabels = (0..<weeks).map { offset in
                guard offset % 3 == (weeks - 1) % 3,
                    let weekStart = calendar.date(
                        byAdding: .weekOfYear, value: offset - (weeks - 1), to: thisWeek)
                else {
                    return ""
                }
                return weekStart.formatted(.dateTime.day().month(.abbreviated).locale(locale))
            }
            let busiest = counts.indices.max { counts[$0] < counts[$1] }
            if usesFixture, let date = calendar.date(byAdding: .day, value: -1, to: today) {
                busiestDay = Self.dayName(date, weekdayOnly: false, locale: locale)
            } else if let busiest, counts[busiest] > 0,
                let weekStart = calendar.date(
                    byAdding: .weekOfYear, value: busiest - (weeks - 1), to: thisWeek)
            {
                busiestDay = String(
                    localized:
                        "the week of \(Self.dayName(weekStart, weekdayOnly: false, locale: locale))"
                )
            } else {
                busiestDay = nil
            }
        }

        // When: two-hour bands across the day, the night folded into one row.
        let bands: [(start: Int, end: Int)] = [
            (6, 8), (8, 10), (10, 12), (12, 14), (14, 16), (16, 18), (18, 20), (20, 22), (22, 6),
        ]
        var grid = Array(repeating: Array(repeating: 0.0, count: 7), count: bands.count)
        if usesFixture {
            for row in bands.indices {
                for column in 0..<7 {
                    let shape = sin(Double(row) * 0.72 + 0.5) * cos(Double(column) * 0.65 - 0.3)
                    grid[row][column] = max(0, shape) * (column >= 5 ? 0.35 : 1)
                }
            }
        } else {
            for entry in entries {
                let hour = calendar.component(.hour, from: entry.date)
                let row =
                    bands.firstIndex { hour >= $0.start && hour < $0.end } ?? (bands.count - 1)
                let column =
                    (calendar.component(.weekday, from: entry.date) - calendar.firstWeekday + 7)
                    % 7
                grid[row][column] += Double(entry.words)
            }
        }
        let peak = grid.flatMap { $0 }.max() ?? 0
        heat = peak > 0 ? grid.map { $0.map { $0 / peak } } : grid
        heatRowLabels = bands.map { band in
            guard
                let date = calendar.date(bySettingHour: band.start, minute: 0, second: 0, of: today)
            else {
                return ""
            }
            return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).locale(locale))
        }
        let weekdaySymbols = calendar.veryShortStandaloneWeekdaySymbols
        let weekdayNames = calendar.standaloneWeekdaySymbols
        heatColumnLabels = (0..<7).map {
            weekdaySymbols[($0 + calendar.firstWeekday - 1) % 7].uppercased()
        }
        var slot: (day: String, hour: String)?
        var slotValue = 0.0
        for row in heat.indices {
            for column in heat[row].indices where heat[row][column] > slotValue {
                slotValue = heat[row][column]
                slot = (
                    day: weekdayNames[(column + calendar.firstWeekday - 1) % 7],
                    hour: heatRowLabels[row]
                )
            }
        }
        busiestSlot = slot

        // Apps.
        if usesFixture {
            apps = [
                EditorialAppShare(id: "Notes", name: "Notes", share: 41, tone: theme.cobalt),
                EditorialAppShare(
                    id: "Mail", name: "Mail", share: 28, tone: theme.cobalt.opacity(0.76)),
                EditorialAppShare(
                    id: "Cursor", name: "Cursor", share: 19, tone: theme.cobalt.opacity(0.5)),
                EditorialAppShare(
                    id: "Other", name: String(localized: "Other"), share: 12, tone: theme.coral),
            ]
        } else {
            let grouped = Dictionary(grouping: filtered, by: \.applicationName)
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
            let total = max(1, filtered.count)
            let top = Array(grouped.prefix(3))
            // Any record for an application carries the same bundle identifier, so the first one
            // found is enough to resolve the icon macOS has for it.
            let bundleIdentifiers = Dictionary(
                filtered.compactMap { record in
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
                    icon: ApplicationIconCache.icon(
                        forBundleIdentifier: bundleIdentifiers[item.key])
                )
            }
            // "Other" only earns a row when something is actually in it, and empty placeholder
            // rows are not padding worth showing: a short honest list beats a padded one.
            let topCount = top.reduce(0) { $0 + $1.value }
            // The denominator is clamped only to avoid division by zero. It must
            // not count as a dictation in an otherwise empty history.
            let otherShare = Int(
                (Double(filtered.count - topCount) / Double(total) * 100).rounded())
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
            apps = Array(result.prefix(4))
        }

        // Regularity: the 13-week calendar, plus how much of the period saw any dictation.
        let dayCounts = Dictionary(grouping: records) { calendar.startOfDay(for: $0.createdAt) }
            .mapValues(\.count)
        calendarDays = (0..<91).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            if usesFixture {
                let seed = (offset * 37 + 11) % 10
                return (date: date, count: seed < 3 ? 0 : seed - 2)
            }
            return (date: date, count: dayCounts[date] ?? 0)
        }
        var best = 0
        var running = 0
        for day in calendarDays {
            if day.count > 0 {
                running += 1
                best = max(best, running)
            } else {
                running = 0
            }
        }
        longestRun = best
        if usesFixture {
            switch period {
            case .week:
                activeDays = 5
                spanDays = 7
            case .month:
                activeDays = 19
                spanDays = 30
            case .all:
                activeDays = 64
                spanDays = 91
            }
        } else {
            activeDays = Set(filtered.map { calendar.startOfDay(for: $0.createdAt) }).count
            if let days = period.days {
                spanDays = days
            } else if let earliest = records.map(\.createdAt).min() {
                let elapsed =
                    calendar.dateComponents(
                        [.day], from: calendar.startOfDay(for: earliest), to: today
                    ).day ?? 0
                spanDays = max(1, elapsed + 1)
            } else {
                spanDays = 1
            }
        }

        log = Array(filtered.prefix(8))
    }

    private static func dayName(_ date: Date, weekdayOnly: Bool, locale: Locale) -> String {
        weekdayOnly
            ? date.formatted(.dateTime.weekday(.wide).locale(locale))
            : date.formatted(.dateTime.day().month(.wide).locale(locale))
    }
}

struct EditorialInsightsView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var period = EditorialInsightPeriod.week
    @State private var visible = false
    @State private var inspectedRecord: TranscriptRecord?
    /// Built when the period or the history changes, never on a redraw: the word diff behind
    /// the corrections card is the most expensive computation in the Hub.
    @State private var model: EditorialInsightsModel?

    var body: some View {
        GeometryReader { geometry in
            let metrics = EditorialMetrics(geometry.size)
            let model =
                self.model
                ?? EditorialInsightsModel(
                    records: [], period: period, usesFixture: false, locale: locale, theme: theme)
            let gap: CGFloat = metrics.compact ? 12 : 16

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    EditorialPageHeader(
                        metrics: metrics,
                        eyebrow: "Insights",
                        title: "Your voice at a glance.",
                        summary: period.summary
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

                    heroBand(model, metrics: metrics)
                        .editorialStagger(1, visible: visible)

                    cardRow(metrics: metrics, gap: gap) {
                        rhythmCard(model, metrics: metrics)
                        heatmapCard(model, metrics: metrics)
                    }
                    .padding(.top, gap)
                    .editorialStagger(2, visible: visible)

                    cardRow(metrics: metrics, gap: gap) {
                        appsCard(model, metrics: metrics)
                        fixesCard(model, metrics: metrics)
                        regularityCard(model, metrics: metrics)
                    }
                    .padding(.top, gap)
                    .editorialStagger(3, visible: visible)

                    logCard(model, metrics: metrics)
                        .padding(.top, gap)
                        .editorialStagger(4, visible: visible)
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
        .onChange(of: period, initial: true) { _, _ in rebuildModel() }
        .onChange(of: transcripts.records) { _, _ in rebuildModel() }
        .onChange(of: transcripts.usesExampleData) { _, _ in rebuildModel() }
        .onChange(of: locale) { _, _ in rebuildModel() }
        .sheet(item: $inspectedRecord) { record in
            TranscriptDetailSheet(record: record, store: transcripts)
                .environment(theme)
        }
    }

    private func rebuildModel() {
        model = EditorialInsightsModel(
            records: transcripts.records,
            period: period,
            usesFixture: usesPrototypeFixture,
            locale: locale,
            theme: theme
        )
    }

    // MARK: Hero

    /// The one sentence the page exists for, with the signal behind it and three numbers beside.
    private func heroBand(_ model: EditorialInsightsModel, metrics: EditorialMetrics) -> some View {
        let layout =
            metrics.compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 28))

        return ZStack(alignment: .leading) {
            theme.canvas

            HubDitherField(mode: .insights, cadence: .still)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: metrics.compact ? 0.05 : 0.32),
                            .init(color: .black, location: metrics.compact ? 0.55 : 0.72),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }

            layout {
                VStack(alignment: .leading, spacing: 0) {
                    eyebrow(period.eyebrow)
                    Text(LocalizedStringKey("\(model.recoveredMinutes) minutes saved, estimated."))
                        .font(
                            VoxoLTypography.font(
                                size: metrics.compact ? 24 : 30, weight: .semibold,
                                relativeTo: .largeTitle)
                        )
                        .foregroundStyle(theme.ink)
                        .tracking(-0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.top, 8)
                    Text(
                        LocalizedStringKey(
                            "\(model.words) words prepared in \(model.sessions) dictations, without leaving your apps."
                        )
                    )
                    .font(VoxoLTypography.font(size: metrics.bodySize, relativeTo: .body))
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .help("Estimate based on typing at 40 words per minute, before review time.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    heroTile(value: model.averageWPM.formatted(), label: "words / min") {
                        EditorialPaceGauge(value: model.averageWPM)
                            .frame(width: 40, height: 22)
                    }
                    heroTile(
                        value: model.wordsPerSession.formatted(
                            .number.precision(.fractionLength(1))),
                        label: "words / dictation"
                    ) {
                        EmptyView()
                    }
                    heroTile(value: model.appCount.formatted(), label: "apps used") {
                        EmptyView()
                    }
                }
            }
            .padding(metrics.compact ? 22 : 30)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        }
    }

    private func heroTile<Accessory: View>(
        value: String,
        label: LocalizedStringKey,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: value)
                    .font(VoxoLTypography.font(size: 26, weight: .semibold, relativeTo: .title))
                    .foregroundStyle(theme.ink)
                    .monospacedDigit()
                    .tracking(-0.8)
                    .lineLimit(1)
                Text(label)
                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
                    .fixedSize()
            }
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minWidth: 118, alignment: .leading)
        .background(theme.raisedSurface.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.line.opacity(0.8), lineWidth: 1)
        }
        .shadow(color: theme.ink.opacity(0.06), radius: 14, y: 6)
    }

    // MARK: Cards

    /// Cards side by side when the window allows, stacked when it does not. Side by side, every
    /// card takes the row's full height so their bottoms line up.
    private func cardRow<Content: View>(
        metrics: EditorialMetrics,
        gap: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            if metrics.compact {
                VStack(alignment: .leading, spacing: gap) { content() }
            } else {
                HStack(alignment: .top, spacing: gap) { content() }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func insightCard<Content: View, Trailing: View>(
        metrics: EditorialMetrics,
        title: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                eyebrow(title)
                Spacer(minLength: 8)
                trailing()
            }
            .frame(minHeight: 24)

            content()
                .padding(.top, 10)
        }
        .padding(metrics.compact ? 16 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.raisedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.line, lineWidth: 1)
        )
    }

    private func insightCard<Content: View>(
        metrics: EditorialMetrics,
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        insightCard(metrics: metrics, title: title, trailing: { EmptyView() }, content: content)
    }

    private func rhythmCard(_ model: EditorialInsightsModel, metrics: EditorialMetrics) -> some View
    {
        insightCard(metrics: metrics, title: "Rhythm") {
            if let trend = model.trendPercent {
                EditorialTrendChip(percent: trend)
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                headline(
                    model.busiestDay.map { LocalizedStringKey("Busiest on \($0).") }
                        ?? "Nothing dictated yet."
                )
                EditorialGrainBars(values: model.bars, labels: model.barLabels)
                    .frame(height: metrics.compact ? 104 : 124)
                    .padding(.top, 14)
            }
        }
    }

    private func heatmapCard(_ model: EditorialInsightsModel, metrics: EditorialMetrics)
        -> some View
    {
        insightCard(metrics: metrics, title: "When you dictate") {
            VStack(alignment: .leading, spacing: 0) {
                headline(
                    model.busiestSlot.map {
                        LocalizedStringKey("Mostly on \($0.day) around \($0.hour).")
                    } ?? "Nothing dictated yet."
                )
                EditorialHeatmap(
                    rows: model.heat,
                    rowLabels: model.heatRowLabels,
                    columnLabels: model.heatColumnLabels
                )
                .padding(.top, 14)
            }
        }
    }

    private func appsCard(_ model: EditorialInsightsModel, metrics: EditorialMetrics) -> some View {
        insightCard(metrics: metrics, title: "Where you dictate") {
            VStack(alignment: .leading, spacing: 0) {
                headline(appHeadline(model))

                VStack(spacing: metrics.compact ? 10 : 12) {
                    ForEach(model.apps) { item in
                        HStack(spacing: 10) {
                            Group {
                                if let icon = item.icon {
                                    Image(nsImage: icon).resizable().interpolation(.high)
                                } else {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(theme.selection)
                                }
                            }
                            .frame(width: 20, height: 20)

                            Text(verbatim: item.name)
                                .frame(width: metrics.compact ? 64 : 72, alignment: .leading)
                                .lineLimit(1)

                            GeometryReader { geometry in
                                Capsule()
                                    .fill(theme.selection)
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(item.tone)
                                            .frame(
                                                width: geometry.size.width * CGFloat(item.share)
                                                    / 100)
                                    }
                            }
                            .frame(height: 7)

                            Text(verbatim: "\(item.share) %")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                        .foregroundStyle(theme.ink)
                    }

                    if model.apps.isEmpty {
                        Text("Your apps will appear here.")
                            .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                            .foregroundStyle(theme.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    private func fixesCard(_ model: EditorialInsightsModel, metrics: EditorialMetrics) -> some View
    {
        let cleanedShare =
            model.sessions > 0
            ? Int((Double(model.correctedResults) / Double(model.sessions) * 100).rounded()) : 0
        return insightCard(metrics: metrics, title: "Changes to transcripts") {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: model.correctedWords.formatted())
                    .font(
                        VoxoLTypography.font(size: 34, weight: .semibold, relativeTo: .largeTitle)
                    )
                    .foregroundStyle(theme.ink)
                    .monospacedDigit()
                    .tracking(-1.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text("words added or removed from the original")
                    .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .help("Includes your edits. A change is not a validated correction.")

                EditorialRule().padding(.vertical, 12)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: model.correctedResults.formatted())
                        .font(VoxoLTypography.font(size: 16, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(theme.ink)
                        .monospacedDigit()
                    Text("results changed")
                        .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                }

                GeometryReader { geometry in
                    Capsule()
                        .fill(theme.selection)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(theme.success)
                                .frame(
                                    width: geometry.size.width * CGFloat(min(100, cleanedShare))
                                        / 100)
                        }
                }
                .frame(height: 7)
                .padding(.top, 10)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: "\(cleanedShare) %")
                        .font(
                            VoxoLTypography.font(
                                size: 11.5, weight: .semibold, relativeTo: .caption)
                        )
                        .foregroundStyle(theme.ink)
                        .monospacedDigit()
                    Text("of dictations cleaned up")
                        .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                }
                .padding(.top, 6)
            }
        }
    }

    private func regularityCard(_ model: EditorialInsightsModel, metrics: EditorialMetrics)
        -> some View
    {
        insightCard(metrics: metrics, title: "Regularity") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(verbatim: model.activeDays.formatted())
                        .font(
                            VoxoLTypography.font(size: 22, weight: .semibold, relativeTo: .title2)
                        )
                        .foregroundStyle(theme.ink)
                        .monospacedDigit()
                    Text(LocalizedStringKey("active days of \(model.spanDays)"))
                        .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(LocalizedStringKey("Longest run \(model.longestRun)"))
                        .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                        .lineLimit(1)
                }

                EditorialStreakCalendar(days: model.calendarDays)
                    .padding(.top, 14)
            }
        }
    }

    // MARK: Log

    /// The period's dictations as numbers rather than prose: what Today shows as text, read here as
    /// pace, length and how much VoxoL had to change.
    private func logCard(_ model: EditorialInsightsModel, metrics: EditorialMetrics) -> some View {
        let remaining = max(0, model.sessions - model.log.count)
        return insightCard(metrics: metrics, title: "Dictation log") {
            if !model.log.isEmpty, !usesPrototypeFixture {
                Text(LocalizedStringKey("\(model.sessions) dictations"))
                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if model.log.isEmpty {
                    Text("Your dictations will appear here.")
                        .font(VoxoLTypography.font(size: metrics.bodySize, relativeTo: .body))
                        .foregroundStyle(theme.secondaryInk)
                        .padding(.top, 4)
                } else {
                    logHeader(metrics: metrics)
                    EditorialRule().padding(.top, 8)
                    ForEach(model.log) { record in
                        logRow(record, metrics: metrics)
                        if record.id != model.log.last?.id {
                            EditorialRule()
                        }
                    }
                    if remaining > 0, !usesPrototypeFixture {
                        Text(LocalizedStringKey("And \(remaining) more in Today."))
                            .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                            .foregroundStyle(theme.secondaryInk)
                            .padding(.top, 12)
                    }
                }
            }
        }
    }

    private func logHeader(metrics: EditorialMetrics) -> some View {
        HStack(spacing: 12) {
            columnLabel("Time").frame(width: logTimeWidth(metrics), alignment: .leading)
            columnLabel("App").frame(maxWidth: .infinity, alignment: .leading)
            columnLabel("Words").frame(width: 48, alignment: .trailing)
            if !metrics.compact {
                columnLabel("Duration").frame(width: 56, alignment: .trailing)
                columnLabel("Pace").frame(width: 84, alignment: .trailing)
            }
            columnLabel("Cleanup").frame(width: 92, alignment: .leading)
            Color.clear.frame(width: 26, height: 1)
        }
        .padding(.top, 6)
    }

    private func columnLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(VoxoLTypography.font(size: 10.5, weight: .medium, relativeTo: .caption))
            .foregroundStyle(theme.secondaryInk)
            .lineLimit(1)
    }

    private func logTimeWidth(_ metrics: EditorialMetrics) -> CGFloat {
        metrics.compact ? 96 : 118
    }

    private func logRow(_ record: TranscriptRecord, metrics: EditorialMetrics) -> some View {
        EditorialInsightsLogRow(
            record: record,
            compact: metrics.compact,
            timeWidth: logTimeWidth(metrics)
        ) { inspectedRecord = $0 }
    }

    // MARK: Type

    private func eyebrow(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(VoxoLTypography.font(size: 10.5, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(theme.secondaryInk)
            .textCase(.uppercase)
            .tracking(1)
    }

    private func headline(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(VoxoLTypography.font(size: 15, weight: .semibold, relativeTo: .headline))
            .foregroundStyle(theme.ink)
            .tracking(-0.2)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func appHeadline(_ model: EditorialInsightsModel) -> LocalizedStringKey {
        if usesPrototypeFixture { return "Notes remains your first reflex." }
        guard let first = model.apps.first else { return "Nothing dictated yet." }
        return LocalizedStringKey("\(first.name) is your first reflex.")
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

    private var usesPrototypeFixture: Bool {
        transcripts.usesExampleData
    }
}

/// One line of the dictation log, with its own hover so pointing at it redraws one row.
private struct EditorialInsightsLogRow: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.locale) private var locale

    let record: TranscriptRecord
    let compact: Bool
    let timeWidth: CGFloat
    let inspect: (TranscriptRecord) -> Void

    @State private var hovered = false

    var body: some View {
        let cleaned =
            record.revisions.first.map {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    != record.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? false

        HStack(spacing: 12) {
            Text(
                record.createdAt.formatted(
                    .dateTime.day().month(.abbreviated).hour().minute().locale(locale))
            )
            .foregroundStyle(theme.secondaryInk)
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: timeWidth, alignment: .leading)

            HStack(spacing: 7) {
                Group {
                    if let icon = ApplicationIconCache.icon(
                        forBundleIdentifier: record.applicationBundleIdentifier)
                    {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(theme.selection)
                    }
                }
                .frame(width: 16, height: 16)
                Text(verbatim: record.applicationName)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: record.wordCount.formatted())
                .foregroundStyle(theme.ink)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)

            if !compact {
                Text(
                    verbatim: record.durationSeconds.formatted(
                        .number.precision(.fractionLength(1))) + " s"
                )
                .foregroundStyle(theme.secondaryInk)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)

                Text(LocalizedStringKey("\(record.wordsPerMinute) wpm"))
                    .foregroundStyle(theme.secondaryInk)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 84, alignment: .trailing)
            }

            EditorialStatusChip(
                title: cleaned ? "Cleaned" : "As heard",
                tone: cleaned ? theme.success : theme.secondaryInk,
                filledDot: false
            )
            .frame(width: 92, alignment: .leading)

            EditorialIconButton(
                icon: "text.magnifyingglass",
                label: "Result detail",
                size: 26,
                systemSymbol: true
            ) {
                inspect(record)
            }
            .opacity(hovered ? 1 : 0)
        }
        .font(VoxoLTypography.font(size: 12, relativeTo: .body))
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? theme.selection.opacity(0.45) : Color.clear)
                .animation(EditorialMotion.soft, value: hovered)
        }
        .contentShape(Rectangle())
        .onTapGesture { inspect(record) }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Result detail")) { inspect(record) }
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
    case training

    var title: LocalizedStringKey {
        switch self {
        case .dictionary: "Dictionary"
        case .snippets: "Voice shortcuts"
        case .profiles: "Profiles"
        case .training: "Review recordings"
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
    @State private var showsDictionarySuggestions = false
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
                    title: "Make dictation your own.",
                    summary:
                        "Set exact words, shortcuts and writing style, then review saved recordings."
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        case .training:
            TrainingStudioView()
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
                    detail: "Names and terms VoxoL should spell your way",
                    actionTitle: "Add",
                    action: { presentedSheet = .dictionary(nil) }
                )
                Divider().overlay(theme.line)

                // One correction is not yet a rule — but it is worth showing.
                // The add button supplies the confidence a second occurrence
                // would have; ignore makes the proposal stay dismissed.
                let suggestions = pendingDictionarySuggestions
                if !suggestions.isEmpty {
                    DisclosureGroup(isExpanded: $showsDictionarySuggestions) {
                        VStack(spacing: 0) {
                            Text(
                                "Suggested after one correction. Review each word before adding it."
                            )
                            .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                            .foregroundStyle(theme.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
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
                                Divider().overlay(theme.line)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(theme.cobalt)
                            Text("Suggestions from corrections")
                                .foregroundStyle(theme.ink)
                            Text(suggestions.count.formatted())
                                .foregroundStyle(theme.secondaryInk)
                        }
                        .font(VoxoLTypography.font(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(theme.cobaltSoft.opacity(0.17))
                    .id(suggestionRefresh)
                    Divider().overlay(theme.line)
                }

                if personalization.snapshot.dictionary.isEmpty {
                    emptyLibraryState(
                        title: "No dictionary entries yet",
                        detail: "Add names and terms that VoxoL must write exactly."
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(personalization.snapshot.dictionary) { entry in
                                Button {
                                    presentedSheet = .dictionary(entry)
                                } label: {
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
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Edit this dictionary entry")
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
                    title: "Voice shortcuts",
                    detail: "Say a short phrase to insert text you use often",
                    actionTitle: "Add",
                    action: { presentedSheet = .snippet(nil) }
                )
                Divider().overlay(theme.line)

                if personalization.snapshot.snippets.isEmpty {
                    emptyLibraryState(
                        title: "No snippets yet",
                        detail: "Say a short phrase to insert a longer text you save."
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(personalization.snapshot.snippets) { snippet in
                                Button {
                                    presentedSheet = .snippet(snippet)
                                } label: {
                                    libraryDataRow(
                                        leading: snippet.trigger,
                                        detail: snippet.expansion,
                                        trailing: snippet.isEnabled
                                            ? String(localized: "Active")
                                            : String(localized: "Paused")
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Edit this snippet")
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
                    .font(VoxoLTypography.font(size: 14, weight: .medium, relativeTo: .body))
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
        .frame(minHeight: 64)
    }

    private func libraryDataRow(
        leading: String,
        detail: String,
        trailing: String
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: leading)
                    .font(VoxoLTypography.font(size: 14, weight: .medium, relativeTo: .body))
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
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.secondaryInk)
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 58)
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
                EditorialDropdownOption(
                    id: $0.rawValue, verbatim: String(localized: $0.localizedTitle))
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
                .disabled(UpdateNotifier.shared.isChecking)
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
        let notifier = UpdateNotifier.shared
        if notifier.isChecking { return "Checking…" }
        if let available = notifier.available { return "Update to \(available.version)" }
        if notifier.state.phase == .failed { return "Check failed · Retry" }
        return notifier.state.phase == .current ? "Up to date" : "Check for updates"
    }

    private func checkForUpdate() async {
        if UpdateNotifier.shared.available != nil {
            UpdateNotifier.shared.installAvailableUpdate()
            return
        }
        // Delegated rather than duplicated: this used to run its own copy of
        // the same fetch and comparison, so the row here and the sidebar badge
        // could disagree about whether an update existed. One reader, one
        // answer. `announce: false` keeps the alert out of the way of someone
        // who is already looking at the result.
        await UpdateNotifier.shared.check(announce: false)
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
