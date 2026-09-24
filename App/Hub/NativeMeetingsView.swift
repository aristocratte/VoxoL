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

struct NativeMeetingsView: View {
    private enum Page: String { case report, transcript, people }

    private struct ReportSection: Identifiable {
        let id: Int
        let heading: String?
        var body: [String]
    }

    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    @Environment(ModelInstallationStore.self) private var models
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct RecordingRequest: Identifiable {
        let id = UUID()
        let title: String
    }
    @State private var recordingRequest: RecordingRequest?

    @State private var page: Page = .report
    @State private var editing = false
    @State private var editingSection: Int?
    @FocusState private var focusedSection: Int?
    @State private var search = ""
    @State private var names: [Int: String] = [:]
    @State private var copied = false
    @State private var confirmDeletion = false
    @State private var confirmRegeneration = false

    private var french: Bool { locale.language.languageCode?.identifier == "fr" }
    private var speakerPrefix: String { s("Intervenant", "Speaker") }
    private var unknownLabel: String { s("Intervenant incertain", "Uncertain speaker") }
    private var filteredRecords: [SpeakerTranscript] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings.records }
        return meetings.records.filter { record in
            record.title.localizedStandardContains(query)
                || record.rawText.localizedStandardContains(query)
                || record.speakerIDs.contains {
                    record.name(for: $0, prefix: speakerPrefix).localizedStandardContains(query)
                }
        }
    }

    var body: some View {
        Group {
            if let document = meetings.selected {
                meetingPage(document)
                    .transition(.opacity)
            } else {
                historyPage
                    .transition(.opacity)
            }
        }
        .foregroundStyle(theme.ink)
        .background(theme.canvas)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: meetings.selection)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: page)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: meetings.phase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: meetings.recorder.state)
        .sheet(item: $recordingRequest) { request in
            MeetingRecordingSheet(title: request.title, french: french)
        }
        .onChange(of: meetings.selection) { _, _ in
            page = .report
            editing = false
            editingSection = nil
            focusedSection = nil
            copied = false
            names = meetings.selected?.names ?? [:]
        }
        .confirmationDialog(
            s("Supprimer cette réunion ?", "Delete this meeting?"),
            isPresented: $confirmDeletion, titleVisibility: .visible
        ) {
            Button(s("Supprimer la réunion", "Delete meeting"), role: .destructive) {
                if let id = meetings.selection { Task { await meetings.remove(id) } }
            }
        } message: {
            Text(
                verbatim: s(
                    "Le fichier audio d’origine restera sur votre Mac.",
                    "The original audio file stays on your Mac."))
        }
        .confirmationDialog(
            s("Remplacer le compte rendu actuel ?", "Replace the current report?"),
            isPresented: $confirmRegeneration, titleVisibility: .visible
        ) {
            Button(s("Générer un nouveau brouillon", "Generate a new draft")) {
                if let id = meetings.selection { meetings.generateReport(for: id, french: french) }
            }
        } message: {
            Text(
                verbatim: s(
                    "Vos modifications seront remplacées. La transcription restera disponible.",
                    "Your edits will be replaced. The transcript stays available."))
        }
    }

    // MARK: History

    private var historyPage: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 11) {
                            eyebrow(s("VOTRE ESPACE RÉUNION", "YOUR MEETING SPACE"))
                            Text(verbatim: s("Les idées restent.", "Keep the ideas."))
                                .font(VoxoLTypography.font(size: 38, weight: .semibold))
                                .tracking(-1.4)
                            Text(
                                verbatim: s(
                                    "Enregistrez la conversation. Retrouvez l’essentiel.",
                                    "Record the conversation. Find what matters."
                                )
                            )
                            .font(VoxoLTypography.font(size: 15))
                            .foregroundStyle(theme.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 560, alignment: .leading)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 8) {
                            recordButton
                            importButton
                        }
                    }
                    .padding(.bottom, 35)

                    statusMessages

                    MeetingAgendaView(french: french) { title in
                        recordingRequest = RecordingRequest(title: title)
                    }

                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: s("Historique", "History"))
                                .font(VoxoLTypography.font(size: 20, weight: .semibold))
                            Text(
                                verbatim: s(
                                    "\(meetings.records.count) réunion\(meetings.records.count > 1 ? "s" : "") · \(Int(meetings.records.reduce(0) { $0 + $1.duration } / 60)) min de conversations",
                                    "\(meetings.records.count) meeting\(meetings.records.count == 1 ? "" : "s") · \(Int(meetings.records.reduce(0) { $0 + $1.duration } / 60)) min of conversations"
                                )
                            )
                            .font(VoxoLTypography.font(size: 12))
                            .foregroundStyle(theme.secondaryInk)
                        }
                        Spacer()
                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13))
                                .foregroundStyle(theme.secondaryInk)
                            TextField(s("Rechercher…", "Search…"), text: $search)
                                .textFieldStyle(.plain)
                                .font(VoxoLTypography.font(size: 13))
                        }
                        .padding(.horizontal, 13)
                        .frame(width: 276, height: 40)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.line))
                    }
                    .padding(.bottom, 16)

                    if meetings.records.isEmpty {
                        historyEmptyState
                    } else if filteredRecords.isEmpty {
                        Text(
                            verbatim: s(
                                "Aucune réunion ne correspond à cette recherche.",
                                "No meeting matches this search.")
                        )
                        .font(VoxoLTypography.font(size: 14))
                        .foregroundStyle(theme.secondaryInk)
                        .padding(30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        LazyVStack(spacing: 9) {
                            ForEach(filteredRecords) { record in
                                historyRow(record)
                            }
                        }
                    }
                    Text(
                        verbatim: s(
                            "TRAITEMENT LOCAL · LES FICHIERS RESTENT SUR CE MAC",
                            "LOCAL PROCESSING · FILES STAY ON THIS MAC")
                    )
                    .font(VoxoLTypography.font(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(theme.secondaryInk)
                    .padding(.top, 28)
                }
                .padding(.horizontal, 38)
                .padding(.vertical, 40)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var historyEmptyState: some View {
        VStack(alignment: .leading, spacing: 15) {
            VoxoLMark(size: 60)
            Text(
                verbatim: s(
                    "De la conversation à l’action.", "From conversation to action.")
            )
            .font(VoxoLTypography.font(size: 23, weight: .semibold))
            Text(
                verbatim: s(
                    "En présentiel ou en appel, gardez une trace claire des échanges, des décisions et des prochaines étapes. Vous pouvez aussi importer un audio ou une vidéo.",
                    "In person or on a call, keep a clear record of discussions, decisions and next steps. You can also import audio or video."
                )
            )
            .font(VoxoLTypography.font(size: 14))
            .foregroundStyle(theme.secondaryInk)
            .frame(maxWidth: 475, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 22) {
                Label(s("Enregistrer", "Record"), systemImage: "waveform")
                Image(systemName: "chevron.right").font(.system(size: 9))
                Label(s("Transcrire", "Transcribe"), systemImage: "text.alignleft")
                Image(systemName: "chevron.right").font(.system(size: 9))
                Label(s("Décider", "Take action"), systemImage: "checklist")
            }
            .font(VoxoLTypography.font(size: 12, weight: .medium))
            .foregroundStyle(theme.cobalt)
            .padding(.top, 8)
        }
        .padding(35)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.line))
    }

    private func historyRow(_ record: SpeakerTranscript) -> some View {
        Button {
            meetings.selection = record.id
        } label: {
            HStack(spacing: 18) {
                Image(systemName: "waveform")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(theme.cobalt)
                    .frame(width: 52, height: 52)
                    .background(theme.cobaltSoft, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 7) {
                    Text(verbatim: record.title)
                        .font(VoxoLTypography.font(size: 16, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(
                            verbatim: record.createdAt.formatted(
                                Date.FormatStyle(date: .abbreviated, time: .shortened).locale(
                                    locale)))
                        Text("·")
                        Text(verbatim: SpeakerTranscript.timestamp(record.duration))
                        Text("·")
                        Text(
                            verbatim: s(
                                "\(record.speakerIDs.count) intervenant\(record.speakerIDs.count > 1 ? "s" : "")",
                                "\(record.speakerIDs.count) speaker\(record.speakerIDs.count == 1 ? "" : "s")"
                            ))
                    }
                    .font(VoxoLTypography.font(size: 11.5))
                    .foregroundStyle(theme.secondaryInk)
                }
                Spacer(minLength: 8)
                Text(
                    verbatim: meetings.reports[record.id]?.generator == nil
                        ? s("À compléter", "To complete") : s("Compte rendu", "Report")
                )
                .font(VoxoLTypography.font(size: 11, weight: .medium))
                .foregroundStyle(
                    meetings.reports[record.id]?.generator == nil
                        ? theme.secondaryInk : theme.cobalt
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    meetings.reports[record.id]?.generator == nil
                        ? theme.selection : theme.cobaltSoft, in: Capsule())
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.secondaryInk)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(theme.line))
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(SignalPressButtonStyle())
        .accessibilityLabel("\(record.title), \(s("ouvrir la réunion", "open meeting"))")
    }

    private var importButton: some View {
        Button {
            if meetings.modelReady, let root = models.installedDirectory(for: .asr) {
                meetings.importAudio(asrDirectory: root, french: french)
            } else if !meetings.modelReady {
                meetings.installModel()
            }
        } label: {
            Label(
                meetings.modelReady
                    ? s("Importer un audio ou une vidéo", "Import audio or video")
                    : s("Installer la reconnaissance vocale", "Install speaker recognition"),
                systemImage: meetings.modelReady ? "arrow.up.doc" : "arrow.down.to.line"
            )
        }
        .buttonStyle(MeetingQuietButtonStyle())
        .disabled(
            meetings.busy || (meetings.modelReady && models.installedDirectory(for: .asr) == nil)
        )
        .help(
            models.installedDirectory(for: .asr) == nil && meetings.modelReady
                ? s(
                    "Installez d’abord le modèle de transcription dans Réglages.",
                    "Install the transcription model in Settings first.")
                : "")
    }

    private var recordButton: some View {
        Button {
            recordingRequest = RecordingRequest(title: s("Nouvelle réunion", "New meeting"))
        } label: {
            Label(s("Enregistrer une réunion", "Record a meeting"), systemImage: "record.circle")
        }
        .buttonStyle(MeetingAccentButtonStyle())
        .disabled(meetings.busy || meetings.recorder.completedURL != nil)
    }

    // MARK: Meeting workspace

    private func meetingPage(_ document: SpeakerTranscript) -> some View {
        VStack(spacing: 0) {
            meetingToolbar(document)
            Rectangle().fill(theme.line).frame(height: 1)
            statusMessages
                .padding(.horizontal, 24)
                .padding(.top, meetings.busy || meetings.failure != nil ? 12 : 0)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if geometry.size.width >= 880 {
                        outline(document)
                            .frame(width: 210)
                        Rectangle().fill(theme.line).frame(width: 1)
                    }
                    VStack(spacing: 0) {
                        if geometry.size.width < 880 {
                            compactNavigation
                        }
                        documentContent(document)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func meetingToolbar(_ document: SpeakerTranscript) -> some View {
        HStack(spacing: 14) {
            Button {
                meetings.selection = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                    Text(verbatim: s("Réunions", "Meetings"))
                }
            }
            .buttonStyle(MeetingQuietButtonStyle())
            Rectangle().fill(theme.line).frame(width: 1, height: 22)
            Text(verbatim: document.title)
                .font(VoxoLTypography.font(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(theme.secondaryInk)
            Spacer(minLength: 6)
            if let draft = meetings.reports[document.id] {
                Button {
                    meetings.exportWord(draft, title: document.title)
                } label: {
                    Label(s("Exporter Word", "Export Word"), systemImage: "doc.richtext")
                }
                .buttonStyle(SignalSecondaryButtonStyle())
                Menu {
                    Button(s("Modifier le Markdown source", "Edit Markdown source")) {
                        editingSection = nil
                        editing = true
                    }
                    Divider()
                    Button(s("Exporter Markdown", "Export Markdown")) {
                        meetings.exportReport(draft, title: document.title)
                    }
                    Button(s("Copier le Markdown", "Copy Markdown")) {
                        meetings.copyReport(draft)
                        copied = true
                    }
                    Divider()
                    Button(s("Supprimer la réunion", "Delete meeting"), role: .destructive) {
                        confirmDeletion = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .frame(width: 40, height: 40)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.line))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(s("Autres options", "More options"))
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 68)
        .background(theme.surface)
    }

    private func outline(_ document: SpeakerTranscript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow(s("CETTE RÉUNION", "THIS MEETING"))
                .padding(.horizontal, 16)
                .padding(.top, 30)
                .padding(.bottom, 12)
            navigationButton(.report, title: s("Compte rendu", "Report"), icon: "text.alignleft")
            navigationButton(.transcript, title: s("Transcription", "Transcript"), icon: "waveform")
            navigationButton(.people, title: s("Intervenants", "Speakers"), icon: "person.2")
            Rectangle().fill(theme.line).frame(height: 1).padding(.vertical, 18)
            Text(verbatim: s("INFORMATIONS", "DETAILS"))
                .font(VoxoLTypography.font(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(theme.secondaryInk)
                .padding(.horizontal, 16)
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                Text(
                    verbatim: document.createdAt.formatted(
                        Date.FormatStyle(date: .abbreviated).locale(locale)))
            }
            .font(VoxoLTypography.font(size: 12))
            .foregroundStyle(theme.secondaryInk)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            HStack(spacing: 8) {
                Image(systemName: "clock")
                Text(verbatim: SpeakerTranscript.timestamp(document.duration))
            }
            .font(VoxoLTypography.font(size: 12))
            .foregroundStyle(theme.secondaryInk)
            .padding(.horizontal, 16)
            Spacer(minLength: 8)
            Label(s("Traitement sur ce Mac", "Processed on this Mac"), systemImage: "lock.shield")
                .font(VoxoLTypography.font(size: 10))
                .foregroundStyle(theme.secondaryInk)
                .padding(.horizontal, 16)
                .padding(.bottom, 22)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface.opacity(0.66))
    }

    private var compactNavigation: some View {
        HStack(spacing: 5) {
            navigationButton(.report, title: s("Compte rendu", "Report"), icon: "text.alignleft")
            navigationButton(.transcript, title: s("Transcription", "Transcript"), icon: "waveform")
            navigationButton(.people, title: s("Intervenants", "Speakers"), icon: "person.2")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.surface.opacity(0.7))
    }

    private func navigationButton(_ target: Page, title: String, icon: String) -> some View {
        Button {
            page = target
            editing = false
            editingSection = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 17)
                Text(verbatim: title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(VoxoLTypography.font(size: 12.5, weight: page == target ? .semibold : .medium))
            .foregroundStyle(page == target ? theme.cobalt : theme.secondaryInk)
            .padding(.horizontal, 13)
            .frame(height: 39)
            .background(
                page == target ? theme.cobaltSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(SignalPressButtonStyle())
        .padding(.horizontal, 7)
    }

    @ViewBuilder
    private func documentContent(_ document: SpeakerTranscript) -> some View {
        switch page {
        case .report:
            reportPage(document)
        case .transcript:
            transcriptPage(document)
        case .people:
            peoplePage(document)
        }
    }

    // MARK: Report document and editor

    private func reportPage(_ document: SpeakerTranscript) -> some View {
        Group {
            if let draft = meetings.reports[document.id] {
                if editing {
                    editorPage(draft, document: document)
                } else {
                    reportPreview(draft, document: document)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        eyebrow(s("DOCUMENT", "DOCUMENT"))
                        Text(
                            verbatim: s(
                                "Un document pour cette réunion", "A document for this meeting")
                        )
                        .font(VoxoLTypography.font(size: 29, weight: .semibold))
                        Text(
                            verbatim: s(
                                "Créez un brouillon Markdown lié à la transcription, puis modifiez-le directement ici.",
                                "Create a Markdown draft linked to the transcript, then edit it here."
                            )
                        )
                        .font(VoxoLTypography.font(size: 14))
                        .foregroundStyle(theme.secondaryInk)
                        Button(s("Créer le brouillon", "Create draft")) {
                            Task { await meetings.createReport(for: document.id, french: french) }
                        }
                        .buttonStyle(MeetingAccentButtonStyle())
                    }
                    .padding(40)
                    .frame(maxWidth: 800, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
    }

    private func reportPreview(_ draft: MeetingReportDraft, document: SpeakerTranscript)
        -> some View
    {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                documentTopline(document, label: s("COMPTE RENDU", "MEETING REPORT"))
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.cobalt)
                    Text(
                        verbatim: draft.generator == nil
                            ? s("Brouillon à compléter", "Draft to complete")
                            : s(
                                "Brouillon généré · à relire",
                                "Generated draft · review before sharing"))
                    Spacer(minLength: 6)
                    Button {
                        let count = reportSections(draft.markdown).count
                        editingSection = count > 1 ? 1 : 0
                        focusedSection = editingSection
                    } label: {
                        Label(s("Modifier", "Edit"), systemImage: "pencil")
                    }
                    .buttonStyle(MeetingQuietButtonStyle())
                    Button {
                        regenerate(draft, document: document)
                    } label: {
                        Label(s("Générer", "Generate"), systemImage: "sparkles")
                    }
                    .buttonStyle(MeetingQuietButtonStyle())
                    .disabled(meetings.busy || !meetings.reportModelAvailable)
                }
                .font(VoxoLTypography.font(size: 11.5))
                .foregroundStyle(theme.secondaryInk)
                .padding(.bottom, 18)
                if !draft.isCurrent(for: document) {
                    inlineNotice(
                        s(
                            "La transcription ou les noms ont changé depuis la génération. Relisez ce document avant de le partager.",
                            "The transcript or names changed after generation. Review this document before sharing."
                        ), tone: theme.coral)
                }
                if !meetings.reportModelAvailable {
                    inlineNotice(
                        s(
                            "Le modèle local de compte rendu n’est pas disponible sur ce Mac. Vous pouvez toujours modifier et exporter le document.",
                            "The local report model is unavailable on this Mac. You can still edit and export this document."
                        ), tone: theme.secondaryInk)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(reportSections(draft.markdown)) { section in
                        if let heading = section.heading {
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: String(heading.dropFirst(3)))
                                    .font(VoxoLTypography.font(size: 19, weight: .semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    editingSection = section.id
                                    focusedSection = section.id
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(MeetingQuietButtonStyle())
                                .help(s("Modifier cette section", "Edit this section"))
                            }
                            .padding(.top, 22)
                            .padding(.bottom, 7)
                        }
                        if editingSection == section.id {
                            inlineSectionEditor(section, draft: draft, document: document)
                        } else {
                            ForEach(Array(section.body.enumerated()), id: \.offset) { _, line in
                                reportLine(line)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(theme.line).frame(height: 1).padding(.vertical, 24)
                Text(
                    verbatim: s(
                        "Document modifiable · enregistrement automatique · vérifiez les passages cités avant tout partage.",
                        "Editable document · autosaved · check cited passages before sharing."
                    )
                )
                .font(VoxoLTypography.font(size: 11))
                .foregroundStyle(theme.secondaryInk)
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .background(theme.surface)
    }

    private func inlineSectionEditor(
        _ section: ReportSection, draft: MeetingReportDraft, document: SpeakerTranscript
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "pencil.line")
                Text(verbatim: s("ÉDITION DE LA SECTION", "EDIT SECTION"))
                    .tracking(1)
                Spacer()
                Text(verbatim: s("Enregistré automatiquement", "Autosaved"))
                    .foregroundStyle(theme.secondaryInk)
            }
            .font(VoxoLTypography.font(size: 10, weight: .semibold))
            .foregroundStyle(theme.cobalt)
            TextField(
                s("Rédiger cette section…", "Write this section…"),
                text: Binding(
                    get: {
                        let current = meetings.reports[document.id]?.markdown ?? draft.markdown
                        let sections = reportSections(current)
                        guard sections.indices.contains(section.id) else { return "" }
                        return sections[section.id].body.joined(separator: "\n")
                            .trimmingCharacters(in: .newlines)
                    },
                    set: { updateSection($0, at: section.id, document: document.id) }
                ), axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(VoxoLTypography.font(size: 14))
            .lineSpacing(5)
            .lineLimit(4...40)
            .focused($focusedSection, equals: section.id)
            .accessibilityLabel(s("Modifier la section", "Edit section"))
            HStack {
                Text(
                    verbatim: s(
                        "Vous pouvez utiliser des listes, du gras et des liens Markdown.",
                        "Use Markdown lists, bold text and links."
                    )
                )
                .font(VoxoLTypography.font(size: 10))
                .foregroundStyle(theme.secondaryInk)
                Spacer()
                Button(s("Terminer", "Done")) {
                    editingSection = nil
                    focusedSection = nil
                }
                .buttonStyle(MeetingQuietButtonStyle())
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.canvas, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(theme.cobalt.opacity(0.34)))
    }

    private func reportSections(_ markdown: String) -> [ReportSection] {
        var sections = [ReportSection(id: 0, heading: nil, body: [])]
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                sections.append(ReportSection(id: sections.count, heading: line, body: []))
            } else {
                sections[sections.count - 1].body.append(line)
            }
        }
        return sections
    }

    private func updateSection(_ text: String, at index: Int, document id: UUID) {
        guard let markdown = meetings.reports[id]?.markdown else { return }
        var sections = reportSections(markdown)
        guard sections.indices.contains(index) else { return }
        sections[index].body = [""] + text.components(separatedBy: "\n") + [""]
        let result = sections.flatMap { section -> [String] in
            (section.heading.map { [$0] } ?? []) + section.body
        }.joined(separator: "\n")
        meetings.updateReport(result, for: id)
    }

    private func editorPage(_ draft: MeetingReportDraft, document: SpeakerTranscript) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pencil.line")
                    .foregroundStyle(theme.cobalt)
                Text(verbatim: s("ÉDITION DU DOCUMENT", "EDIT DOCUMENT"))
                    .font(VoxoLTypography.font(size: 10, weight: .semibold))
                    .tracking(1.3)
                Spacer()
                Text(verbatim: s("Enregistrement automatique", "Autosaved"))
                    .font(VoxoLTypography.font(size: 11))
                    .foregroundStyle(theme.secondaryInk)
                Button(s("Terminer", "Done")) { editing = false }
                    .buttonStyle(MeetingQuietButtonStyle())
            }
            .padding(.bottom, 15)
            Rectangle().fill(theme.line).frame(height: 1)
            TextEditor(
                text: Binding(
                    get: { meetings.reports[document.id]?.markdown ?? draft.markdown },
                    set: { meetings.updateReport($0, for: document.id) }
                )
            )
            .font(VoxoLTypography.font(size: 16))
            .lineSpacing(5)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(
                s("Éditeur Markdown du compte rendu", "Meeting report Markdown editor"))
        }
        .padding(.horizontal, 44)
        .padding(.top, 30)
        .frame(maxWidth: 840)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface)
    }

    private func regenerate(_ draft: MeetingReportDraft, document: SpeakerTranscript) {
        let template = try? MeetingReportDraft.template(for: document, french: french)
        if draft.markdown == template?.markdown {
            meetings.generateReport(for: document.id, french: french)
        } else {
            confirmRegeneration = true
        }
    }

    @ViewBuilder
    private func reportLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") {
            Text(verbatim: String(trimmed.dropFirst(2)))
                .font(VoxoLTypography.font(size: 31, weight: .semibold))
                .tracking(-0.7)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else if trimmed.hasPrefix("## ") {
            Text(verbatim: String(trimmed.dropFirst(3)))
                .font(VoxoLTypography.font(size: 19, weight: .semibold))
                .padding(.top, 22)
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else if trimmed.hasPrefix("### ") {
            HStack(spacing: 9) {
                Circle().fill(theme.cobalt).frame(width: 8, height: 8)
                Text(verbatim: String(trimmed.dropFirst(4)))
                    .font(VoxoLTypography.font(size: 15, weight: .semibold))
            }
            .padding(.top, 14)
            .padding(.bottom, 5)
        } else if trimmed.hasPrefix("- [ ] ") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(theme.cobalt, lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                richText(String(trimmed.dropFirst(6)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(VoxoLTypography.font(size: 14))
            .padding(.vertical, 2)
        } else if trimmed.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Circle().fill(theme.cobalt).frame(width: 5, height: 5)
                richText(String(trimmed.dropFirst(2)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(VoxoLTypography.font(size: 14))
            .padding(.vertical, 2)
        } else if trimmed.isEmpty {
            Color.clear.frame(height: 5)
        } else {
            richText(trimmed)
                .font(VoxoLTypography.font(size: 14))
                .lineSpacing(4)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }
    }

    private func richText(_ markdown: String) -> Text {
        if let rich = try? AttributedString(markdown: markdown) { return Text(rich) }
        return Text(verbatim: markdown)
    }

    // MARK: Transcript and people

    private func transcriptPage(_ document: SpeakerTranscript) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                documentTopline(document, label: s("TRANSCRIPTION", "TRANSCRIPT"))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: s("La conversation", "The conversation"))
                            .font(VoxoLTypography.font(size: 30, weight: .semibold))
                        Text(
                            verbatim: s(
                                "Cliquez sur le nom d’un intervenant pour corriger une attribution.",
                                "Click a speaker name to correct an assignment."
                            )
                        )
                        .font(VoxoLTypography.font(size: 13))
                        .foregroundStyle(theme.secondaryInk)
                    }
                    Spacer()
                    Button {
                        meetings.copy(document, french: french)
                        copied = true
                    } label: {
                        Label(
                            copied ? s("Copié", "Copied") : s("Copier", "Copy"),
                            systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(MeetingQuietButtonStyle())
                    Menu {
                        Button(s("Texte (.txt)", "Text (.txt)")) {
                            meetings.export(document, format: "txt", french: french)
                        }
                        Button(s("Sous-titres (.srt)", "Subtitles (.srt)")) {
                            meetings.export(document, format: "srt", french: french)
                        }
                        Button(s("Données (.json)", "Structured data (.json)")) {
                            meetings.export(document, format: "json", french: french)
                        }
                    } label: {
                        Label(s("Exporter", "Export"), systemImage: "square.and.arrow.up")
                            .font(VoxoLTypography.font(size: 12, weight: .medium))
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, 11)
                            .frame(height: 34)
                            .background(theme.canvas, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.line))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.bottom, 30)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.turns) { turn in
                        HStack(alignment: .top, spacing: 20) {
                            Text(verbatim: SpeakerTranscript.timestamp(turn.start))
                                .font(VoxoLTypography.font(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(theme.secondaryInk)
                                .frame(width: 70, alignment: .leading)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 8) {
                                    Circle().fill(
                                        turn.displayedSpeakerIDs.first.map(color)
                                            ?? theme.secondaryInk
                                    )
                                    .frame(width: 8, height: 8)
                                    Menu {
                                        ForEach(document.speakerIDs, id: \.self) { speaker in
                                            Button(
                                                document.name(for: speaker, prefix: speakerPrefix)
                                            ) {
                                                Task {
                                                    await meetings.assign(
                                                        speaker: speaker, turn: turn.id,
                                                        document: document.id)
                                                }
                                            }
                                        }
                                        Button(unknownLabel) {
                                            Task {
                                                await meetings.assign(
                                                    speaker: nil, turn: turn.id,
                                                    document: document.id)
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Text(
                                                verbatim: document.label(
                                                    for: turn, prefix: speakerPrefix,
                                                    unknown: unknownLabel))
                                        }
                                        .font(VoxoLTypography.font(size: 12, weight: .semibold))
                                        .foregroundStyle(theme.cobalt)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                    if turn.displayedOverlap {
                                        Text(verbatim: s("Voix superposées", "Overlapping voices"))
                                            .font(VoxoLTypography.font(size: 10))
                                            .foregroundStyle(theme.coral)
                                    }
                                }
                                Text(
                                    verbatim: turn.text.trimmingCharacters(
                                        in: .whitespacesAndNewlines)
                                )
                                .font(VoxoLTypography.font(size: 15))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 19)
                        Rectangle().fill(theme.line).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .background(theme.surface)
    }

    private func peoplePage(_ document: SpeakerTranscript) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                documentTopline(document, label: s("INTERVENANTS", "SPEAKERS"))
                Text(verbatim: s("Les personnes de cette réunion", "People in this meeting"))
                    .font(VoxoLTypography.font(size: 30, weight: .semibold))
                Text(
                    verbatim: s(
                        "Renommez les voix après vérification. Les noms et les corrections restent propres à cette réunion.",
                        "Rename voices after reviewing them. Names and corrections apply only to this meeting."
                    )
                )
                .font(VoxoLTypography.font(size: 14))
                .foregroundStyle(theme.secondaryInk)
                .padding(.bottom, 10)
                ForEach(document.speakerIDs, id: \.self) { speaker in
                    HStack(spacing: 15) {
                        Circle().fill(color(speaker)).frame(width: 11, height: 11)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: s("VOIX \(speaker + 1)", "VOICE \(speaker + 1)"))
                                .font(VoxoLTypography.font(size: 10, weight: .semibold))
                                .tracking(1)
                                .foregroundStyle(theme.secondaryInk)
                            TextField(
                                "\(speakerPrefix) \(speaker + 1)",
                                text: Binding(
                                    get: { names[speaker] ?? document.names[speaker] ?? "" },
                                    set: { names[speaker] = $0 }
                                )
                            )
                            .textFieldStyle(.plain)
                            .font(VoxoLTypography.font(size: 16, weight: .medium))
                            .onSubmit { rename(speaker, in: document) }
                        }
                        Spacer()
                        Button(s("Enregistrer", "Save")) { rename(speaker, in: document) }
                            .buttonStyle(SignalSecondaryButtonStyle())
                    }
                    .padding(18)
                    .background(theme.canvas, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line))
                }
                if let report = meetings.reports[document.id], !report.isCurrent(for: document) {
                    inlineNotice(
                        s(
                            "Les noms du compte rendu peuvent être anciens. Relisez ou régénérez le document.",
                            "Names in the report may be outdated. Review or regenerate the document."
                        ), tone: theme.coral)
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .background(theme.surface)
    }

    // MARK: Shared elements

    private func documentTopline(_ document: SpeakerTranscript, label: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(theme.cobalt).frame(width: 23, height: 4)
            eyebrow(label)
            Spacer()
            Text(verbatim: SpeakerTranscript.timestamp(document.duration))
                .font(VoxoLTypography.font(size: 11))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryInk)
        }
        .padding(.bottom, 25)
    }

    private func eyebrow(_ title: String) -> some View {
        Text(verbatim: title)
            .font(VoxoLTypography.font(size: 10, weight: .semibold))
            .tracking(1.35)
            .foregroundStyle(theme.secondaryInk)
    }

    private func inlineNotice(_ text: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle").foregroundStyle(tone)
            Text(verbatim: text)
                .foregroundStyle(theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(VoxoLTypography.font(size: 12))
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 15)
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let failure = meetings.failure {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.coral)
                Text(verbatim: failure).textSelection(.enabled)
                Spacer()
                Button {
                    meetings.failure = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(MeetingQuietButtonStyle())
            }
            .font(VoxoLTypography.font(size: 12))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.coralSoft, in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 15)
        }
        if meetings.recorder.active || meetings.recorder.completedURL != nil {
            MeetingCaptureCard(french: french)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if meetings.phase != .idle {
            MeetingProgressCard(french: french, label: phaseLabel)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var phaseLabel: String {
        switch meetings.phase {
        case .idle: s("Prêt", "Ready")
        case .checking:
            s("Vérification de la reconnaissance des voix…", "Checking speaker recognition…")
        case .downloading:
            s("Installation de la reconnaissance des voix…", "Installing speaker recognition…")
        case .reading: s("Préparation de la piste audio…", "Preparing audio track…")
        case .transcribing: s("Transcription de la conversation…", "Transcribing the conversation…")
        case .speakers: s("Identification des intervenants…", "Identifying speaker turns…")
        case .reporting: s("Rédaction du compte rendu local…", "Writing the local report…")
        case .cancelling: s("Annulation…", "Cancelling…")
        }
    }

    private func rename(_ speaker: Int, in document: SpeakerTranscript) {
        Task { await meetings.rename(speaker: speaker, to: names[speaker] ?? "", in: document.id) }
    }

    private func color(_ speaker: Int) -> Color {
        [theme.cobalt, theme.coral, theme.success, .purple, .orange, .teal, .indigo, .brown][
            speaker % 8]
    }

    private func s(_ french: String, _ english: String) -> String {
        self.french ? french : english
    }
}

struct MeetingAccentButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoxoLTypography.font(size: 13, weight: .semibold))
            .foregroundStyle(theme.surface)
            .padding(.horizontal, 18)
            .frame(height: 42)
            .background(
                enabled ? theme.cobalt : theme.secondaryInk,
                in: RoundedRectangle(cornerRadius: 11)
            )
            .opacity(enabled ? 1 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct MeetingQuietButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoxoLTypography.font(size: 12, weight: .medium))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 9)
            .frame(minHeight: 34)
            .background(
                configuration.isPressed ? theme.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}
