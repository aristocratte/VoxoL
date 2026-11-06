import AppKit
import PersonalizationKit
import SwiftUI
import TextProcessingKit

// MARK: - History, computed once

/// One dictation's date and length, computed once so the charts and totals never split the same
/// text twice.
struct EditorialWordEntry {
    let date: Date
    let words: Int
    let seconds: TimeInterval

    init(_ record: TranscriptRecord) {
        date = record.createdAt
        words = record.wordCount
        seconds = max(0, record.durationSeconds)
    }
}

/// A calendar day of the history. Today carries no title: the page is already called Today.
struct HomeHistoryDay: Identifiable {
    let day: Date
    let title: String?
    let records: [TranscriptRecord]

    var id: Date { day }

    static func group(
        _ records: [TranscriptRecord], calendar: Calendar, locale: Locale
    ) -> [HomeHistoryDay] {
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            let title: String?
            if calendar.isDateInToday(day) {
                title = nil
            } else if calendar.isDateInYesterday(day) {
                title = String("Yesterday", in: locale)
            } else {
                title = day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
                    .sentenceCased
            }
            return HomeHistoryDay(
                day: day,
                title: title,
                records: grouped[day]?.sorted { $0.createdAt > $1.createdAt } ?? []
            )
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts
    @Environment(PersonalizationStore.self) private var personalization
    @Environment(\.locale) private var locale

    let setupReady: Bool
    let openSetup: () -> Void

    @AppStorage("voxol.dictationShortcut") private var shortcut = DictationShortcut.optionSpace
    @AppStorage("voxol.activationMode") private var activationMode = ActivationMode.hold
    @AppStorage("voxol.privateMode") private var privateMode = false
    @AppStorage("voxol.historyEnabled") private var historyEnabled = true
    @AppStorage("voxol.learningEnabled") private var learningEnabled = true

    @State private var days: [HomeHistoryDay] = []
    @State private var displayedDays: [HomeHistoryDay] = []
    @State private var todayCount = 0
    @State private var todayWords = 0
    @State private var query = ""
    @State private var openedID: UUID?
    @State private var inspected: TranscriptRecord?
    @State private var editing: TranscriptRecord?
    @FocusState private var searchFocused: Bool

    var body: some View {
        HubPage {
            HubPageHeader(
                title: "Today",
                meta: Text("\(todayCount) dictations · \(todayWords) words")
            ) {
                HubSearchField(text: $query, focus: $searchFocused)
            }

            if !setupReady {
                setupCard.padding(.top, 20)
            }

            notices

            feed
        }
        .onChange(of: transcripts.records, initial: true) { _, _ in rebuild() }
        .onChange(of: locale) { _, _ in rebuild() }
        .task(id: query) {
            if !query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            filter()
        }
        .sheet(item: $inspected) { record in
            TranscriptDetailSheet(record: record, store: transcripts)
                .environment(theme)
        }
        .sheet(item: $editing) { record in
            TranscriptEditor(text: record.text) { edited in
                Task { await saveEdit(of: record, text: edited) }
            }
        }
    }

    // MARK: Blocks

    private var setupCard: some View {
        HubDitherCard(art: "DitherCabin") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Finish setup to dictate")
                    .font(VoxoLTypography.font(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Text("VoxoL needs its permissions and local engines before the shortcut works.")
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open setup", action: openSetup)
                    .buttonStyle(HubButtonStyle(kind: .primary))
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let issue = transcripts.historyIssue {
            recoveryNotice(issue).padding(.top, 20)
        }
        if privateMode || !historyEnabled {
            Label(
                privateMode
                    ? LocalizedStringKey("Private mode is on · new dictations are not saved")
                    : LocalizedStringKey("History is paused · new dictations are not saved"),
                systemImage: privateMode ? "lock" : "pause.circle"
            )
            .font(VoxoLTypography.font(size: 13))
            .foregroundStyle(theme.secondaryInk)
            .padding(.top, 16)
        }
    }

    @ViewBuilder
    private var feed: some View {
        if transcripts.isLoading && transcripts.records.isEmpty {
            ProgressView().controlSize(.small).padding(.top, 24)
        } else if transcripts.records.isEmpty {
            if transcripts.historyIssue == nil && setupReady {
                HubDitherCard(art: "DitherCabin") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            activationMode == .hold
                                ? "Hold \(shortcut.label) and speak"
                                : "Press \(shortcut.label) and speak"
                        )
                        .font(VoxoLTypography.font(size: 15, weight: .semibold))
                            .foregroundStyle(theme.ink)
                        Text("Your dictations will appear here.")
                            .font(VoxoLTypography.font(size: 13))
                            .foregroundStyle(theme.secondaryInk)
                    }
                }
                .padding(.top, 20)
            }
        } else if displayedDays.isEmpty {
            Text(LocalizedStringKey("No dictation matches “\(query)”."))
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.secondaryInk)
                .padding(.top, 24)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(displayedDays) { day in
                    if let title = day.title {
                        Text(verbatim: title)
                            .font(VoxoLTypography.font(size: 13, weight: .medium))
                            .foregroundStyle(theme.secondaryInk)
                            .padding(.horizontal, 10)
                            .padding(.top, 22)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(day.records) { record in
                        if record.id == currentOpenID {
                            ResultCard(
                                record: record,
                                printed: record.id == latestID,
                                edit: { editing = record },
                                inspect: { inspected = record }
                            )
                            .padding(.vertical, 8)
                        } else {
                            HomeRow(record: record) {
                                withAnimation(EditorialMotion.soft) { openedID = record.id }
                            } inspect: {
                                inspected = record
                            }
                        }
                    }
                }
            }
            .padding(.top, displayedDays.first?.title == nil ? 12 : 0)
        }
    }

    private func recoveryNotice(_ issue: TranscriptHistoryIssue) -> some View {
        HubPanel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.warning)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        issue == .loadFailed
                            ? "History could not be loaded" : "History could not be saved"
                    )
                    .font(VoxoLTypography.font(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    Text(
                        issue == .loadFailed
                            ? "Your existing archive has not been replaced. Keep VoxoL open and retry to save any new results."
                            : "Recent changes are not saved. Keep VoxoL open and retry."
                    )
                    .font(VoxoLTypography.font(size: 12))
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Retry") { Task { await transcripts.retryHistory() } }
                        .buttonStyle(HubButtonStyle(kind: .onWell))
                        .disabled(transcripts.isLoading)
                        .accessibilityIdentifier("voxol.history.retry")
                    if !transcripts.records.isEmpty {
                        Button("Export recovery copy") {
                            Task { await transcripts.chooseRecoveryDestination() }
                        }
                        .buttonStyle(HubButtonStyle(kind: .onWell))
                        .help(
                            "Saves a separate JSON copy so you can quit safely. Your existing archive is unchanged."
                        )
                    }
                }
            }
            .padding(.vertical, 14)
        }
    }

    // MARK: State

    private var latestID: UUID? { transcripts.records.first?.id }

    /// The result shown open: the one the user chose, else the most recent one on screen.
    private var currentOpenID: UUID? {
        let visible = displayedDays.flatMap(\.records)
        if let openedID, visible.contains(where: { $0.id == openedID }) { return openedID }
        return visible.first?.id
    }

    private func rebuild() {
        var calendar = Calendar.current
        calendar.locale = locale
        days = HomeHistoryDay.group(transcripts.records, calendar: calendar, locale: locale)
        let today = transcripts.records.prefix { calendar.isDateInToday($0.createdAt) }
        todayCount = today.count
        todayWords = today.reduce(0) { $0 + $1.wordCount }
        filter()
    }

    private func filter() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            displayedDays = days
            return
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        displayedDays = days.compactMap { day in
            let matches = day.records.filter {
                $0.text.range(of: needle, options: options) != nil
                    || $0.applicationName.range(of: needle, options: options) != nil
            }
            return matches.isEmpty
                ? nil : HomeHistoryDay(day: day.day, title: day.title, records: matches)
        }
    }

    /// Saves a hand edit and, when learning is on, keeps the pair so VoxoL can learn from it.
    private func saveEdit(of record: TranscriptRecord, text: String) async {
        guard let edit = await transcripts.replaceText(for: record.id, with: text) else { return }
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

// MARK: - Rows

/// One dictation, closed: its app, its first line, its time. A click opens it in place.
private struct HomeRow: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts

    let record: TranscriptRecord
    let open: () -> Void
    let inspect: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            HubAppIcon(bundleIdentifier: record.applicationBundleIdentifier)
            Text(verbatim: record.text)
                .font(VoxoLTypography.font(size: 14))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                Button {
                    transcripts.copy(record)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 12))
                }
                .buttonStyle(HubButtonStyle(kind: .ghost))
                .help("Copy transcription")
            }
            Text(record.createdAt, format: .dateTime.hour().minute())
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.secondaryInk)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .hubRowHover(hovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy transcription") { transcripts.copy(record) }
            Button("Result detail", action: inspect)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Copy transcription")) { transcripts.copy(record) }
    }
}

/// One dictation, open: what was written in full, what was heard, and what to do with it.
/// The most recent result is printed on its dithered strip; any other opens on the plain well.
private struct ResultCard: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts
    @Environment(\.locale) private var locale

    let record: TranscriptRecord
    let printed: Bool
    let edit: () -> Void
    let inspect: () -> Void

    @State private var tokens: [TranscriptDiff.Token]?

    var body: some View {
        Group {
            if printed {
                HubDitherCard(art: "DitherCabin") { content }
            } else {
                content
                    .padding(.vertical, 16)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        theme.well, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .task(id: record.text) {
            tokens = record.revisions.first.flatMap {
                TranscriptDiff.tokens(raw: $0.text, final: record.text)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HubAppIcon(bundleIdentifier: record.applicationBundleIdentifier)
                Text(verbatim: record.applicationName)
                    .font(VoxoLTypography.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: meta)
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.secondaryInk)
                    .monospacedDigit()
            }

            Text(verbatim: record.text)
                .font(VoxoLTypography.serif(size: 19))
                .foregroundStyle(theme.ink)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            if let tokens {
                Text(heard(tokens))
                    .font(VoxoLTypography.font(size: 13))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityLabel(Text("Heard: \(record.originalText)"))
            }

            HStack(spacing: 6) {
                Button("Copy") { transcripts.copy(record) }
                    .buttonStyle(HubButtonStyle(kind: .primary))
                if record.canUndo {
                    Button("Restore original") {
                        Task { await transcripts.undoLastEdit(for: record.id) }
                    }
                    .buttonStyle(HubButtonStyle(kind: .onWell))
                } else if record.canRedo {
                    Button("Restore cleaned-up text") {
                        Task { await transcripts.redoLastEdit(for: record.id) }
                    }
                    .buttonStyle(HubButtonStyle(kind: .onWell))
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Edit text", action: edit)
                        .disabled(record.isExample)
                    Button("Result detail", action: inspect)
                    if record.audioRelativePath != nil {
                        Button("Export audio") {
                            Task { await transcripts.exportAudio(for: record) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.secondaryInk)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(theme.secondaryInk)
                .fixedSize()
                .help("More actions")
            }
            .padding(.top, 14)
        }
    }

    private var meta: String {
        let time = record.createdAt.formatted(.dateTime.hour().minute())
        let seconds = Int(record.durationSeconds.rounded())
        return String("\(time) · \(seconds) s · \(record.wordCount) words", in: locale)
    }

    /// The raw transcript as it was heard: what VoxoL dropped struck through, what it wrote in the
    /// data colour.
    private func heard(_ tokens: [TranscriptDiff.Token]) -> AttributedString {
        var result = AttributedString()
        for token in tokens {
            var piece = AttributedString(token.text)
            switch token.change {
            case .unchanged:
                piece.foregroundColor = theme.secondaryInk
            case .removed:
                piece.foregroundColor = theme.secondaryInk.opacity(0.6)
                piece.strikethroughStyle = .single
            case .added:
                piece.foregroundColor = theme.cobalt
            }
            result.append(piece)
            result.append(AttributedString(" "))
        }
        return result
    }
}
