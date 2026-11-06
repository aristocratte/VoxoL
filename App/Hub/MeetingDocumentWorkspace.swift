import AppKit
import SpeakerKit
import SwiftUI

/// One meeting, written down: the report in a reading column with each passage's time in the
/// margin, the conversation printed above it as the audio's scrubber, and the transcript beside it.
/// Editing switches the same column to the rich editor; nothing about the report is lost.
struct MeetingReportView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let transcript: SpeakerTranscript
    let french: Bool

    @AppStorage("voxol.meetings.transcriptOpen") private var showTranscript = true
    @State private var playback = MeetingPlayback()
    @State private var editor = MeetingEditorController()
    @State private var editing = false
    @State private var focusedBlock: UUID?
    @State private var showVersions = false
    @State private var showProposal = false
    @State private var showVoices = false
    @State private var showLink = false
    @State private var link = "https://"
    @State private var includeExportSources = true
    @State private var confirmDeletion = false
    @State private var envelope: [Double] = []

    private var draft: MeetingReportDraft? { meetings.reports[transcript.id] }
    private var content: MeetingDocument { draft?.content ?? .init(title: transcript.title) }
    private var generating: Bool {
        meetings.phase == .reporting && meetings.processingID == transcript.id
    }
    private var isEmpty: Bool { content.blocks.allSatisfy { $0.text.isEmpty } }
    private var turnStarts: [Int: Double] {
        Dictionary(uniqueKeysWithValues: transcript.turns.map { ($0.id, $0.start) })
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar
                if editing { formattingBar }
                HStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        if editing { editorColumn } else { readingColumn }
                        playerBar.padding(.bottom, 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showTranscript && geometry.size.width >= 860 {
                        MeetingTranscriptPanel(
                            transcript: transcript, citedTurns: citedTurns, playback: playback,
                            french: french, renameVoices: { showVoices = true }
                        )
                        .frame(width: min(340, geometry.size.width * 0.32))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : EditorialMotion.soft, value: showTranscript)
        .animation(reduceMotion ? nil : EditorialMotion.soft, value: editing)
        .task(id: transcript.id) {
            envelope = ConversationPrint.envelope(of: transcript)
            if draft == nil { await meetings.createReport(for: transcript.id, french: french) }
        }
        .task {
            while !Task.isCancelled {
                playback.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onChange(of: transcript.turns) { _, _ in envelope = ConversationPrint.envelope(of: transcript) }
        .onChange(of: editor.selectedBlock) { _, id in if editing { focusedBlock = id } }
        .onDisappear { playback.stop() }
        .sheet(isPresented: $showProposal) {
            if let draft, let proposal = draft.proposal {
                MeetingProposalSheet(
                    current: draft.content, proposed: proposal.document, french: french,
                    canAccept: (try? MeetingReportDraft.fingerprint(of: transcript))
                        == proposal.sourceFingerprint,
                    accept: { meetings.acceptProposal(for: transcript.id); showProposal = false },
                    discard: { meetings.discardProposal(for: transcript.id); showProposal = false })
                .environment(theme)
            }
        }
        .sheet(isPresented: $showVersions) {
            MeetingVersionSheet(versions: draft?.versions ?? [], french: french) { version in
                meetings.restoreVersion(version, for: transcript.id)
                showVersions = false
            }
            .environment(theme)
        }
        .sheet(isPresented: $showVoices) {
            MeetingVoicesSheet(transcript: transcript, french: french)
                .environment(theme)
                .environment(meetings)
        }
        .confirmationDialog(
            tr(french, "Supprimer cette réunion ?", "Delete this meeting?"),
            isPresented: $confirmDeletion, titleVisibility: .visible
        ) {
            Button(tr(french, "Supprimer la réunion", "Delete meeting"), role: .destructive) {
                Task { await meetings.remove(transcript.id) }
            }
        } message: {
            Text(
                verbatim: tr(french, "Le fichier audio d’origine restera sur ton Mac.", "The original audio file stays on your Mac."))
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button {
                meetings.selection = nil
            } label: {
                Label(tr(french, "Réunions", "Meetings"), systemImage: "chevron.left")
            }
            .buttonStyle(HubButtonStyle(kind: .ghost))
            Spacer(minLength: 8)
            styleMenu
            exportMenu
            Button(editing ? (tr(french, "Terminé", "Done")) : (tr(french, "Modifier", "Edit"))) {
                editing.toggle()
                if !editing { focusedBlock = nil }
            }
            .buttonStyle(HubButtonStyle(kind: editing ? .primary : .ghost))
            .disabled(generating)
            Button {
                showTranscript.toggle()
            } label: {
                Label(tr(french, "Transcription", "Transcript"), systemImage: "text.alignleft")
            }
            .buttonStyle(HubButtonStyle(kind: showTranscript ? .secondary : .ghost))
            moreMenu
        }
        .padding(.leading, 10).padding(.trailing, 12)
        .frame(height: 48)
    }

    private var styleMenu: some View {
        Menu {
            ForEach(MeetingReportStyle.allCases, id: \.self) { style in
                Button {
                    meetings.reportStyle = style
                } label: {
                    if meetings.reportStyle == style {
                        Label(styleName(style), systemImage: "checkmark")
                    } else {
                        Text(styleName(style))
                    }
                }
            }
            Divider()
            Button(isEmpty ? (tr(french, "Rédiger", "Write")) : (tr(french, "Rédiger à nouveau", "Write again"))) {
                meetings.generateReport(for: transcript.id, french: french)
            }
            .disabled(meetings.busy || !meetings.reportModelAvailable)
        } label: {
            menuLabel(styleName(meetings.reportStyle))
        }
        .menuStyle(.borderlessButton).tint(theme.secondaryInk).fixedSize().padding(.horizontal, 6)
    }

    private var exportMenu: some View {
        Menu {
            if let draft {
                Toggle(tr(french, "Inclure les timecodes", "Include timecodes"), isOn: $includeExportSources)
                Divider()
                Button("Word (.docx)") {
                    meetings.exportWord(draft, title: transcript.title, includeSources: includeExportSources)
                }
                Button("PDF") {
                    meetings.exportPDF(draft, title: transcript.title, includeSources: includeExportSources)
                }
                Button("Markdown") {
                    meetings.exportReport(draft, title: transcript.title, includeSources: includeExportSources)
                }
                Divider()
                Button(tr(french, "Copier le compte rendu", "Copy report")) { meetings.copyReport(draft) }
            }
        } label: {
            menuLabel(tr(french, "Exporter", "Export"))
        }
        .menuStyle(.borderlessButton).tint(theme.secondaryInk).fixedSize().padding(.horizontal, 6)
        .disabled(draft == nil || isEmpty)
    }

    private var moreMenu: some View {
        Menu {
            Button(
                transcript.favorite == true
                    ? (tr(french, "Retirer des favoris", "Remove from favorites"))
                    : (tr(french, "Ajouter aux favoris", "Add to favorites"))
            ) {
                meetings.updateMeeting(transcript.id) { $0.favorite = !($0.favorite ?? false) }
            }
            Button(
                draft?.reviewedAt == nil
                    ? (tr(french, "Marquer comme relue", "Mark as reviewed"))
                    : (tr(french, "Marquer à relire", "Mark as to review"))
            ) {
                meetings.markReviewed(draft?.reviewedAt == nil, for: transcript.id)
            }
            .disabled(isEmpty || generating)
            Button(tr(french, "Versions…", "Versions…")) { showVersions = true }
            Button(tr(french, "Renommer les voix…", "Rename voices…")) { showVoices = true }
            Menu(tr(french, "Événement du calendrier", "Calendar event")) {
                if transcript.calendarEvent != nil {
                    Button(tr(french, "Dissocier de l’événement", "Unlink event")) {
                        meetings.updateMeeting(transcript.id) { $0.calendarEvent = nil }
                    }
                    Divider()
                }
                ForEach(meetings.calendar.events) { event in
                    Button(event.title) {
                        meetings.updateMeeting(transcript.id) {
                            $0.calendarEvent = event.link; $0.meetingDate = event.start
                        }
                    }
                }
                if !meetings.calendar.connected {
                    Button(tr(french, "Connecter le calendrier", "Connect calendar")) {
                        Task { await meetings.calendar.connect() }
                    }
                }
            }
            Button(
                transcript.audioReference == nil
                    ? (tr(french, "Relier le fichier audio…", "Link the audio file…"))
                    : (tr(french, "Changer de fichier audio…", "Change the audio file…"))
            ) {
                meetings.attachAudio(to: transcript.id)
            }
            Divider()
            Button(tr(french, "Supprimer la réunion", "Delete meeting"), role: .destructive) {
                confirmDeletion = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.secondaryInk)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(theme.secondaryInk).fixedSize()
        .help(tr(french, "Plus d’actions", "More actions"))
    }

    private func menuLabel(_ title: String) -> some View {
        Text(verbatim: title)
            .font(VoxoLTypography.font(size: 13, weight: .medium))
            .foregroundStyle(theme.secondaryInk)
    }

    // MARK: Reading

    private var readingColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    status
                    if !transcript.turns.isEmpty {
                        print.padding(.top, 20)
                    }
                    if isEmpty {
                        emptyState.padding(.top, 24)
                    } else {
                        blocks.padding(.top, 14)
                    }
                    notes
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.leading, 56)
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 104)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: currentBlock) { _, id in
                guard let id, playback.playing else { return }
                withAnimation(EditorialMotion.soft) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                tr(french, "Titre de la réunion", "Meeting title"),
                text: Binding(
                    get: { transcript.title },
                    set: { title in
                        meetings.updateMeeting(transcript.id) { $0.title = String(title.prefix(240)) }
                    }),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(VoxoLTypography.serif(size: 30, weight: .semibold))
            .foregroundStyle(theme.ink)
            .accessibilityAddTraits(.isHeader)

            HStack(spacing: 10) {
                Text(verbatim: when)
                    .monospacedDigit()
                if !transcript.speakerIDs.isEmpty {
                    HStack(spacing: -5) {
                        ForEach(transcript.speakerIDs.prefix(5), id: \.self) { id in
                            MeetingSpeakerBadge(speaker: id, name: speakerName(id))
                                .overlay(Circle().stroke(theme.surface, lineWidth: 2))
                        }
                    }
                    Text(verbatim: transcript.speakerIDs.map(speakerName).joined(separator: ", "))
                        .lineLimit(1)
                }
                if let event = transcript.calendarEvent {
                    Label(event.title, systemImage: "calendar").lineLimit(1).help(event.calendar)
                }
            }
            .font(VoxoLTypography.font(size: 13))
            .foregroundStyle(theme.secondaryInk)
        }
    }

    private var when: String {
        let locale = Locale(identifier: tr(french, "fr", "en"))
        let start = transcript.occurredAt
        let end = start.addingTimeInterval(transcript.duration)
        let day = start.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))
            .sentenceCased
        let hours =
            "\(start.formatted(.dateTime.hour().minute().locale(locale))) – \(end.formatted(.dateTime.hour().minute().locale(locale)))"
        let minutes = max(1, Int((transcript.duration / 60).rounded()))
        return "\(day) · \(hours) · \(minutes) min"
    }

    @ViewBuilder
    private var status: some View {
        if generating {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(
                        verbatim: meetings.reportStage.isEmpty
                            ? (tr(french, "Rédaction du compte rendu…", "Writing the report…"))
                            : meetings.reportStage
                    )
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.ink)
                    Spacer()
                    Button(tr(french, "Annuler", "Cancel")) { meetings.cancel() }
                        .buttonStyle(HubButtonStyle(kind: .ghost))
                }
                ProgressView(value: min(1, max(0, meetings.reportProgress)))
                    .tint(theme.cobalt)
            }
            .padding(.top, 16)
        }
        if let proposal = draft?.proposal {
            notice(
                tr(french, "Une nouvelle version est prête.", "A new version is ready."),
                action: (tr(french, "Comparer", "Compare"), { showProposal = true })
            )
            .id(proposal.id)
        }
        if let draft, !draft.isCurrent(for: transcript), !isEmpty {
            notice(
                tr(french, "Les intervenants ont changé depuis la rédaction.", "Speakers changed since this report was written."),
                tone: theme.warning,
                action: (
                    tr(french, "Rédiger à nouveau", "Write again"),
                    { meetings.generateReport(for: transcript.id, french: french) }
                )
            )
        }
        if let failure = meetings.failure {
            notice(failure, tone: theme.warning, action: (tr(french, "Fermer", "Dismiss"), { meetings.failure = nil }))
        }
        if let error = playback.error {
            notice(
                error, tone: theme.warning,
                action: (tr(french, "Relier", "Link"), { meetings.attachAudio(to: transcript.id) }))
        }
    }

    private func notice(
        _ text: String, tone: Color? = nil, action: (String, () -> Void)
    ) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: text)
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(tone ?? theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action.0, action: action.1)
                .buttonStyle(HubButtonStyle(kind: .onWell))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 14)
    }

    private var print: some View {
        let chapters = chapterStarts
        return VStack(alignment: .leading, spacing: 6) {
            ConversationPrint(
                envelope: envelope, duration: transcript.duration,
                position: playback.player == nil && playback.position == 0 ? nil : playback.position,
                chapters: chapters.map(\.time),
                seek: { time in
                    if playback.player == nil {
                        playback.play(transcript.audioReference, at: time, french: french)
                    } else {
                        playback.seek(time)
                    }
                }
            )
            .frame(height: 52)
            .help(tr(french, "Cliquer pour écouter depuis ce moment", "Click to listen from this moment"))
            chapterLabels(chapters)
        }
    }

    private func chapterLabels(_ chapters: [(time: Double, title: String)]) -> some View {
        GeometryReader { proxy in
            ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                let end = index + 1 < chapters.count ? chapters[index + 1].time : transcript.duration
                let width = (end - chapter.time) / max(1, transcript.duration) * proxy.size.width
                let current = playback.position >= chapter.time && playback.position < end
                // A title shows whole or not at all: a cut-off chapter name reads as a glitch.
                ViewThatFits(in: .horizontal) {
                    Text(verbatim: chapter.title)
                        .font(VoxoLTypography.font(size: 12, weight: current ? .medium : .regular))
                        .foregroundStyle(current ? theme.ink : theme.secondaryInk)
                        .fixedSize()
                        .onTapGesture {
                            playback.play(transcript.audioReference, at: chapter.time, french: french)
                        }
                    Color.clear.frame(width: 0)
                }
                .frame(width: max(width - 6, 0), alignment: .leading)
                .offset(x: chapter.time / max(1, transcript.duration) * proxy.size.width)
            }
        }
        .frame(height: 16)
    }

    /// Chapters are the report's own headings, placed at the first moment each one cites.
    private var chapterStarts: [(time: Double, title: String)] {
        let blocks = content.blocks
        return blocks.indices.compactMap { index -> (Double, String)? in
            let block = blocks[index]
            // A topic is a heading followed by prose; the decision, task and question lists that
            // close a report are not moments of the conversation.
            guard block.kind == .heading, index + 1 < blocks.count,
                blocks[index + 1].kind == .paragraph, let time = startTime(of: block)
            else { return nil }
            return (time, block.text)
        }
        .sorted { $0.0 < $1.0 }
        .map { (time: $0.0, title: $0.1) }
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(content.blocks.enumerated()), id: \.element.id) { index, block in
                MeetingBlockRow(
                    block: block,
                    french: french,
                    number: numberedIndex(index),
                    time: startTime(of: block),
                    current: currentBlock == block.id,
                    focused: focusedBlock == block.id,
                    play: { time in playback.play(transcript.audioReference, at: time, french: french) },
                    toggle: { toggleTask(block.id) },
                    focus: { focusedBlock = focusedBlock == block.id ? nil : block.id }
                )
                .id(block.id)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !generating {
            HubDitherCard(art: "DitherCabin") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr(french, "Pas encore de compte rendu", "No report yet"))
                        .font(VoxoLTypography.font(size: 15, weight: .semibold))
                        .foregroundStyle(theme.ink)
                    Text(
                        meetings.reportModelAvailable
                            ? (tr(french, "VoxoL le rédige sur ce Mac à partir de la conversation.", "VoxoL writes it on this Mac from the conversation."))
                            : (tr(french, "Installe le moteur de rédaction dans Réglages, ou écris-le toi-même.", "Install the writing engine in Settings, or write it yourself."))
                    )
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button(tr(french, "Rédiger le compte rendu", "Write the report")) {
                            meetings.generateReport(for: transcript.id, french: french)
                        }
                        .buttonStyle(HubButtonStyle(kind: .primary))
                        .disabled(meetings.busy || !meetings.reportModelAvailable)
                        Button(tr(french, "Écrire moi-même", "Write it myself")) { editing = true }
                            .buttonStyle(HubButtonStyle(kind: .onWell))
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    /// The user's own notes and bookmarked moments, kept apart from what was said.
    @ViewBuilder
    private var notes: some View {
        let markers = (transcript.markers ?? []).sorted { $0.time < $1.time }
        let personal = transcript.personalNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !markers.isEmpty || !personal.isEmpty {
            Text(tr(french, "Tes notes", "Your notes"))
                .font(VoxoLTypography.serif(size: 19, weight: .semibold))
                .foregroundStyle(theme.ink)
                .padding(.top, 30)
                .padding(.bottom, 8)
            ForEach(markers) { marker in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button {
                        playback.play(transcript.audioReference, at: marker.time, french: french)
                    } label: {
                        Text(verbatim: MeetingTime.short(marker.time))
                            .font(VoxoLTypography.font(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryInk)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    TextField(
                        tr(french, "Moment marqué", "Bookmarked moment"),
                        text: Binding(
                            get: { marker.note },
                            set: { text in
                                meetings.updateMeeting(transcript.id) { record in
                                    if let index = record.markers?.firstIndex(where: { $0.id == marker.id }) {
                                        record.markers?[index].note = text
                                    }
                                }
                            }),
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(VoxoLTypography.serif(size: 16))
                    .foregroundStyle(theme.ink)
                }
                .padding(.leading, -56)
                .padding(.vertical, 4)
            }
            if !personal.isEmpty {
                TextField(
                    "",
                    text: Binding(
                        get: { transcript.personalNotes ?? "" },
                        set: { text in meetings.updateMeeting(transcript.id) { $0.personalNotes = text } }),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(VoxoLTypography.serif(size: 16))
                .foregroundStyle(theme.ink)
                .lineSpacing(6)
                .padding(.top, 6)
            }
        }
    }

    // MARK: Editing

    private var editorColumn: some View {
        MeetingRichEditor(document: Binding(get: { content }, set: save), controller: editor)
            .frame(maxWidth: 696)
            .padding(.horizontal, 32)
            .padding(.bottom, 72)
            .frame(maxWidth: .infinity)
    }

    private var formattingBar: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(MeetingDocumentBlock.Kind.allCases, id: \.self) { kind in
                    Button(kindName(kind)) { editor.setKind(kind) }
                }
            } label: {
                menuLabel(kindName(editor.kind))
            }
            .menuStyle(.borderlessButton).tint(theme.secondaryInk).fixedSize().padding(.horizontal, 6)
            formatButton("bold", help: tr(french, "Gras · ⌘B", "Bold · ⌘B")) { editor.toggle("bold") }
            formatButton("italic", help: tr(french, "Italique · ⌘I", "Italic · ⌘I")) { editor.toggle("italic") }
            formatButton("highlighter", help: tr(french, "Surligner", "Highlight")) { editor.toggle("highlight") }
            formatButton("link", help: tr(french, "Lien", "Link")) { showLink = true }
                .disabled(editor.selectedText.isEmpty)
                .popover(isPresented: $showLink) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(tr(french, "Lien du passage sélectionné", "Link for selected text"))
                        TextField("https://", text: $link).textFieldStyle(.roundedBorder)
                        HStack {
                            Button(tr(french, "Retirer", "Remove")) { editor.setLink(""); showLink = false }
                            Spacer()
                            Button(tr(french, "Appliquer", "Apply")) { editor.setLink(link); showLink = false }
                        }
                    }
                    .padding(18).frame(width: 320)
                }
            Menu {
                Button(tr(french, "Clarifier le passage", "Clarify passage")) {
                    rewrite("Make the prose clearer and more natural.")
                }
                Button(tr(french, "Raccourcir", "Shorten")) {
                    rewrite("Make the prose more concise without losing its important facts.")
                }
                Button(tr(french, "Développer depuis la conversation", "Expand from the conversation")) {
                    rewrite(
                        "Explain this point in more detail, only when the supplied passages support those details."
                    )
                }
            } label: {
                menuLabel(tr(french, "Réécrire", "Rewrite"))
            }
            .menuStyle(.borderlessButton).tint(theme.secondaryInk).fixedSize().padding(.horizontal, 6)
            .disabled(meetings.busy || !meetings.reportModelAvailable || selectedSources.isEmpty)
            formatButton("arrow.uturn.backward", help: tr(french, "Annuler", "Undo"), action: editor.undo)
            formatButton("arrow.uturn.forward", help: tr(french, "Rétablir", "Redo"), action: editor.redo)
            Spacer(minLength: 8)
            Text(verbatim: saveCaption)
                .font(VoxoLTypography.font(size: 12))
                .foregroundStyle(theme.secondaryInk)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(theme.well)
    }

    private func formatButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(HubButtonStyle(kind: .ghost))
        .help(help)
        .accessibilityLabel(help)
    }

    private var selectedSources: [Int] {
        content.blocks.first { $0.id == editor.selectedBlock }?.sourceTurnIDs ?? []
    }

    private func rewrite(_ instruction: String) {
        guard let block = editor.selectedBlock else { return }
        meetings.rewritePassage(block, in: transcript.id, instruction: instruction, french: french)
    }

    private func save(_ document: MeetingDocument) {
        meetings.updateDocument(document, for: transcript.id)
    }

    private var saveCaption: String {
        guard meetings.savedIDs.contains(transcript.id) else {
            return tr(french, "Cette session seulement", "This session only")
        }
        return switch meetings.saveState {
        case .session: tr(french, "Cette session seulement", "This session only")
        case .saving: tr(french, "Enregistrement…", "Saving…")
        case .saved: tr(french, "Enregistré", "Saved")
        case .failed: tr(french, "Échec de l’enregistrement", "Save failed")
        }
    }

    // MARK: Player

    @ViewBuilder
    private var playerBar: some View {
        if !transcript.turns.isEmpty {
            HStack(spacing: 2) {
                if transcript.audioReference == nil {
                    Text(tr(french, "Audio non relié", "No audio linked"))
                        .font(VoxoLTypography.font(size: 13))
                        .foregroundStyle(theme.secondaryInk)
                        .padding(.leading, 10)
                    Button(tr(french, "Relier", "Link")) { meetings.attachAudio(to: transcript.id) }
                        .buttonStyle(HubButtonStyle(kind: .ghost))
                } else {
                    Button(String("−15")) { playback.skip(-15, limit: transcript.duration) }
                        .buttonStyle(HubButtonStyle(kind: .ghost))
                        .accessibilityLabel(tr(french, "Reculer de 15 secondes", "Back 15 seconds"))
                    Button {
                        playback.toggle(transcript.audioReference, french: french)
                    } label: {
                        Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.surface)
                            .frame(width: 32, height: 32)
                            .background(theme.ink, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playback.playing ? Text("Pause") : Text(tr(french, "Lire", "Play")))
                    Button(String("+15")) { playback.skip(15, limit: transcript.duration) }
                        .buttonStyle(HubButtonStyle(kind: .ghost))
                        .accessibilityLabel(tr(french, "Avancer de 15 secondes", "Forward 15 seconds"))
                    (Text(verbatim: MeetingTime.short(playback.position))
                        .foregroundColor(theme.ink)
                        + Text(verbatim: " / \(MeetingTime.short(transcript.duration))")
                        .foregroundColor(theme.secondaryInk))
                        .font(VoxoLTypography.font(size: 13, weight: .medium))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                    Button {
                        playback.cycleRate()
                    } label: {
                        Text(verbatim: playback.rate == 1 ? "1×" : String(format: "%g×", playback.rate))
                            .monospacedDigit()
                    }
                    .buttonStyle(HubButtonStyle(kind: .ghost))
                    .help(tr(french, "Vitesse de lecture", "Playback speed"))
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 44)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 0.5)
            .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
        }
    }

    // MARK: Model

    private func startTime(of block: MeetingDocumentBlock) -> Double? {
        block.sourceTurnIDs.compactMap { turnStarts[$0] }.min()
    }

    /// The passage being heard: the last block whose first source is at or before the playhead.
    private var currentBlock: UUID? {
        guard playback.player != nil else { return nil }
        let timed = content.blocks.compactMap { block in
            startTime(of: block).map { (block.id, $0) }
        }
        return timed.filter { $0.1 <= playback.position + 0.5 }.max { $0.1 < $1.1 }?.0
    }

    /// The turns a passage cites: the focused one, else the one being heard.
    private var citedTurns: Set<Int> {
        let id = editing ? editor.selectedBlock : (focusedBlock ?? currentBlock)
        return Set(content.blocks.first { $0.id == id }?.sourceTurnIDs ?? [])
    }

    private func numberedIndex(_ index: Int) -> Int {
        var count = 0
        var cursor = index
        while cursor >= 0, content.blocks[cursor].kind == .numbered {
            count += 1
            cursor -= 1
        }
        return count
    }

    private func toggleTask(_ id: UUID) {
        var document = content
        guard let index = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        document.blocks[index].checked.toggle()
        meetings.updateDocument(document, for: transcript.id)
    }

    private func speakerName(_ id: Int) -> String {
        transcript.name(for: id, prefix: tr(french, "Intervenant", "Speaker"))
    }

    private func styleName(_ style: MeetingReportStyle) -> String {
        switch style {
        case .complete: tr(french, "Compte rendu complet", "Full report")
        case .concise: tr(french, "Synthèse courte", "Short summary")
        case .technical: tr(french, "Note technique", "Technical brief")
        case .followup: tr(french, "Préparer le suivi", "Follow-up brief")
        }
    }

    private func kindName(_ kind: MeetingDocumentBlock.Kind) -> String {
        switch kind {
        case .paragraph: tr(french, "Paragraphe", "Paragraph")
        case .heading: tr(french, "Titre", "Heading")
        case .subheading: tr(french, "Sous-titre", "Subheading")
        case .bullet: tr(french, "Liste à puces", "Bullet list")
        case .numbered: tr(french, "Liste numérotée", "Numbered list")
        case .task: tr(french, "Action", "Task")
        case .quote: tr(french, "Citation", "Quote")
        }
    }
}

// MARK: - A passage of the report

/// One block, read: its time in the margin (a click plays from there), its text set in New York.
private struct MeetingBlockRow: View {
    @Environment(VoxoLTheme.self) private var theme

    let block: MeetingDocumentBlock
    let french: Bool
    let number: Int
    let time: Double?
    let current: Bool
    let focused: Bool
    let play: (Double) -> Void
    let toggle: () -> Void
    let focus: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if let time {
                    Button {
                        play(time)
                    } label: {
                        Text(verbatim: MeetingTime.short(time))
                            .font(VoxoLTypography.font(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(current ? theme.cobalt : theme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHeading ? (hovering ? 1 : 0) : 1)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: 44, alignment: .trailing)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, -56)
        .padding(.vertical, verticalPadding)
        .padding(.top, topPadding)
        .background {
            if current || focused {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.well)
                    .padding(.horizontal, -10)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: focus)
    }

    private var isHeading: Bool { block.kind == .heading || block.kind == .subheading }

    private var topPadding: CGFloat {
        switch block.kind {
        case .heading: 22
        case .subheading: 12
        default: 0
        }
    }

    private var verticalPadding: CGFloat {
        switch block.kind {
        case .paragraph, .quote: 6
        default: 3
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .heading:
            Text(attributed(size: 19, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        case .subheading:
            Text(attributed(size: 16, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: "•").font(VoxoLTypography.serif(size: 16))
                body(size: 16)
            }
        case .numbered:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(number).").font(VoxoLTypography.serif(size: 16)).monospacedDigit()
                body(size: 16)
            }
        case .task:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(action: toggle) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(block.checked ? theme.ink : theme.selection)
                        .frame(width: 16, height: 16)
                        .overlay {
                            if block.checked {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.surface)
                            }
                        }
                        .alignmentGuide(.firstTextBaseline) { $0.height - 3 }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(block.text))
                .accessibilityValue(Text(verbatim: block.checked ? tr(french, "Fait", "Done") : tr(french, "À faire", "To do")))
                body(size: 16)
                    .strikethrough(block.checked, color: theme.secondaryInk.opacity(0.5))
                    .foregroundStyle(block.checked ? theme.secondaryInk : theme.ink)
            }
        case .quote:
            body(size: 16)
                .foregroundStyle(theme.secondaryInk)
                .padding(.leading, 16)
        case .paragraph:
            body(size: 16)
        }
    }

    private func body(size: CGFloat) -> some View {
        Text(attributed(size: size, weight: .regular))
            .lineSpacing(6)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attributed(size: CGFloat, weight: Font.Weight) -> AttributedString {
        var result = AttributedString()
        for run in block.runs {
            var piece = AttributedString(run.text)
            var font = VoxoLTypography.serif(size: size, weight: run.bold ? .semibold : weight)
            if run.italic { font = font.italic() }
            piece.font = font
            piece.foregroundColor = theme.ink
            if run.highlighted { piece.backgroundColor = theme.cobaltSoft.opacity(0.7) }
            if let link = run.link, let url = URL(string: link) {
                piece.link = url
                piece.underlineStyle = .single
            }
            result.append(piece)
        }
        return result
    }
}

// MARK: - Sheets

/// Names for the voices of one meeting.
private struct MeetingVoicesSheet: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    @Environment(\.dismiss) private var dismiss

    let transcript: SpeakerTranscript
    let french: Bool

    @State private var names: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr(french, "Les voix de cette réunion", "Voices in this meeting"))
                .font(VoxoLTypography.font(size: 17, weight: .semibold))
                .foregroundStyle(theme.ink)
            HubPanel {
                ForEach(transcript.speakerIDs, id: \.self) { speaker in
                    HStack(spacing: 12) {
                        MeetingSpeakerBadge(speaker: speaker, name: names[speaker] ?? transcript.name(for: speaker, prefix: tr(french, "Intervenant", "Speaker")))
                        TextField(
                            "\(tr(french, "Intervenant", "Speaker")) \(speaker + 1)",
                            text: Binding(
                                get: { names[speaker] ?? transcript.names[speaker] ?? "" },
                                set: { names[speaker] = $0 })
                        )
                        .textFieldStyle(.plain)
                        .font(VoxoLTypography.font(size: 14))
                    }
                    .frame(minHeight: 44)
                }
            }
            .padding(.top, 16)
            HStack {
                Spacer()
                Button(tr(french, "Annuler", "Cancel")) { dismiss() }
                    .buttonStyle(HubButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button(tr(french, "Enregistrer", "Save")) {
                    Task {
                        for (speaker, name) in names {
                            await meetings.rename(speaker: speaker, to: name, in: transcript.id)
                        }
                        dismiss()
                    }
                }
                .buttonStyle(HubButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 440)
        .background(theme.surface)
    }
}

private struct MeetingProposalSheet: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    let current: MeetingDocument
    let proposed: MeetingDocument
    let french: Bool
    let canAccept: Bool
    let accept: () -> Void
    let discard: () -> Void
    @State private var left = MeetingEditorController()
    @State private var right = MeetingEditorController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(tr(french, "Comparer les versions", "Compare versions"))
                    .font(VoxoLTypography.font(size: 17, weight: .semibold))
                Spacer()
                Button(tr(french, "Fermer", "Close")) { dismiss() }
                    .buttonStyle(HubButtonStyle(kind: .ghost))
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr(french, "Ton document", "Your document"))
                        .font(VoxoLTypography.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.secondaryInk)
                    MeetingRichEditor(document: .constant(current), controller: left, editable: false)
                        .background(theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr(french, "Nouvelle version", "New version"))
                        .font(VoxoLTypography.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.secondaryInk)
                    MeetingRichEditor(document: .constant(proposed), controller: right, editable: false)
                        .background(theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            HStack {
                Text(
                    canAccept
                        ? (tr(french, "Ton document actuel reste dans les versions.", "Your current document stays in version history."))
                        : (tr(french, "La transcription a changé depuis cette version. Relance la rédaction.", "The transcript changed after this version. Write it again."))
                )
                .font(VoxoLTypography.font(size: 12))
                .foregroundStyle(canAccept ? theme.secondaryInk : theme.warning)
                Spacer()
                Button(tr(french, "Écarter", "Discard"), action: discard)
                    .buttonStyle(HubButtonStyle(kind: .secondary))
                Button(tr(french, "Utiliser cette version", "Use this version"), action: accept)
                    .buttonStyle(HubButtonStyle(kind: .primary))
                    .disabled(!canAccept)
            }
        }
        .padding(24)
        .frame(minWidth: 760, idealWidth: 960, minHeight: 560, idealHeight: 680)
        .background(theme.surface)
        .foregroundStyle(theme.ink)
    }
}

private struct MeetingVersionSheet: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss
    let versions: [MeetingReportVersion]
    let french: Bool
    let restore: (MeetingReportVersion) -> Void
    @State private var selected: UUID?
    @State private var editor = MeetingEditorController()
    private var version: MeetingReportVersion? {
        versions.first { $0.id == selected } ?? versions.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(tr(french, "Versions du compte rendu", "Report versions"))
                    .font(VoxoLTypography.font(size: 17, weight: .semibold))
                Spacer()
                Button(tr(french, "Fermer", "Close")) { dismiss() }
                    .buttonStyle(HubButtonStyle(kind: .ghost))
            }
            if let version {
                Picker(
                    tr(french, "Version", "Version"),
                    selection: Binding(get: { version.id }, set: { selected = $0 })
                ) {
                    ForEach(versions.reversed()) { item in
                        Text(item.date.formatted()).tag(item.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                MeetingRichEditor(document: .constant(version.document), controller: editor, editable: false)
                    .background(theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack {
                    Text(
                        tr(french, "Restaurer garde aussi le document actuel.", "Restoring also keeps the current document.")
                    )
                    .font(VoxoLTypography.font(size: 12))
                    .foregroundStyle(theme.secondaryInk)
                    Spacer()
                    Button(tr(french, "Restaurer", "Restore")) { restore(version) }
                        .buttonStyle(HubButtonStyle(kind: .primary))
                }
            } else {
                Text(
                    tr(french, "Aucune version précédente. Tes modifications et les nouvelles rédactions en créeront.", "No previous version. Your edits and new drafts will create them.")
                )
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.secondaryInk)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 740, height: 600)
        .background(theme.surface)
        .foregroundStyle(theme.ink)
    }
}
