import AppKit
import SpeakerKit
import SwiftUI

// Starting a recording, the meeting while it is recorded, and the work that follows the stop.

/// Where the local processing is, in one line: the step, its measured progress, the time spent.
struct MeetingProgressLine: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings

    let french: Bool

    private var label: String {
        switch meetings.phase {
        case .idle: tr(french, "Prêt", "Ready")
        case .checking: tr(french, "Vérification de la reconnaissance des voix…", "Checking speaker recognition…")
        case .downloading: tr(french, "Installation de la reconnaissance des voix…", "Installing speaker recognition…")
        case .reading: tr(french, "Préparation de l’audio…", "Preparing the audio…")
        case .transcribing: tr(french, "Transcription de la conversation…", "Transcribing the conversation…")
        case .speakers: tr(french, "Identification des voix…", "Identifying the voices…")
        case .reporting:
            meetings.reportStage.isEmpty
                ? (tr(french, "Rédaction du compte rendu…", "Writing the report…")) : meetings.reportStage
        case .cancelling: tr(french, "Annulation…", "Cancelling…")
        }
    }

    private var measured: Double? {
        switch meetings.phase {
        case .speakers: meetings.speakerProgress
        case .reporting: meetings.reportProgress
        default: nil
        }
    }

    var body: some View {
        HubPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: label)
                            .font(VoxoLTypography.font(size: 13, weight: .medium))
                            .foregroundStyle(theme.ink)
                            .contentTransition(.opacity)
                        if !meetings.processingTitle.isEmpty {
                            Text(verbatim: meetings.processingTitle)
                                .font(VoxoLTypography.font(size: 12))
                                .foregroundStyle(theme.secondaryInk)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if let start = meetings.processingStartedAt {
                        Text(start, style: .timer)
                            .font(VoxoLTypography.font(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryInk)
                            .fixedSize()
                    }
                    if meetings.phase != .checking {
                        Button(tr(french, "Annuler", "Cancel")) { meetings.cancel() }
                            .buttonStyle(HubButtonStyle(kind: .onWell))
                            .disabled(meetings.phase == .cancelling)
                    }
                }
                if let measured {
                    ProgressView(value: min(1, max(0, measured))).tint(theme.cobalt)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(theme.cobalt)
                }
            }
            .padding(.vertical, 12)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Starts a recording: a title, in person or on a call, then the file it is saved to.
struct MeetingRecordingSheet: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    @Environment(\.dismiss) private var dismiss

    @State var title: String
    @State private var source: MeetingRecorder.Source = .microphone
    let french: Bool
    var calendarEvent: MeetingCalendarLink? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr(french, "Enregistrer une réunion", "Record a meeting"))
                .font(VoxoLTypography.font(size: 17, weight: .semibold))
                .foregroundStyle(theme.ink)

            HubPanel {
                HubField(verbatim: tr(french, "Titre", "Title")) {
                    TextField(tr(french, "Titre de la réunion", "Meeting title"), text: $title)
                        .textFieldStyle(.plain)
                        .font(VoxoLTypography.font(size: 13))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 240)
                }
                HubField(
                    verbatim: tr(french, "Son", "Sound"),
                    detail: source == .call
                        ? Text(tr(french, "Micro et son du Mac. Un casque évite l’écho.", "Mic and Mac audio. Headphones avoid echo."))
                        : Text(tr(french, "Le micro de ce Mac.", "This Mac’s microphone."))
                ) {
                    HubSegmented(
                        options: MeetingRecorder.Source.allCases, selection: $source, track: theme.selection
                    ) {
                        Text($0 == .microphone ? (tr(french, "En présentiel", "In person")) : (tr(french, "En appel", "On a call")))
                    }
                    .disabled(meetings.recorder.active)
                }
            }
            .padding(.top, 16)

            Text(
                tr(french, "Préviens les participants avant de commencer. Une heure au plus ; la transcription démarre à l’arrêt.", "Tell participants before you start. One hour at most; transcription starts when you stop.")
            )
            .font(VoxoLTypography.font(size: 12))
            .foregroundStyle(theme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)

            if let failure = meetings.recorder.failure {
                Text(verbatim: failure)
                    .font(VoxoLTypography.font(size: 12))
                    .foregroundStyle(theme.warning)
                    .padding(.top, 8)
            }

            HStack {
                if meetings.recorder.state == .preparing { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr(french, "Annuler", "Cancel")) { dismiss() }
                    .buttonStyle(HubButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(meetings.recorder.active)
                Button(tr(french, "Choisir le fichier et démarrer", "Choose file and start")) {
                    Task {
                        await meetings.recorder.start(title: title, source: source, event: calendarEvent)
                        if meetings.recorder.state == .recording { dismiss() }
                    }
                }
                .buttonStyle(HubButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(meetings.recorder.active)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 520)
        .background(theme.surface)
        .interactiveDismissDisabled(meetings.recorder.active)
    }
}

/// The meeting while it is recorded: its sound printed as it comes in, and notes kept at their
/// moment. After the stop, the same page offers to transcribe and shows the work in progress.
struct MeetingLiveView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    @Environment(ModelInstallationStore.self) private var models

    let french: Bool
    let showList: () -> Void

    @State private var levels: [Double] = []
    @State private var draft = ""
    @FocusState private var composing: Bool

    private var recorder: MeetingRecorder { meetings.recorder }
    private var live: Bool { recorder.state == .recording || recorder.state == .paused }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: recorder.title.isEmpty ? (tr(french, "Nouvelle réunion", "New meeting")) : recorder.title)
                        .font(VoxoLTypography.serif(size: 30, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 10) {
                        Circle()
                            .fill(recorder.state == .recording ? theme.coral : theme.secondaryInk)
                            .frame(width: 8, height: 8)
                        Text(verbatim: stateLine)
                            .font(VoxoLTypography.font(size: 13, weight: .medium))
                            .foregroundStyle(theme.ink)
                            .monospacedDigit()
                    }
                    .padding(.top, 8)

                    ConversationPrint(
                        envelope: levels.isEmpty ? [0] : levels,
                        duration: 1,
                        tint: theme.coral
                    )
                    .frame(height: 52)
                    .padding(.top, 20)

                    if let failure = recorder.failure {
                        Text(verbatim: failure)
                            .font(VoxoLTypography.font(size: 13))
                            .foregroundStyle(theme.warning)
                            .padding(.top, 14)
                    }

                    notes.padding(.top, 24)

                    if !live, recorder.completedURL != nil {
                        afterStop.padding(.top, 24)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.leading, 56)
                .padding(.horizontal, 32)
                .padding(.top, 12)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            // The print fills from the left as the meeting goes on, one column per half second,
            // and keeps its density by halving its resolution when it gets long.
            while !Task.isCancelled {
                if recorder.state == .recording {
                    levels.append(min(1, 0.12 + recorder.level * 1.1))
                    if levels.count > 480 {
                        levels = stride(from: 0, to: levels.count - 1, by: 2).map {
                            max(levels[$0], levels[$0 + 1])
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button(action: showList) {
                Label(tr(french, "Réunions", "Meetings"), systemImage: "chevron.left")
            }
            .buttonStyle(HubButtonStyle(kind: .ghost))
            Spacer()
            if live {
                Button(tr(french, "Marquer ce moment", "Mark this moment")) { recorder.markMoment() }
                    .buttonStyle(HubButtonStyle(kind: .secondary))
                    .keyboardShortcut("m", modifiers: .command)
                Button(recorder.state == .paused ? (tr(french, "Reprendre", "Resume")) : "Pause") {
                    recorder.togglePause()
                }
                .buttonStyle(HubButtonStyle(kind: .secondary))
                Button(tr(french, "Arrêter", "Stop")) {
                    Task {
                        await recorder.stop()
                        if recorder.failure == nil { transcribe() }
                    }
                }
                .buttonStyle(HubButtonStyle(kind: .primary))
            } else if recorder.active {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.leading, 10).padding(.trailing, 12)
        .frame(height: 48)
    }

    private var stateLine: String {
        let time = MeetingTime.short(recorder.elapsed)
        switch recorder.state {
        case .recording: return tr(french, "Enregistrement · \(time)", "Recording · \(time)")
        case .paused: return tr(french, "En pause · \(time)", "Paused · \(time)")
        case .preparing: return tr(french, "Préparation…", "Preparing…")
        case .finishing: return tr(french, "Finalisation du fichier…", "Finishing the file…")
        case .idle:
            return recorder.failure == nil
                ? (tr(french, "Audio enregistré · \(time)", "Audio saved · \(time)"))
                : (tr(french, "Enregistrement interrompu", "Recording interrupted"))
        }
    }

    /// Notes are kept at the moment they are written; a marked moment is a note without words.
    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(recorder.markers) { marker in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: MeetingTime.short(marker.time))
                        .font(VoxoLTypography.font(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(theme.secondaryInk)
                        .frame(width: 44, alignment: .trailing)
                    if marker.note.isEmpty {
                        Text(tr(french, "Moment marqué", "Marked moment"))
                            .font(VoxoLTypography.font(size: 13))
                            .foregroundStyle(theme.secondaryInk)
                    } else {
                        Text(verbatim: marker.note)
                            .font(VoxoLTypography.serif(size: 16))
                            .foregroundStyle(theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, -56)
            }
            if live {
                HStack(alignment: .center, spacing: 12) {
                    Text(verbatim: MeetingTime.short(recorder.elapsed))
                        .font(VoxoLTypography.font(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(theme.coral)
                        .frame(width: 44, alignment: .trailing)
                    HStack {
                        TextField(tr(french, "Écris une note…", "Write a note…"), text: $draft)
                            .textFieldStyle(.plain)
                            .font(VoxoLTypography.serif(size: 16))
                            .focused($composing)
                            .onSubmit {
                                recorder.addNote(draft)
                                draft = ""
                                composing = true
                            }
                        HubKeycap(label: "⏎", fill: theme.surface)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(.leading, -56)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var afterStop: some View {
        if meetings.phase != .idle {
            MeetingProgressLine(french: french)
        } else if let url = recorder.completedURL {
            HubPanel {
                VStack(alignment: .leading, spacing: 10) {
                    if !meetings.modelReady || models.installedDirectory(for: .asr) == nil {
                        Text(
                            tr(french, "Le fichier est conservé. Installe les moteurs de transcription et de reconnaissance des voix pour créer le compte rendu.", "The file is kept. Install the transcription and speaker recognition engines to create the report.")
                        )
                        .font(VoxoLTypography.font(size: 13))
                        .foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        Button(tr(french, "Transcrire", "Transcribe"), action: transcribe)
                            .buttonStyle(HubButtonStyle(kind: .primary))
                            .disabled(meetings.busy || !meetings.modelReady || models.installedDirectory(for: .asr) == nil)
                        Button(tr(french, "Afficher le fichier", "Show file")) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(HubButtonStyle(kind: .onWell))
                        Spacer()
                        Button(tr(french, "Fermer", "Dismiss")) { recorder.dismissRecording() }
                            .buttonStyle(HubButtonStyle(kind: .ghost))
                            .disabled(meetings.busy)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func transcribe() {
        guard let url = recorder.completedURL, let root = models.installedDirectory(for: .asr),
            meetings.modelReady
        else { return }
        meetings.transcribe(url: url, asrDirectory: root, french: french, title: recorder.title)
    }
}
