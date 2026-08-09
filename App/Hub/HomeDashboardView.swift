import SwiftUI
import PersonalizationKit
import TextProcessingKit

struct SignalTodayView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts
    @Environment(DictationSessionCoordinator.self) private var dictationSession

    let previewCapsule: () -> Void
    let openInsights: () -> Void
    let openSettings: () -> Void

    @AppStorage("voxol.historyEnabled") private var historyEnabled = true
    @State private var inspectedRecord: TranscriptRecord?
    @State private var resultCardIsHovered = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760 || geometry.size.height < 600

            VStack(alignment: .leading, spacing: compact ? 13 : 18) {
                SignalPageHeader(
                    eyebrow: "Today",
                    title: "Ready when you are.",
                    summary:
                        "Speak naturally. VoxoL prepares the text and inserts it into the active app."
                ) {
                    SignalIconButton(
                        symbol: "slider.horizontal.3",
                        help: "Open settings",
                        action: openSettings
                    )
                }

                voiceHero(compact: compact)
                    .frame(height: compact ? 184 : 218)

                HStack(alignment: .top, spacing: compact ? 10 : 14) {
                    recentResult(compact: compact)
                        .frame(maxWidth: .infinity)
                    todayUsage(compact: compact)
                        .frame(width: compact ? 238 : 292)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, compact ? 24 : 34)
            .padding(.vertical, compact ? 21 : 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(item: $inspectedRecord) { record in
            TranscriptDetailSheet(record: record, store: transcripts)
                .environment(theme)
        }
    }

    private func voiceHero(compact: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    theme.selection.opacity(0.64),
                    theme.surface.opacity(0.84),
                    theme.cobaltSoft.opacity(0.2),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: compact ? 8 : 11) {
                    SignalStatusChip(
                        title: runtimeStatus,
                        color: runtimeColor,
                        symbol: runtimeSymbol
                    )

                    Text("Speak. Your text is ready.")
                        .font(
                            VoxoLTypography.font(
                                size: compact ? 22 : 27,
                                weight: .semibold,
                                relativeTo: .title2
                            )
                        )
                        .foregroundStyle(theme.ink)
                        .tracking(-0.45)

                    Text("Hold the shortcut, speak naturally, then release.")
                        .font(
                            VoxoLTypography.font(
                                size: compact ? 12.5 : 14,
                                relativeTo: .body
                            )
                        )
                        .foregroundStyle(theme.secondaryInk)
                        .lineLimit(2)

                    Button(action: previewCapsule) {
                        HStack(spacing: 10) {
                            Image(systemName: "mic.fill")
                            Text("Preview the gesture")
                            Spacer(minLength: 6)
                            Text(verbatim: "⌥ Space")
                                .font(
                                    VoxoLTypography.font(
                                        size: 11.5, weight: .semibold, relativeTo: .caption)
                                )
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(theme.surface.opacity(0.13))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .frame(maxWidth: compact ? 246 : 286)
                    }
                    .buttonStyle(SignalPrimaryButtonStyle())
                }
                .padding(.leading, compact ? 20 : 28)
                .padding(.vertical, compact ? 17 : 22)
                .frame(maxWidth: compact ? 326 : 390, alignment: .leading)

                ZStack {
                    HubDitherField(mode: activeSignalMode)
                    VoxoLMark(size: compact ? 48 : 58)
                        .padding(compact ? 12 : 15)
                        .background(theme.surface.opacity(0.94))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(theme.line.opacity(0.8), lineWidth: 1)
                        }
                        .shadow(color: theme.ink.opacity(0.08), radius: 14, y: 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.line.opacity(0.7), lineWidth: 1)
        }
    }

    private func recentResult(compact: Bool) -> some View {
        SignalCard(padding: compact ? 15 : 19) {
            VStack(alignment: .leading, spacing: compact ? 8 : 11) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        SignalEyebrow(title: "Latest result")
                        if let latest = transcripts.records.first {
                            Text(latest.createdAt, format: .relative(presentation: .named))
                                .font(
                                    VoxoLTypography.font(
                                        size: 15, weight: .semibold, relativeTo: .headline)
                                )
                                .foregroundStyle(theme.ink)
                        } else {
                            Text("No retained result yet")
                                .font(
                                    VoxoLTypography.font(
                                        size: 15, weight: .semibold, relativeTo: .headline)
                                )
                                .foregroundStyle(theme.ink)
                        }
                    }
                    Spacer()
                    if let latest = transcripts.records.first {
                        SignalIconButton(symbol: "doc.on.doc", help: "Copy text") {
                            transcripts.copy(latest)
                        }
                    }
                }

                if let latest = transcripts.records.first {
                    Text(latest.text)
                        .font(
                            VoxoLTypography.font(
                                size: compact ? 13.5 : 15,
                                weight: .medium,
                                relativeTo: .body
                            )
                        )
                        .foregroundStyle(theme.ink)
                        .lineLimit(compact ? 2 : 3)

                    HStack(spacing: 7) {
                        Text(verbatim: latest.applicationName)
                        Text(verbatim: "·")
                        Text(verbatim: formatDuration(latest.durationSeconds))
                        Text(verbatim: "·")
                        // The card's own promise: open it to see what was heard and what was
                        // written, side by side.
                        if latest.revisions.first != nil {
                            Text("See what changed")
                                .foregroundStyle(resultCardIsHovered ? theme.ink : theme.cobalt)
                        } else {
                            Text("Prepared locally")
                        }
                    }
                    .font(VoxoLTypography.font(size: 10.5, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
                } else {
                    Text(
                        historyEnabled
                            ? "Your next successful dictation will appear here."
                            : "Enable local history in Library to retain future results."
                    )
                    .font(VoxoLTypography.font(size: 13, relativeTo: .body))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // A plain tap gesture rather than wrapping the card in a Button: the copy icon lives
        // inside it and a nested button would stop receiving clicks.
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { inspectLatest() }
        .onHover { hovering in
            guard transcripts.records.first != nil else { return }
            withAnimation(.easeOut(duration: 0.14)) { resultCardIsHovered = hovering }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.ink.opacity(resultCardIsHovered ? 0.16 : 0), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("See what changed")) { inspectLatest() }
    }

    private func inspectLatest() {
        guard let latest = transcripts.records.first else { return }
        inspectedRecord = latest
    }

    private func todayUsage(compact: Bool) -> some View {
        SignalCard(padding: compact ? 15 : 19) {
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                SignalEyebrow(title: "Today")
                Text("Your voice has already saved you time.")
                    .font(
                        VoxoLTypography.font(
                            size: compact ? 14 : 16,
                            weight: .semibold,
                            relativeTo: .headline
                        )
                    )
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    SignalMetricTile(value: recoveredTime, label: "recovered")
                    SignalMetricTile(value: todayWords.formatted(), label: "words")
                    SignalMetricTile(value: todayRecords.count.formatted(), label: "dictations")
                }

                Spacer(minLength: 0)
                Button(action: openInsights) {
                    HStack(spacing: 7) {
                        Text("View insights")
                        Image(systemName: "arrow.right")
                    }
                    .font(
                        VoxoLTypography.font(
                            size: 12.5, weight: .semibold, relativeTo: .subheadline)
                    )
                    .foregroundStyle(theme.cobalt)
                    .frame(minHeight: 40)
                }
                .buttonStyle(SignalPressButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var todayRecords: [TranscriptRecord] {
        let start = Calendar.current.startOfDay(for: Date())
        return transcripts.records.filter { $0.createdAt >= start }
    }

    private var todayWords: Int {
        todayRecords.reduce(0) { $0 + $1.wordCount }
    }

    private var recoveredTime: String {
        Self.recoveredTime(for: todayRecords)
    }

    static func recoveredTime(for records: [TranscriptRecord]) -> String {
        let words = records.reduce(0) { $0 + $1.wordCount }
        let speaking = records.reduce(0) { $0 + max(0, $1.durationSeconds) }
        let estimatedTyping = Double(words) / 40 * 60
        let recovered = max(0, estimatedTyping - speaking)
        if recovered < 60 {
            return "\(Int(recovered.rounded()))s"
        }
        return "\(Int((recovered / 60).rounded()))m"
    }

    private var activeSignalMode: HubSignalMode {
        switch dictationSession.state {
        case .listening, .speechDetected:
            .voice
        case .transcribing, .polishing, .inserting:
            .processing
        default:
            .idle
        }
    }

    private var runtimeStatus: LocalizedStringKey {
        switch dictationSession.state {
        case .listening:
            "Listening locally"
        case .speechDetected:
            "Voice detected"
        case .transcribing:
            "Transcribing locally"
        case .polishing:
            "Preparing text"
        case .inserting:
            "Inserting text"
        case .failed, .waitingForInputMonitoring:
            "Setup required"
        default:
            "Ready to listen"
        }
    }

    private var runtimeColor: Color {
        switch dictationSession.state {
        case .listening, .speechDetected:
            theme.coral
        case .transcribing, .polishing, .inserting:
            theme.cobalt
        case .failed, .waitingForInputMonitoring:
            theme.warning
        default:
            theme.success
        }
    }

    private var runtimeSymbol: String? {
        switch dictationSession.state {
        case .listening, .speechDetected:
            "waveform"
        case .transcribing, .polishing, .inserting:
            "ellipsis"
        case .failed, .waitingForInputMonitoring:
            "exclamationmark"
        default:
            nil
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        duration.formatted(.number.precision(.fractionLength(1))) + "s"
    }
}

private enum SignalInsightPeriod: String, CaseIterable, Identifiable {
    case sevenDays
    case thirtyDays
    case all

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .all: "All"
        }
    }

    var dayCount: Int? {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .all: nil
        }
    }
}

struct SignalInsightsView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts

    @State private var period = SignalInsightPeriod.sevenDays

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760 || geometry.size.height < 600

            VStack(alignment: .leading, spacing: compact ? 13 : 18) {
                SignalPageHeader(
                    eyebrow: "Insights",
                    title: "Your voice, at a glance.",
                    summary: insightSummary
                ) {
                    periodPicker
                        .frame(width: compact ? 218 : 252)
                }

                insightHero(compact: compact)
                    .frame(height: compact ? 142 : 170)

                HStack(alignment: .top, spacing: compact ? 10 : 14) {
                    rhythmCard(compact: compact)
                    appUsageCard(compact: compact)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, compact ? 24 : 34)
            .padding(.vertical, compact ? 21 : 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(SignalInsightPeriod.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.large)
    }

    private func insightHero(compact: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    theme.selection.opacity(0.64),
                    theme.surface.opacity(0.9),
                    theme.cobaltSoft.opacity(0.28),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            HubDitherField(mode: .insights)
                .opacity(0.72)

            HStack(spacing: compact ? 12 : 18) {
                VStack(alignment: .leading, spacing: 5) {
                    SignalEyebrow(title: periodEyebrow)
                    Text(recoveredTime)
                        .font(
                            VoxoLTypography.font(
                                size: compact ? 22 : 27,
                                weight: .semibold,
                                relativeTo: .title2
                            )
                        )
                        .foregroundStyle(theme.ink)
                        .monospacedDigit()
                    HStack(spacing: 4) {
                        Text(verbatim: filteredWords.formatted())
                        Text("words prepared in")
                        Text(verbatim: filteredRecords.count.formatted())
                        Text("dictations")
                    }
                    .font(
                        VoxoLTypography.font(
                            size: compact ? 10.5 : 12,
                            relativeTo: .caption
                        )
                    )
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: compact ? 7 : 10) {
                    heroMetric(
                        value: averageWPM.formatted(),
                        label: "words / min",
                        compact: compact
                    )
                    heroMetric(
                        value: averageWordsPerSession.formatted(
                            .number.precision(.fractionLength(1))
                        ),
                        label: "words / dictation",
                        compact: compact
                    )
                    heroMetric(
                        value: uniqueApps.formatted(),
                        label: "apps used",
                        compact: compact
                    )
                }
                .frame(maxWidth: compact ? 298 : 382)
            }
            .padding(compact ? 16 : 20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.line.opacity(0.7), lineWidth: 1)
        }
    }

    private func heroMetric(
        value: String,
        label: LocalizedStringKey,
        compact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(
                    VoxoLTypography.font(
                        size: compact ? 20 : 24,
                        weight: .semibold,
                        relativeTo: .title3
                    )
                )
                .foregroundStyle(theme.ink)
                .monospacedDigit()
            Text(label)
                .font(
                    VoxoLTypography.font(
                        size: compact ? 9.5 : 10.5,
                        relativeTo: .caption
                    )
                )
                .foregroundStyle(theme.secondaryInk)
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 10 : 13)
        .frame(maxWidth: .infinity, maxHeight: compact ? 76 : 90, alignment: .leading)
        .background(theme.surface.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.line.opacity(0.8), lineWidth: 1)
        }
    }

    private func rhythmCard(compact: Bool) -> some View {
        SignalCard(padding: compact ? 15 : 18) {
            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        SignalEyebrow(title: "Rhythm")
                        Text(
                            filteredRecords.isEmpty
                                ? "Your rhythm will appear here." : "Your local rhythm."
                        )
                        .font(
                            VoxoLTypography.font(
                                size: compact ? 14.5 : 17,
                                weight: .semibold,
                                relativeTo: .headline
                            )
                        )
                        .foregroundStyle(theme.ink)
                    }
                    Spacer()
                    if transcripts.usesExampleData {
                        SignalStatusChip(title: "Example", color: theme.cobalt, symbol: "sparkles")
                    }
                }

                HStack(alignment: .bottom, spacing: compact ? 6 : 9) {
                    ForEach(dayBuckets) { bucket in
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(bucket.isToday ? theme.cobalt : theme.cobaltSoft)
                                .frame(height: barHeight(for: bucket.words, compact: compact))
                            Text(bucket.label)
                                .font(
                                    VoxoLTypography.font(
                                        size: 9.5, weight: .medium, relativeTo: .caption)
                                )
                                .foregroundStyle(theme.secondaryInk)
                        }
                        .frame(maxWidth: .infinity, alignment: .bottom)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
    }

    private func appUsageCard(compact: Bool) -> some View {
        SignalCard(padding: compact ? 15 : 18) {
            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                VStack(alignment: .leading, spacing: 3) {
                    SignalEyebrow(title: "Where you dictate")
                    Text(appUsageTitle)
                        .font(
                            VoxoLTypography.font(
                                size: compact ? 14.5 : 17,
                                weight: .semibold,
                                relativeTo: .headline
                            )
                        )
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                }

                if appUsage.isEmpty {
                    Label("No retained app activity yet.", systemImage: "macwindow")
                        .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    VStack(spacing: compact ? 8 : 11) {
                        ForEach(appUsage) { usage in
                            HStack(spacing: 8) {
                                Text(verbatim: usage.name)
                                    .font(
                                        VoxoLTypography.font(
                                            size: compact ? 10.5 : 12,
                                            weight: .medium,
                                            relativeTo: .caption
                                        )
                                    )
                                    .foregroundStyle(theme.ink)
                                    .lineLimit(1)
                                    .frame(width: compact ? 50 : 70, alignment: .leading)
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(theme.selection)
                                        Capsule()
                                            .fill(usage.isOther ? theme.coral : theme.cobalt)
                                            .frame(width: proxy.size.width * usage.share)
                                    }
                                }
                                .frame(height: 7)
                                Text(verbatim: "\(Int((usage.share * 100).rounded()))%")
                                    .font(
                                        VoxoLTypography.font(
                                            size: 10.5,
                                            weight: .semibold,
                                            relativeTo: .caption
                                        )
                                    )
                                    .foregroundStyle(theme.ink)
                                    .monospacedDigit()
                                    .frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
    }

    private var filteredRecords: [TranscriptRecord] {
        guard let dayCount = period.dayCount,
            let start = Calendar.current.date(byAdding: .day, value: -dayCount, to: Date())
        else {
            return transcripts.records
        }
        return transcripts.records.filter { $0.createdAt >= start }
    }

    private var filteredWords: Int {
        filteredRecords.reduce(0) { $0 + $1.wordCount }
    }

    private var totalSpeakingSeconds: TimeInterval {
        filteredRecords.reduce(0) { $0 + max(0, $1.durationSeconds) }
    }

    private var averageWPM: Int {
        totalSpeakingSeconds > 0
            ? Int((Double(filteredWords) / totalSpeakingSeconds * 60).rounded())
            : 0
    }

    private var averageWordsPerSession: Double {
        filteredRecords.isEmpty ? 0 : Double(filteredWords) / Double(filteredRecords.count)
    }

    private var uniqueApps: Int {
        Set(filteredRecords.map(\.applicationName)).count
    }

    private var recoveredTime: String {
        let value = SignalTodayView.recoveredTime(for: filteredRecords)
        return String(localized: "\(value) recovered")
    }

    private var insightSummary: LocalizedStringKey {
        switch period {
        case .sevenDays: "Seven days of dictation, measured only on this Mac."
        case .thirtyDays: "Thirty days of dictation, measured only on this Mac."
        case .all: "All retained dictations, measured only on this Mac."
        }
    }

    private var periodEyebrow: LocalizedStringKey {
        switch period {
        case .sevenDays: "This week"
        case .thirtyDays: "Last 30 days"
        case .all: "All time"
        }
    }

    private var appUsageTitle: LocalizedStringKey {
        guard let first = appUsage.first else {
            return "Your apps will appear here."
        }
        return first.name == "Other"
            ? "Your apps, locally measured." : "Your first reflex is visible."
    }

    private var appUsage: [AppUsage] {
        let grouped = Dictionary(grouping: filteredRecords, by: \.applicationName)
        let total = max(1, filteredRecords.count)
        let sorted =
            grouped
            .map { AppUsage(name: $0.key, count: $0.value.count, total: total) }
            .sorted { $0.count > $1.count }
        if sorted.count <= 4 {
            return sorted
        }
        let first = Array(sorted.prefix(3))
        let otherCount = sorted.dropFirst(3).reduce(0) { $0 + $1.count }
        return first + [AppUsage(name: "Other", count: otherCount, total: total, isOther: true)]
    }

    private var dayBuckets: [InsightDayBucket] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                let next = calendar.date(byAdding: .day, value: 1, to: day)
            else {
                return nil
            }
            let words =
                filteredRecords
                .filter { $0.createdAt >= day && $0.createdAt < next }
                .reduce(0) { $0 + $1.wordCount }
            return InsightDayBucket(
                date: day,
                words: words,
                label: day.formatted(.dateTime.weekday(.narrow)),
                isToday: calendar.isDateInToday(day)
            )
        }
    }

    private var maximumDayWords: Int {
        max(1, dayBuckets.map(\.words).max() ?? 1)
    }

    private func barHeight(for words: Int, compact: Bool) -> CGFloat {
        guard words > 0 else {
            return 7
        }
        let maximumHeight: CGFloat = compact ? 72 : 96
        return max(14, CGFloat(words) / CGFloat(maximumDayWords) * maximumHeight)
    }

    private struct InsightDayBucket: Identifiable {
        let date: Date
        let words: Int
        let label: String
        let isToday: Bool

        var id: Date { date }
    }

    private struct AppUsage: Identifiable {
        let name: String
        let count: Int
        let total: Int
        var isOther = false

        var id: String { name }
        var share: CGFloat { CGFloat(count) / CGFloat(max(1, total)) }
    }
}

struct HomeStudioView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts

    let previewCapsule: () -> Void
    let replayPreflight: () -> Void

    @AppStorage("voxol.historyEnabled") private var historyEnabled = true

    var body: some View {
        StudioPage(
            eyebrow: "Overview",
            title: "Your voice, at a glance.",
            summary:
                "See how much you dictate, how quickly you speak and every locally retained result."
        ) {
            if transcripts.usesExampleData {
                exampleBanner
            }

            metricGrid

            StudioSection("Activity") {
                ShowcaseSurface {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Last 7 days")
                                    .font(.title3.weight(.semibold))
                                Text("Word volume by day")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryInk)
                            }
                            Spacer()
                            Toggle("Keep text history", isOn: $historyEnabled)
                                .toggleStyle(.switch)
                        }

                        TranscriptActivityChart(records: transcripts.records)

                        HStack(spacing: 10) {
                            Button(action: previewCapsule) {
                                Label("Preview capsule", systemImage: "waveform")
                            }
                            .buttonStyle(VoxoLPrimaryButtonStyle())

                            Button("Setup", action: replayPreflight)
                                .buttonStyle(VoxoLSecondaryButtonStyle())
                        }
                    }
                }
            }

            StudioSection(
                "Recent transcriptions",
                summary:
                    "Hover a result to copy it, restore its previous edit or export retained audio."
            ) {
                transcriptList
            }

            LocalOnlyNote(
                text:
                    "Text history is local and opt-in. Audio remains off unless you explicitly enable retention later."
            )
        }
        .overlay(alignment: .topTrailing) {
            toast
        }
        .animation(.easeInOut(duration: 0.18), value: transcripts.toast)
    }

    private var exampleBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
            VStack(alignment: .leading, spacing: 2) {
                Text("Example activity")
                    .font(.headline)
                Text("Visible for UI review only · never written to your history")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
            }
            Spacer()
        }
        .padding(15)
        .background(theme.selection)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180), spacing: 14)],
            spacing: 14
        ) {
            dashboardMetric(
                value: transcripts.metrics.words.formatted(),
                label: "Words",
                detail: "In retained dictations",
                symbol: "text.word.spacing"
            )
            dashboardMetric(
                value: transcripts.metrics.averageWordsPerMinute.formatted(),
                label: "Average WPM",
                detail: "Across speaking time",
                symbol: "speedometer"
            )
            dashboardMetric(
                value: transcripts.metrics.sessions.formatted(),
                label: "Dictations",
                detail: "Local sessions",
                symbol: "waveform"
            )
            dashboardMetric(
                value: speakingTime,
                label: "Speaking time",
                detail: "Audio is not retained",
                symbol: "timer"
            )
        }
    }

    @ViewBuilder
    private var transcriptList: some View {
        if transcripts.isLoading {
            VoxoLCard {
                ProgressView("Loading local history…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        } else if transcripts.records.isEmpty {
            VoxoLCard {
                ContentUnavailableView(
                    "No transcriptions yet",
                    systemImage: "text.bubble",
                    description: Text(
                        historyEnabled
                            ? "Your next successful dictation will appear here."
                            : "Enable text history to keep future dictations locally."
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 190)
            }
        } else {
            LazyVStack(spacing: 12) {
                ForEach(transcripts.records) { record in
                    TranscriptActivityRow(record: record, store: transcripts)
                }
            }
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let toast = transcripts.toast {
            toastLabel(toast)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.raisedSurface)
                .clipShape(Capsule())
                .overlay { Capsule().stroke(theme.line, lineWidth: 1) }
                .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                .padding(20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(1.6))
                    transcripts.dismissToast()
                }
        }
    }

    @ViewBuilder
    private func toastLabel(_ toast: TranscriptToast) -> some View {
        switch toast {
        case .copied:
            Label("Copied", systemImage: "checkmark")
        case .previousVersionRestored:
            Label("Previous version restored", systemImage: "arrow.uturn.backward")
        case .laterVersionRestored:
            Label("Later version restored", systemImage: "arrow.uturn.forward")
        case .audioExported:
            Label("Audio exported", systemImage: "checkmark")
        case .noAudioRetained:
            Label("No audio was retained", systemImage: "mic.slash")
        case .audioExportFailed:
            Label("Audio could not be exported", systemImage: "exclamationmark.triangle")
        case .historyLoadFailed:
            Label("History could not be loaded", systemImage: "exclamationmark.triangle")
        case .historySaveFailed:
            Label("History could not be saved", systemImage: "exclamationmark.triangle")
        case .editSaved:
            Label("Edit saved", systemImage: "checkmark")
        }
    }

    private var speakingTime: String {
        let seconds = Int(transcripts.metrics.speakingSeconds.rounded())
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private func dashboardMetric(
        value: String,
        label: LocalizedStringKey,
        detail: LocalizedStringKey,
        symbol: String
    ) -> some View {
        VoxoLCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: symbol)
                        .foregroundStyle(theme.secondaryInk)
                    Spacer()
                    Text(value)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TranscriptActivityRow: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PersonalizationStore.self) private var personalization

    @AppStorage("voxol.learningEnabled") private var learningEnabled = true
    @AppStorage("voxol.privateMode") private var privateMode = false

    let record: TranscriptRecord
    let store: TranscriptStore

    @State private var isHovering = false
    @State private var showsEditor = false

    var body: some View {
        VoxoLCard {
            VStack(alignment: .leading, spacing: 13) {
                metadata

                Text(record.text)
                    .font(.body)
                    .foregroundStyle(theme.ink)
                    .textSelection(.enabled)
                    .lineLimit(isHovering ? 6 : 3)

                HStack(spacing: 12) {
                    Label("\(record.wordCount) words", systemImage: "textformat")
                    Label("\(record.wordsPerMinute) WPM", systemImage: "speedometer")
                    Label(duration, systemImage: "timer")
                    Spacer()
                    actions
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
                }
                .font(.caption)
                .foregroundStyle(theme.secondaryInk)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button("Edit text") {
                showsEditor = true
            }
            .disabled(record.isExample)
            Button("Copy text") {
                store.copy(record)
            }
            Button("Restore previous version") {
                Task {
                    await store.undoLastEdit(for: record.id)
                }
            }
            .disabled(!record.canUndo)
            Button("Restore later version") {
                Task {
                    await store.redoLastEdit(for: record.id)
                }
            }
            .disabled(!record.canRedo)
            Divider()
            Button("Export retained audio") {
                Task {
                    await store.exportAudio(for: record)
                }
            }
            .disabled(record.audioRelativePath == nil)
        }
        .sheet(isPresented: $showsEditor) {
            TranscriptEditor(text: record.text) { editedText in
                Task {
                    guard let edit = await store.replaceText(for: record.id, with: editedText)
                    else {
                        return
                    }
                    guard learningEnabled, !privateMode else {
                        return
                    }
                    let detected = LanguageDetector.detect(edit.correctedText)
                    let language: PersonalizationLanguage = detected == .french ? .french : .english
                    await personalization.addCorrection(
                        CorrectionPair(
                            rawTranscript: edit.rawTranscript,
                            correctedText: edit.correctedText,
                            bundleIdentifier: edit.applicationBundleIdentifier,
                            profile: .automatic,
                            language: language
                        )
                    )
                }
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 10) {
            Image(systemName: applicationSymbol)
                .font(.subheadline)
                .frame(width: 24)
            Text(record.applicationName)
                .font(.subheadline.weight(.semibold))
            if record.isExample {
                Text("Example")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.secondaryInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.selection)
                    .clipShape(Capsule())
            }
            Spacer()
            Text(record.createdAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                .font(.caption)
                .foregroundStyle(theme.secondaryInk)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                showsEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .disabled(record.isExample)
            .help("Edit text")

            Button {
                store.copy(record)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy text")

            Button {
                Task {
                    await store.undoLastEdit(for: record.id)
                }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!record.canUndo)
            .help("Restore previous version")

            Button {
                Task {
                    await store.redoLastEdit(for: record.id)
                }
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!record.canRedo)
            .help("Restore later version")

            Button {
                Task {
                    await store.exportAudio(for: record)
                }
            } label: {
                Image(systemName: "waveform.badge.arrow.down")
            }
            .disabled(record.audioRelativePath == nil)
            .help(
                record.audioRelativePath == nil ? "No audio was retained" : "Export retained audio")
        }
        .buttonStyle(.borderless)
    }

    private var duration: String {
        record.durationSeconds.formatted(.number.precision(.fractionLength(1))) + "s"
    }

    private var applicationSymbol: String {
        switch record.applicationBundleIdentifier {
        case "com.apple.mail":
            "envelope"
        case "com.apple.Notes":
            "note.text"
        case "com.microsoft.VSCode":
            "chevron.left.forwardslash.chevron.right"
        default:
            "macwindow"
        }
    }
}

struct TranscriptEditor: View {
    @Environment(\.dismiss) private var dismiss

    let save: (String) -> Void
    @State private var text: String

    init(text: String, save: @escaping (String) -> Void) {
        self.save = save
        _text = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit transcription")
                .font(.title2.weight(.semibold))
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 180)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save(text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

private struct TranscriptActivityChart: View {
    @Environment(VoxoLTheme.self) private var theme

    let records: [TranscriptRecord]

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(dayBuckets) { bucket in
                VStack(spacing: 8) {
                    Text(bucket.words.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.secondaryInk)
                        .opacity(bucket.words == 0 ? 0 : 1)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(bucket.words == 0 ? theme.selection : theme.ink)
                        .frame(height: barHeight(for: bucket.words))
                    Text(bucket.date, format: .dateTime.weekday(.narrow))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.secondaryInk)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 150, alignment: .bottom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Word activity over the last 7 days")
    }

    private var dayBuckets: [DayBucket] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today),
                let next = calendar.date(byAdding: .day, value: 1, to: date)
            else {
                return nil
            }
            let words =
                records
                .filter { $0.createdAt >= date && $0.createdAt < next }
                .reduce(0) { $0 + $1.wordCount }
            return DayBucket(date: date, words: words)
        }
    }

    private var maximumWords: Int {
        max(1, dayBuckets.map(\.words).max() ?? 1)
    }

    private func barHeight(for words: Int) -> CGFloat {
        words == 0 ? 8 : max(18, CGFloat(words) / CGFloat(maximumWords) * 94)
    }

    private struct DayBucket: Identifiable {
        let date: Date
        let words: Int

        var id: Date { date }
    }
}

/// What a result actually was: the finished text, and — when the model changed something — the
/// raw transcript compared against it word by word.
struct TranscriptDetailSheet: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss

    let record: TranscriptRecord
    let store: TranscriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(
                        title: "Final text",
                        trailing: {
                            Button("Copy") { store.copy(record) }
                                .buttonStyle(SignalQuietButtonStyle())
                        }
                    ) {
                        Text(verbatim: record.text)
                            .font(VoxoLTypography.font(size: 15, relativeTo: .body))
                            .foregroundStyle(theme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let raw = rawTranscript {
                        if let tokens = TranscriptDiff.tokens(raw: raw, final: record.text) {
                            section(
                                title: "What VoxoL changed",
                                trailing: { TranscriptDiffLegend() }
                            ) {
                                TranscriptDiffText(tokens: tokens)
                            }
                        }

                        section(
                            title: "Heard",
                            trailing: {
                                Button("Copy") { copyRaw(raw) }
                                    .buttonStyle(SignalQuietButtonStyle())
                            }
                        ) {
                            Text(verbatim: raw)
                                .font(VoxoLTypography.font(size: 14, relativeTo: .body))
                                .foregroundStyle(theme.secondaryInk)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        section(title: "What VoxoL changed") {
                            Text("Nothing to clean up — the transcript came out ready.")
                                .font(VoxoLTypography.font(size: 14, relativeTo: .body))
                                .foregroundStyle(theme.secondaryInk)
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
            }

            footer
        }
        .frame(width: 640, height: 520)
        .background(theme.canvas)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Result")
                    .font(VoxoLTypography.font(size: 11, weight: .semibold, relativeTo: .caption))
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(theme.secondaryInk)

                Text(verbatim: record.applicationName)
                    .font(VoxoLTypography.font(size: 22, weight: .semibold, relativeTo: .title2))
                    .foregroundStyle(theme.ink)

                Text(record.createdAt, format: .dateTime.day().month(.wide).hour().minute())
                    .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
            }

            Spacer(minLength: 8)

            SignalIconButton(symbol: "xmark", help: "Close") { dismiss() }
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("\(record.wordCount) words")
            Text(verbatim: "·")
            Text("\(record.wordsPerMinute) WPM")
            Text(verbatim: "·")
            Text("On this Mac")
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(SignalQuietButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
        .foregroundStyle(theme.secondaryInk)
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    /// The raw transcript is kept as the oldest revision, exactly as the store reads it.
    private var rawTranscript: String? {
        guard let raw = record.revisions.first?.text,
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                != record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return nil
        }
        return raw
    }

    private func copyRaw(_ raw: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(raw, forType: .string)
    }

    @ViewBuilder
    private func section<Content: View, Trailing: View>(
        title: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(VoxoLTypography.font(size: 11, weight: .semibold, relativeTo: .caption))
                    .textCase(.uppercase)
                    .tracking(0.9)
                    .foregroundStyle(theme.secondaryInk)
                Spacer(minLength: 12)
                trailing()
            }
            SignalCard(padding: 16) {
                content()
            }
        }
    }
}

/// A quiet text button for the detail sheet, in the same ink as the rest of the Hub.
struct SignalQuietButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(configuration.isPressed ? theme.ink : theme.cobalt)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule().fill(theme.selection.opacity(configuration.isPressed ? 0.9 : 0.55))
            )
            .contentShape(Capsule())
    }
}
