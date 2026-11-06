import SpeakerKit
import SwiftUI

#if DEBUG
    /// The production meeting screen in an isolated preview without dictation services.
    struct SpeakerPreviewRoot: View {
        @State private var theme = VoxoLTheme()
        @State private var meetings = MeetingsStore()
        @State private var models = ModelInstallationStore()

        var body: some View {
            NativeMeetingsView()
                .environment(theme)
                .environment(meetings)
                .environment(models)
                .environment(\.locale, Locale(identifier: "fr"))
                .task {
                    if let state = ProcessInfo.processInfo.environment[
                        "VOXOL_MEETING_PREVIEW_STATE"]
                    {
                        meetings.configurePreview(state)
                        return
                    }
                    async let modelLoad: Void = models.load()
                    async let meetingsLoad: Void = meetings.load()
                    _ = await (modelLoad, meetingsLoad)
                }
        }
    }
#endif

/// Meetings: the list, one meeting's report, or the meeting being recorded.
struct NativeMeetingsView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The list stays reachable while a meeting is being recorded.
    @State private var browsingDuringCapture = false

    private var french: Bool { locale.language.languageCode?.identifier == "fr" }
    private var capturing: Bool {
        meetings.recorder.active || meetings.recorder.completedURL != nil
    }

    var body: some View {
        Group {
            if capturing && !browsingDuringCapture {
                MeetingLiveView(french: french, showList: { browsingDuringCapture = true })
                    .transition(.opacity)
            } else if let document = meetings.selected {
                MeetingReportView(transcript: document, french: french)
                    .id(document.id)
                    .transition(.opacity)
            } else {
                MeetingsListView(french: french, showCapture: { browsingDuringCapture = false })
                    .transition(.opacity)
            }
        }
        .foregroundStyle(theme.ink)
        .background(theme.surface)
        .animation(reduceMotion ? nil : EditorialMotion.soft, value: meetings.selection)
        .animation(reduceMotion ? nil : EditorialMotion.soft, value: capturing)
        .animation(reduceMotion ? nil : EditorialMotion.soft, value: browsingDuringCapture)
        .onChange(of: capturing) { _, now in if now { browsingDuringCapture = false } }
    }
}

// MARK: - List

private struct MeetingsListView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    @Environment(ModelInstallationStore.self) private var models

    let french: Bool
    let showCapture: () -> Void

    private enum Filter: Hashable, CaseIterable { case all, toReview, favorites }

    @State private var filter = Filter.all
    @State private var search = ""
    @State private var recording: RecordingRequest?
    @FocusState private var searchFocused: Bool

    private struct RecordingRequest: Identifiable {
        let id = UUID()
        let title: String
        var event: MeetingCalendarLink?
    }

    private var speakerPrefix: String { tr(french, "Intervenant", "Speaker") }

    private var records: [SpeakerTranscript] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return meetings.records.filter { record in
            let report = meetings.reports[record.id]
            let matchesFilter =
                switch filter {
                case .all: true
                case .toReview: report?.reviewedAt == nil
                case .favorites: record.favorite == true
                }
            let matchesQuery =
                query.isEmpty || record.title.localizedStandardContains(query)
                || record.rawText.localizedStandardContains(query)
                || (report?.content.plainText.localizedStandardContains(query) ?? false)
                || (record.project?.localizedStandardContains(query) ?? false)
                || record.speakerIDs.contains {
                    record.name(for: $0, prefix: speakerPrefix).localizedStandardContains(query)
                }
            return matchesFilter && matchesQuery
        }
        .sorted { $0.occurredAt > $1.occurredAt }
    }

    private var days: [(day: Date, records: [SpeakerTranscript])] {
        Dictionary(grouping: records) { Calendar.current.startOfDay(for: $0.occurredAt) }
            .map { (day: $0.key, records: $0.value) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        HubPage {
            HubPageHeader(verbatim: tr(french, "Réunions", "Meetings"), meta: Text(verbatim: summary)) {
                HStack(spacing: 6) {
                    importButton
                    Button {
                        recording = RecordingRequest(title: tr(french, "Nouvelle réunion", "New meeting"))
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(theme.coral).frame(width: 7, height: 7)
                            Text(tr(french, "Enregistrer", "Record"))
                        }
                    }
                    .buttonStyle(HubButtonStyle(kind: .primary))
                    .disabled(meetings.busy || meetings.recorder.completedURL != nil)
                }
            }

            if meetings.recorder.active || meetings.recorder.completedURL != nil {
                captureRow.padding(.top, 20)
            }
            if meetings.phase != .idle, meetings.processingID == nil || meetings.selected == nil {
                MeetingProgressLine(french: french).padding(.top, 20)
            }
            if let failure = meetings.failure {
                HubPanel {
                    HStack(spacing: 10) {
                        Text(verbatim: failure)
                            .font(VoxoLTypography.font(size: 13))
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(tr(french, "Fermer", "Dismiss")) { meetings.failure = nil }
                            .buttonStyle(HubButtonStyle(kind: .onWell))
                    }
                    .padding(.vertical, 10)
                }
                .padding(.top, 20)
            }

            MeetingUpcomingList(french: french) { event in
                recording = RecordingRequest(title: event.title, event: event.link)
            }

            HubSectionHeader(verbatim: tr(french, "Récentes", "Recent")) {
                HubSearchField(text: $search, focus: $searchFocused)
            }
            if !meetings.records.isEmpty {
                HubSegmented(options: Filter.allCases, selection: $filter) { option in
                    switch option {
                    case .all: Text(tr(french, "Toutes", "All"))
                    case .toReview: Text(tr(french, "À relire", "To review"))
                    case .favorites: Text(tr(french, "Favoris", "Favorites"))
                    }
                }
                .padding(.bottom, 8)
            }

            if meetings.records.isEmpty {
                HubDitherCard(art: "DitherCabin") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr(french, "Aucune réunion pour l’instant", "No meeting yet"))
                            .font(VoxoLTypography.font(size: 15, weight: .semibold))
                            .foregroundStyle(theme.ink)
                        Text(
                            tr(french, "Enregistre une réunion en présentiel ou en appel, ou importe un audio ou une vidéo. Tout reste sur ce Mac.", "Record a meeting in person or on a call, or import audio or video. Everything stays on this Mac.")
                        )
                        .font(VoxoLTypography.font(size: 13))
                        .foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if records.isEmpty {
                Text(tr(french, "Aucune réunion ne correspond.", "No meeting matches."))
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.secondaryInk)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(days, id: \.day) { day in
                        Text(verbatim: dayTitle(day.day))
                            .font(VoxoLTypography.font(size: 13, weight: .medium))
                            .foregroundStyle(theme.secondaryInk)
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(day.records) { record in
                            MeetingRow(record: record, french: french)
                        }
                    }
                }
            }
        }
        .sheet(item: $recording) { request in
            MeetingRecordingSheet(title: request.title, french: french, calendarEvent: request.event)
                .environment(theme)
                .environment(meetings)
        }
    }

    private var summary: String {
        let count = meetings.records.count
        let minutes = Int(meetings.records.reduce(0) { $0 + $1.duration } / 60)
        let duration = minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
        let noun = french ? (count > 1 ? "réunions" : "réunion") : (count == 1 ? "meeting" : "meetings")
        return "\(count) \(noun) · \(duration)"
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return tr(french, "Aujourd’hui", "Today") }
        if calendar.isDateInYesterday(day) { return tr(french, "Hier", "Yesterday") }
        let locale = Locale(identifier: tr(french, "fr", "en"))
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
            .sentenceCased
    }

    @ViewBuilder
    private var importButton: some View {
        if meetings.modelReady {
            Button(tr(french, "Importer", "Import")) {
                if let root = models.installedDirectory(for: .asr) {
                    meetings.importAudio(asrDirectory: root, french: french)
                }
            }
            .buttonStyle(HubButtonStyle(kind: .secondary))
            .disabled(meetings.busy || models.installedDirectory(for: .asr) == nil)
            .help(
                models.installedDirectory(for: .asr) == nil
                    ? (tr(french, "Installe d’abord le moteur de transcription dans Réglages.", "Install the transcription engine in Settings first."))
                    : (tr(french, "Importer un audio ou une vidéo", "Import audio or video")))
        } else {
            Button(tr(french, "Installer la reconnaissance des voix", "Install speaker recognition")) {
                meetings.installModel()
            }
            .buttonStyle(HubButtonStyle(kind: .secondary))
            .disabled(meetings.busy)
        }
    }

    private var captureRow: some View {
        let recorder = meetings.recorder
        return Button(action: showCapture) {
            HStack(spacing: 10) {
                Circle().fill(recorder.active ? theme.coral : theme.secondaryInk).frame(width: 8, height: 8)
                Text(verbatim: recorder.title)
                    .font(VoxoLTypography.font(size: 14, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(
                    verbatim: recorder.active
                        ? MeetingTime.short(recorder.elapsed)
                        : (tr(french, "Prêt à transcrire", "Ready to transcribe"))
                )
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.secondaryInk)
                .monospacedDigit()
                Spacer()
                Text(tr(french, "Revenir", "Return"))
                    .font(VoxoLTypography.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One past meeting: its printed conversation, title, time and length, its voices, its state.
private struct MeetingRow: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings

    let record: SpeakerTranscript
    let french: Bool

    @State private var hovering = false
    @State private var envelope: [Double] = []

    var body: some View {
        Button {
            meetings.selection = record.id
        } label: {
            HStack(spacing: 14) {
                ConversationPrint(envelope: envelope, duration: record.duration, tint: theme.secondaryInk)
                    .frame(width: 76, height: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: record.title)
                            .font(VoxoLTypography.font(size: 14, weight: .medium))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        if record.favorite == true {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(theme.secondaryInk)
                        }
                    }
                    Text(verbatim: detail)
                        .font(VoxoLTypography.font(size: 12))
                        .foregroundStyle(theme.secondaryInk)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: -5) {
                    ForEach(record.speakerIDs.prefix(4), id: \.self) { id in
                        MeetingSpeakerBadge(
                            speaker: id, name: record.name(for: id, prefix: tr(french, "Intervenant", "Speaker")))
                            .overlay(Circle().stroke(hovering ? theme.well : theme.surface, lineWidth: 2))
                    }
                }
                Text(verbatim: state)
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.secondaryInk)
                    .frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
            .hubRowHover(hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: record.turns.count) { envelope = ConversationPrint.envelope(of: record, slices: 60) }
        .accessibilityLabel(Text(verbatim: "\(record.title), \(detail), \(state)"))
    }

    private var detail: String {
        let locale = Locale(identifier: tr(french, "fr", "en"))
        let minutes = max(1, Int((record.duration / 60).rounded()))
        return "\(record.occurredAt.formatted(.dateTime.hour().minute().locale(locale))) · \(minutes) min"
    }

    private var state: String {
        if meetings.processingID == record.id && meetings.phase == .reporting {
            return tr(french, "En rédaction", "Writing")
        }
        guard let report = meetings.reports[record.id] else { return "" }
        if report.proposal != nil { return tr(french, "Nouvelle version", "New version") }
        if report.content.blocks.allSatisfy({ $0.text.isEmpty }) { return tr(french, "Sans compte rendu", "No report") }
        return report.reviewedAt == nil ? (tr(french, "À relire", "To review")) : (tr(french, "Relue", "Reviewed"))
    }
}
