import AppKit
import SpeakerKit
import SwiftUI

struct MeetingDocumentWorkspace: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let transcript: SpeakerTranscript
    let french: Bool
    @State private var editor = MeetingEditorController()
    @State private var showSources = false
    @State private var showVersions = false
    @State private var showProposal = false
    @State private var showLink = false
    @State private var link = "https://"

    private var draft: MeetingReportDraft? { meetings.reports[transcript.id] }
    private var content: MeetingDocument { draft?.content ?? .init(title: transcript.title) }
    private var selectedBlock: MeetingDocumentBlock? {
        content.blocks.first { $0.id == editor.selectedBlock }
    }
    private var generating: Bool {
        meetings.phase == .reporting && meetings.processingID == transcript.id
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width > 1_030 && (!showSources || geometry.size.width > 1_280) {
                    MeetingDocumentOutline(
                        document: content, selected: editor.selectedBlock,
                        french: french, navigate: editor.scroll
                    )
                    .frame(width: 190)
                    Divider().overlay(theme.line)
                }
                VStack(spacing: 0) {
                    header
                    formattingBar
                    if let proposal = draft?.proposal {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.badge.clock")
                            Text(
                                french
                                    ? "Une nouvelle version est prête." : "A new version is ready.")
                            Spacer()
                            Button(french ? "Comparer" : "Compare") { showProposal = true }
                                .buttonStyle(MeetingQuietButtonStyle())
                        }
                        .font(.system(size: 12)).foregroundStyle(theme.cobalt)
                        .padding(.horizontal, 32).padding(.vertical, 8)
                        .background(theme.cobaltSoft.opacity(0.4))
                        .id(proposal.id)
                    }
                    if let draft, !draft.isCurrent(for: transcript) {
                        Text(
                            french
                                ? "Les sources ont changé. Ce compte rendu est à revérifier."
                                : "The sources changed. Review this report again."
                        )
                        .font(.system(size: 12)).foregroundStyle(theme.warning)
                        .padding(.horizontal, 32).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ZStack(alignment: .topLeading) {
                        MeetingRichEditor(
                            document: Binding(get: { content }, set: save), controller: editor)
                        if content.blocks.allSatisfy({ $0.text.isEmpty }) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(
                                    generating
                                        ? (french
                                            ? "Votre compte rendu prend forme…"
                                            : "Your report is taking shape…")
                                        : (french
                                            ? "Commencez à écrire, ou laissez VoxoL rédiger."
                                            : "Start writing, or let VoxoL draft your report.")
                                )
                                .font(.system(size: 16))
                                Text(
                                    french
                                        ? "Le document s’adapte aux sujets de votre réunion."
                                        : "The document follows the topics of your meeting."
                                )
                                .font(.system(size: 13))
                            }
                            .foregroundStyle(theme.secondaryInk).padding(40)
                            .allowsHitTesting(false)
                        }
                    }
                    sourceBar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surface)
                if showSources && geometry.size.width >= 980 {
                    Divider().overlay(theme.line)
                    MeetingSourcePanel(
                        transcript: transcript, sourceIDs: selectedBlock?.sourceTurnIDs ?? [],
                        french: french, close: { showSources = false }
                    )
                    .frame(width: min(340, geometry.size.width * 0.35))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { showSources && geometry.size.width < 980 },
                    set: { showSources = $0 })
            ) {
                MeetingSourcePanel(
                    transcript: transcript, sourceIDs: selectedBlock?.sourceTurnIDs ?? [],
                    french: french, close: { showSources = false }
                )
                .frame(width: 480, height: 620)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showSources)
        .sheet(isPresented: $showProposal) {
            if let draft, let proposal = draft.proposal {
                MeetingProposalSheet(
                    current: draft.content, proposed: proposal.document, french: french,
                    canAccept: (try? MeetingReportDraft.fingerprint(of: transcript))
                        == proposal.sourceFingerprint,
                    accept: {
                        meetings.acceptProposal(for: transcript.id); showProposal = false
                    },
                    discard: {
                        meetings.discardProposal(for: transcript.id); showProposal = false
                    })
            }
        }
        .sheet(isPresented: $showVersions) {
            MeetingVersionSheet(versions: draft?.versions ?? [], french: french) { version in
                meetings.restoreVersion(version, for: transcript.id)
                showVersions = false
            }
        }
        .task {
            if draft == nil { await meetings.createReport(for: transcript.id, french: french) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Text(french ? "COMPTE RENDU" : "MEETING REPORT")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.5)
                    .foregroundStyle(theme.secondaryInk)
                Spacer()
                Label(
                    saveCaption,
                    systemImage: meetings.saveState == .saved ? "checkmark.circle" : "circle.dotted"
                )
                .font(.system(size: 11)).foregroundStyle(theme.secondaryInk)
                Button {
                    showVersions = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(MeetingQuietButtonStyle())
                .help(french ? "Historique des versions" : "Version history")
            }
            TextField(
                french ? "Titre de la réunion" : "Meeting title",
                text: Binding(
                    get: { transcript.title },
                    set: { title in
                        meetings.updateMeeting(transcript.id) {
                            $0.title = String(title.prefix(240))
                        }
                    })
            )
            .textFieldStyle(.plain).font(.system(size: 29, weight: .semibold)).tracking(-0.7)
            HStack(spacing: 12) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { transcript.occurredAt },
                        set: { date in
                            meetings.updateMeeting(transcript.id) { $0.meetingDate = date }
                        }), displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden().datePickerStyle(.field).controlSize(.small)
                Text(SpeakerTranscript.timestamp(transcript.duration)).monospacedDigit()
                Label("\(transcript.speakerIDs.count)", systemImage: "person.2")
                Spacer(minLength: 0)
                Button {
                    meetings.markReviewed(draft?.reviewedAt == nil, for: transcript.id)
                } label: {
                    Label(
                        draft?.reviewedAt == nil
                            ? (french ? "À relire" : "To review") : (french ? "Relue" : "Reviewed"),
                        systemImage: draft?.reviewedAt == nil ? "circle" : "checkmark.circle.fill")
                }
                .buttonStyle(MeetingQuietButtonStyle())
                .disabled(content.blocks.isEmpty || generating)
            }
            .font(.system(size: 11)).foregroundStyle(theme.secondaryInk)
            HStack(spacing: 10) {
                TextField(
                    french ? "Projet (facultatif)" : "Project (optional)",
                    text: Binding(
                        get: { transcript.project ?? "" },
                        set: { text in
                            meetings.updateMeeting(transcript.id) {
                                $0.project = String(text.prefix(100))
                            }
                        })
                )
                .textFieldStyle(.plain).frame(maxWidth: 160)
                Spacer()
                Menu {
                    ForEach(MeetingReportStyle.allCases, id: \.self) { style in
                        Button(styleName(style)) { meetings.reportStyle = style }
                    }
                } label: {
                    Label(styleName(meetings.reportStyle), systemImage: "text.badge.star")
                }.menuStyle(.borderlessButton).fixedSize()
                Button {
                    meetings.generateReport(for: transcript.id, french: french)
                } label: {
                    Label(
                        generating
                            ? (french ? "Rédaction…" : "Writing…")
                            : (french ? "Rédiger" : "Write report"), systemImage: "sparkles")
                }
                .buttonStyle(MeetingQuietButtonStyle())
                .disabled(meetings.busy || !meetings.reportModelAvailable)
                Spacer(minLength: 0)
                if let event = transcript.calendarEvent {
                    Label(event.title, systemImage: "calendar").lineLimit(1)
                        .help(event.calendar)
                }
                Menu {
                    if transcript.calendarEvent != nil {
                        Button(french ? "Dissocier de l’événement" : "Unlink event") {
                            meetings.updateMeeting(transcript.id) { $0.calendarEvent = nil }
                        }
                    }
                    ForEach(meetings.calendar.events) { event in
                        Button(event.title) {
                            meetings.updateMeeting(transcript.id) {
                                $0.calendarEvent = event.link; $0.meetingDate = event.start
                            }
                        }
                    }
                    if !meetings.calendar.connected {
                        Button(french ? "Connecter le calendrier" : "Connect calendar") {
                            Task { await meetings.calendar.connect() }
                        }
                    }
                } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .font(.system(size: 12)).foregroundStyle(theme.secondaryInk)
            if let notice = content.coverageNotice {
                Text(notice).font(.system(size: 10)).foregroundStyle(theme.secondaryInk).lineLimit(
                    2)
            }
        }
        .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 18)
    }

    private var formattingBar: some View {
        HStack(spacing: 5) {
            Menu {
                ForEach(MeetingDocumentBlock.Kind.allCases, id: \.self) { kind in
                    Button(kindName(kind)) { editor.setKind(kind) }
                }
            } label: {
                Text(kindName(editor.kind)).frame(minWidth: 76, alignment: .leading)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Divider().frame(height: 16).padding(.horizontal, 6)
            formatButton("bold", help: french ? "Gras · ⌘B" : "Bold · ⌘B") { editor.toggle("bold") }
            formatButton("italic", help: french ? "Italique · ⌘I" : "Italic · ⌘I") {
                editor.toggle("italic")
            }
            formatButton("highlighter", help: french ? "Surligner" : "Highlight") {
                editor.toggle("highlight")
            }
            formatButton("link", help: french ? "Lien" : "Link") { showLink = true }
                .disabled(editor.selectedText.isEmpty)
                .popover(isPresented: $showLink) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(french ? "Lien du passage sélectionné" : "Link for selected text")
                        TextField("https://", text: $link).textFieldStyle(.roundedBorder)
                        HStack {
                            Button(french ? "Retirer" : "Remove") {
                                editor.setLink(""); showLink = false
                            }
                            Spacer()
                            Button(french ? "Appliquer" : "Apply") {
                                editor.setLink(link); showLink = false
                            }
                        }
                    }.padding(18).frame(width: 320)
                }
            Menu {
                Button(french ? "Clarifier le passage" : "Clarify passage") {
                    rewrite("Make the prose clearer and more natural.")
                }
                Button(french ? "Raccourcir" : "Shorten") {
                    rewrite("Make the prose more concise without losing its important facts.")
                }
                Button(french ? "Développer depuis les sources" : "Expand from sources") {
                    rewrite(
                        "Explain this point in more detail, only when the supplied passages support those details."
                    )
                }
            } label: {
                Image(systemName: "sparkles")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(
                meetings.busy || !meetings.reportModelAvailable
                    || selectedBlock?.sourceTurnIDs.isEmpty != false
            )
            .help(french ? "Réécrire le paragraphe sélectionné" : "Rewrite the selected paragraph")
            Divider().frame(height: 16).padding(.horizontal, 6)
            formatButton(
                "arrow.uturn.backward", help: french ? "Annuler" : "Undo", action: editor.undo)
            formatButton(
                "arrow.uturn.forward", help: french ? "Rétablir" : "Redo", action: editor.redo)
            Spacer(minLength: 4)
            Menu {
                ForEach(content.blocks.filter { [.heading, .subheading].contains($0.kind) }) {
                    block in
                    Button(block.text) { editor.scroll(to: block.id) }
                }
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .menuStyle(.borderlessButton).fixedSize().help(french ? "Sommaire" : "Outline")
            Button {
                showSources.toggle()
            } label: {
                Label(french ? "Sources" : "Sources", systemImage: "sidebar.right")
            }.buttonStyle(MeetingQuietButtonStyle())
        }
        .font(.system(size: 12)).padding(.horizontal, 28).padding(.vertical, 6)
        .background(theme.canvas.opacity(0.65))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private var sourceBar: some View {
        HStack(spacing: 10) {
            if let block = selectedBlock, !block.sourceTurnIDs.isEmpty {
                Button {
                    showSources = true
                } label: {
                    Label(
                        french ? "Sources de ce passage" : "Sources for this passage",
                        systemImage: "quote.bubble")
                }.buttonStyle(.plain).foregroundStyle(theme.cobalt)
                if block.sourcesNeedReview {
                    Text(french ? "Texte modifié · à revérifier" : "Edited text · review sources")
                        .foregroundStyle(theme.warning)
                }
            } else {
                Text(
                    french
                        ? "Sélectionnez un passage pour retrouver ses sources."
                        : "Select a passage to find its sources."
                ).foregroundStyle(theme.secondaryInk)
            }
            Spacer()
            Text(
                french
                    ? "\(content.plainText.split(whereSeparator: \.isWhitespace).count) mots"
                    : "\(content.plainText.split(whereSeparator: \.isWhitespace).count) words"
            )
            .foregroundStyle(theme.secondaryInk)
        }
        .font(.system(size: 10)).padding(.horizontal, 32).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private func formatButton(_ icon: String, help: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) { Image(systemName: icon).frame(width: 24, height: 26) }
            .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private func rewrite(_ instruction: String) {
        guard let block = selectedBlock else { return }
        meetings.rewritePassage(
            block.id, in: transcript.id, instruction: instruction, french: french)
    }

    private func save(_ document: MeetingDocument) {
        meetings.updateDocument(document, for: transcript.id)
    }

    private var saveCaption: String {
        guard meetings.savedIDs.contains(transcript.id) else {
            return french ? "Cette session" : "This session"
        }
        return switch meetings.saveState {
        case .session: french ? "Cette session" : "This session"
        case .saving: french ? "Enregistrement…" : "Saving…"
        case .saved: french ? "Enregistré" : "Saved"
        case .failed: french ? "Échec de sauvegarde" : "Save failed"
        }
    }
    private func styleName(_ style: MeetingReportStyle) -> String {
        switch style {
        case .complete: french ? "Compte rendu complet" : "Full report"
        case .concise: french ? "Synthèse courte" : "Short summary"
        case .technical: french ? "Note technique" : "Technical brief"
        case .followup: french ? "Préparer le suivi" : "Follow-up brief"
        }
    }
    private func kindName(_ kind: MeetingDocumentBlock.Kind) -> String {
        switch kind {
        case .paragraph: french ? "Paragraphe" : "Paragraph"
        case .heading: french ? "Titre" : "Heading"
        case .subheading: french ? "Sous-titre" : "Subheading"
        case .bullet: french ? "Liste à puces" : "Bullet list"
        case .numbered: french ? "Liste numérotée" : "Numbered list"
        case .task: french ? "Action" : "Task"
        case .quote: french ? "Citation" : "Quote"
        }
    }
}

private struct MeetingDocumentOutline: View {
    @Environment(VoxoLTheme.self) private var theme
    let document: MeetingDocument
    let selected: UUID?
    let french: Bool
    let navigate: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Text(french ? "DANS CE DOCUMENT" : "IN THIS DOCUMENT")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.1)
                    .foregroundStyle(theme.secondaryInk).padding(.bottom, 12)
                ForEach(document.blocks.filter { [.heading, .subheading].contains($0.kind) }) {
                    block in
                    Button {
                        navigate(block.id)
                    } label: {
                        Text(block.text).font(
                            .system(size: 12, weight: block.kind == .heading ? .medium : .regular)
                        )
                        .foregroundStyle(selected == block.id ? theme.cobalt : theme.secondaryInk)
                        .multilineTextAlignment(.leading).lineLimit(3)
                        .padding(.leading, block.kind == .subheading ? 10 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }
                if document.blocks.filter({ $0.kind == .heading }).isEmpty {
                    Text(
                        french ? "Vos titres apparaîtront ici." : "Your headings will appear here."
                    )
                    .font(.system(size: 12)).foregroundStyle(theme.secondaryInk)
                }
            }.padding(.horizontal, 20).padding(.vertical, 30)
        }.background(theme.canvas)
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
        VStack(spacing: 18) {
            HStack {
                Text(french ? "Comparer les versions" : "Compare versions").font(
                    .system(size: 23, weight: .semibold))
                Spacer()
                Button(french ? "Fermer" : "Close") { dismiss() }.buttonStyle(
                    MeetingQuietButtonStyle())
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text(french ? "Votre document" : "Your document").font(
                        .system(size: 12, weight: .semibold))
                    MeetingRichEditor(
                        document: .constant(current), controller: left, editable: false)
                }
                Divider()
                VStack(alignment: .leading) {
                    Text(french ? "Nouveau brouillon" : "New draft").font(
                        .system(size: 12, weight: .semibold))
                    MeetingRichEditor(
                        document: .constant(proposed), controller: right, editable: false)
                }
            }
            HStack {
                Text(
                    french
                        ? "Votre document actuel sera conservé dans les versions."
                        : "Your current document will remain in version history."
                )
                .font(.system(size: 11)).foregroundStyle(theme.secondaryInk)
                Spacer()
                Button(french ? "Écarter" : "Discard", action: discard).buttonStyle(
                    MeetingQuietButtonStyle())
                Button(french ? "Utiliser cette version" : "Use this version", action: accept)
                    .buttonStyle(MeetingAccentButtonStyle()).disabled(!canAccept)
            }
            if !canAccept {
                Text(
                    french
                        ? "La transcription a changé depuis ce brouillon. Relancez la rédaction."
                        : "The transcript changed after this draft. Generate a new one."
                )
                .font(.system(size: 12)).foregroundStyle(theme.warning)
            }
        }.padding(26).frame(minWidth: 760, idealWidth: 960, minHeight: 560, idealHeight: 680)
            .background(theme.surface).foregroundStyle(theme.ink)
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
        VStack(spacing: 16) {
            HStack {
                Text(french ? "Versions du document" : "Document versions").font(
                    .system(size: 22, weight: .semibold))
                Spacer()
                Button(french ? "Fermer" : "Close") { dismiss() }.buttonStyle(
                    MeetingQuietButtonStyle())
            }
            if let version {
                Picker(
                    french ? "Version" : "Version",
                    selection: Binding(get: { version.id }, set: { selected = $0 })
                ) {
                    ForEach(versions.reversed()) { item in Text(item.date.formatted()).tag(item.id)
                    }
                }
                MeetingRichEditor(
                    document: .constant(version.document), controller: editor, editable: false)
                HStack {
                    Text(
                        french
                            ? "La restauration conserve aussi le document actuel."
                            : "Restoring also preserves your current document."
                    )
                    .font(.system(size: 11)).foregroundStyle(theme.secondaryInk)
                    Spacer()
                    Button(french ? "Restaurer" : "Restore") { restore(version) }
                        .buttonStyle(MeetingAccentButtonStyle())
                }
            } else {
                ContentUnavailableView(
                    french ? "Aucune version précédente" : "No previous versions",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        french
                            ? "Vos modifications et régénérations créeront des versions."
                            : "Editing and regenerating will create versions."))
            }
        }.padding(26).frame(width: 740, height: 600).background(theme.surface).foregroundStyle(
            theme.ink)
    }
}
