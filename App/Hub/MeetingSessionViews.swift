import AppKit
import EventKit
import SpeakerKit
import SwiftUI

/// A restrained motion vocabulary shared by live capture and local processing.
struct MeetingWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color: Color
    var level: Double? = nil
    var active = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || !active)) {
            context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<23, id: \.self) { index in
                    let envelope = 0.25 + 0.75 * sin(Double(index + 1) / 24 * .pi)
                    let wave =
                        reduceMotion
                        ? 0.55 : 0.35 + 0.65 * abs(sin(time * 2.8 + Double(index) * 0.55))
                    Capsule().fill(color.opacity(0.45 + envelope * 0.55))
                        .frame(
                            width: 3, height: 4 + 32 * envelope * (active ? (level ?? wave) : 0.08))
                }
            }
            .frame(height: 40)
        }
        .accessibilityHidden(true)
    }
}

struct MeetingProgressCard: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let french: Bool
    let label: String

    private var stage: Int {
        switch meetings.phase {
        case .transcribing: 1
        case .speakers: 2
        case .reporting: 3
        default: 0
        }
    }
    private var steps: [String] {
        french
            ? ["Audio", "Transcription", "Intervenants", "Compte rendu"]
            : ["Audio", "Transcript", "Speakers", "Report"]
    }
    private var measuredProgress: Double? {
        switch meetings.phase {
        case .speakers: meetings.speakerProgress
        case .reporting: meetings.reportProgress
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 20) {
                MeetingWaveform(color: theme.cobalt, active: meetings.phase != .cancelling)
                    .padding(10)
                    .background(
                        theme.cobaltSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: label)
                        .font(VoxoLTypography.font(size: 17, weight: .semibold))
                        .contentTransition(.opacity)
                    Text(
                        verbatim: meetings.phase == .reporting && !meetings.reportStage.isEmpty
                            ? meetings.reportStage
                            : meetings.processingTitle.isEmpty
                                ? (french
                                    ? "Tout se passe sur votre Mac."
                                    : "Everything stays on your Mac.")
                                : meetings.processingTitle
                    )
                    .font(VoxoLTypography.font(size: 12))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let start = meetings.processingStartedAt,
                    [.reading, .transcribing, .speakers, .reporting].contains(meetings.phase)
                {
                    Text(start, style: .timer)
                        .font(VoxoLTypography.font(size: 12)).monospacedDigit()
                        .foregroundStyle(theme.secondaryInk).fixedSize()
                        .accessibilityLabel(french ? "Temps écoulé" : "Elapsed time")
                }
                if meetings.phase != .checking {
                    Button(french ? "Annuler" : "Cancel") { meetings.cancel() }
                        .buttonStyle(MeetingQuietButtonStyle())
                        .disabled(meetings.phase == .cancelling)
                }
            }
            if [.reading, .transcribing, .speakers, .reporting].contains(meetings.phase) {
                HStack(spacing: 10) {
                    ForEach(steps.indices, id: \.self) { index in
                        HStack(spacing: 7) {
                            ZStack {
                                Circle().fill(index <= stage ? theme.cobalt : theme.selection)
                                if index < stage {
                                    Image(systemName: "checkmark").font(
                                        .system(size: 9, weight: .bold)
                                    ).foregroundStyle(.white)
                                } else if index == stage {
                                    ProgressView().controlSize(.mini).tint(.white).scaleEffect(0.7)
                                } else {
                                    Text("\(index + 1)").font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(theme.secondaryInk)
                                }
                            }.frame(width: 22, height: 22)
                            Text(verbatim: steps[index]).font(
                                VoxoLTypography.font(
                                    size: 12, weight: index == stage ? .semibold : .regular)
                            )
                            .foregroundStyle(index <= stage ? theme.ink : theme.secondaryInk)
                            if index < 3 {
                                Rectangle().fill(
                                    index < stage ? theme.cobalt.opacity(0.3) : theme.line
                                ).frame(height: 1)
                            }
                        }
                    }
                }
                if let progress = measuredProgress {
                    ProgressView(value: min(1, max(0, progress))).tint(theme.cobalt)
                        .accessibilityLabel(label)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(theme.cobalt)
                        .accessibilityLabel(label)
                }
            }
        }
        .padding(22)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.cobalt.opacity(0.2)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: meetings.phase)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: measuredProgress)
        .padding(.bottom, 20)
    }
}

struct MeetingRecordingSheet: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State var title: String
    @State private var source: MeetingRecorder.Source = .microphone
    let french: Bool
    var calendarEvent: MeetingCalendarLink? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Image(systemName: "waveform.circle.fill").font(.system(size: 32)).foregroundStyle(
                    theme.cobalt)
                Spacer()
                Button(french ? "Fermer" : "Close") { dismiss() }
                    .buttonStyle(MeetingQuietButtonStyle()).disabled(meetings.recorder.active)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(french ? "Place à la conversation." : "Make room for conversation.")
                    .font(VoxoLTypography.font(size: 29, weight: .semibold)).tracking(-0.6)
                Text(
                    french
                        ? "VoxoL garde le fil. Vous restez dans la discussion."
                        : "VoxoL keeps track. You stay in the conversation."
                )
                .font(VoxoLTypography.font(size: 14)).foregroundStyle(theme.secondaryInk)
            }
            TextField(french ? "Titre de la réunion" : "Meeting title", text: $title)
                .textFieldStyle(.plain).font(VoxoLTypography.font(size: 16))
                .padding(14).background(theme.canvas, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityLabel(french ? "Titre de la réunion" : "Meeting title")
            HStack(spacing: 12) {
                sourceCard(
                    .microphone, icon: "person.2", name: french ? "En présentiel" : "In person",
                    subtitle: french ? "Microphone" : "Microphone")
                sourceCard(
                    .call, icon: "laptopcomputer", name: french ? "En appel" : "On a call",
                    subtitle: french ? "Micro + son du Mac" : "Mic + Mac audio")
            }
            Text(
                french
                    ? "Informez les participants avant de commencer. L’audio est enregistré dans le fichier de votre choix ; la transcription se lance après l’arrêt. Durée maximale : 1 heure."
                    : "Let participants know before you start. Audio is saved to a file you choose; transcription starts after you stop. Maximum duration: 1 hour."
            )
            .font(VoxoLTypography.font(size: 12)).foregroundStyle(theme.secondaryInk).fixedSize(
                horizontal: false, vertical: true)
            if source == .call {
                Label(
                    french
                        ? "Le son des applications est capturé. Utilisez un casque pour éviter l’écho."
                        : "App audio is captured. Use headphones to avoid echo.",
                    systemImage: "headphones"
                )
                .font(VoxoLTypography.font(size: 12)).foregroundStyle(theme.secondaryInk)
            }
            if let failure = meetings.recorder.failure {
                Text(verbatim: failure).font(VoxoLTypography.font(size: 12)).foregroundStyle(
                    theme.recording)
            }
            HStack {
                Label(
                    french ? "Enregistrement local" : "Local recording", systemImage: "lock.shield"
                )
                .font(VoxoLTypography.font(size: 11)).foregroundStyle(theme.secondaryInk)
                Spacer()
                if meetings.recorder.state == .preparing { ProgressView().controlSize(.small) }
                Button(french ? "Choisir le fichier et démarrer" : "Choose file & start") {
                    Task {
                        await meetings.recorder.start(
                            title: title, source: source, event: calendarEvent)
                        if meetings.recorder.state == .recording { dismiss() }
                    }
                }
                .buttonStyle(MeetingAccentButtonStyle())
                .disabled(meetings.recorder.active)
            }
        }
        .padding(30).frame(width: 560).background(theme.surface).foregroundStyle(theme.ink)
        .interactiveDismissDisabled(meetings.recorder.active)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: source)
    }

    private func sourceCard(
        _ value: MeetingRecorder.Source, icon: String, name: String, subtitle: String
    ) -> some View {
        Button {
            source = value
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.system(size: 22))
                    Spacer()
                    Image(systemName: source == value ? "checkmark.circle.fill" : "circle")
                }
                Text(verbatim: name).font(VoxoLTypography.font(size: 16, weight: .semibold))
                Text(verbatim: subtitle).font(VoxoLTypography.font(size: 12)).foregroundStyle(
                    theme.secondaryInk)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(source == value ? theme.cobalt : theme.ink)
            .background(
                source == value ? theme.cobaltSoft.opacity(0.5) : theme.canvas,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14).stroke(
                    source == value ? theme.cobalt : theme.line))
        }
        .buttonStyle(.plain).disabled(meetings.recorder.active)
        .accessibilityAddTraits(source == value ? .isSelected : [])
    }
}

struct MeetingCaptureCard: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    @Environment(ModelInstallationStore.self) private var models
    let french: Bool

    var body: some View {
        let recorder = meetings.recorder
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                MeetingWaveform(
                    color: theme.recording, level: recorder.level,
                    active: recorder.state == .recording)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: recorder.title).font(
                        VoxoLTypography.font(size: 18, weight: .semibold)
                    ).lineLimit(1)
                    Text(verbatim: caption).font(VoxoLTypography.font(size: 12)).foregroundStyle(
                        theme.secondaryInk)
                }
                Spacer()
                Text(verbatim: SpeakerTranscript.timestamp(recorder.elapsed))
                    .font(VoxoLTypography.font(size: 25, weight: .medium)).monospacedDigit()
                if recorder.state == .recording || recorder.state == .paused {
                    Button {
                        recorder.togglePause()
                    } label: {
                        Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill")
                    }.buttonStyle(MeetingQuietButtonStyle())
                        .accessibilityLabel(
                            recorder.state == .paused ? (french ? "Reprendre" : "Resume") : "Pause")
                    Button(french ? "Terminer" : "Finish") {
                        Task {
                            await recorder.stop()
                            if recorder.failure == nil { transcribe() }
                        }
                    }.buttonStyle(MeetingAccentButtonStyle())
                } else if recorder.active {
                    ProgressView().controlSize(.small)
                }
            }
            if recorder.state == .recording || recorder.state == .paused {
                HStack(spacing: 12) {
                    TextField(
                        french ? "Une note pour vous…" : "A note for yourself…",
                        text: Binding(
                            get: { recorder.notes }, set: { recorder.notes = $0 }), axis: .vertical
                    )
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                    Button {
                        recorder.markMoment()
                    } label: {
                        Label(
                            french ? "Marquer ce moment" : "Bookmark moment",
                            systemImage: "bookmark")
                    }.buttonStyle(MeetingQuietButtonStyle())
                    if !recorder.markers.isEmpty {
                        Text("\(recorder.markers.count)").font(.system(size: 11)).foregroundStyle(
                            theme.secondaryInk)
                    }
                }.padding(12).background(theme.canvas, in: RoundedRectangle(cornerRadius: 10))
            }
            if let error = recorder.failure {
                Text(verbatim: error).font(VoxoLTypography.font(size: 12)).foregroundStyle(
                    theme.recording)
            }
            if let url = recorder.completedURL, !recorder.active {
                if !meetings.modelReady || models.installedDirectory(for: .asr) == nil {
                    Text(
                        french
                            ? "Votre fichier est conservé. Installez les modèles de transcription et de reconnaissance des voix pour créer le compte rendu."
                            : "Your file is saved. Install transcription and speaker recognition models to create the report."
                    )
                    .font(VoxoLTypography.font(size: 12)).foregroundStyle(theme.secondaryInk)
                }
                HStack {
                    Button(french ? "Afficher le fichier" : "Show file") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(MeetingQuietButtonStyle())
                    Spacer()
                    Button(french ? "Fermer" : "Dismiss") { recorder.dismissRecording() }
                        .buttonStyle(MeetingQuietButtonStyle()).disabled(meetings.busy)
                    Button(french ? "Transcrire" : "Transcribe") { transcribe() }
                        .buttonStyle(MeetingAccentButtonStyle())
                        .disabled(
                            meetings.busy || !meetings.modelReady
                                || models.installedDirectory(for: .asr) == nil)
                }
            }
        }
        .padding(22).background(theme.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.recording.opacity(0.25)))
        .padding(.bottom, 20)
    }

    private var caption: String {
        switch meetings.recorder.state {
        case .idle:
            if meetings.recorder.failure != nil {
                french
                    ? "Enregistrement interrompu · vérifiez le fichier"
                    : "Recording interrupted · check the file"
            } else {
                french ? "Audio enregistré sur votre Mac" : "Audio saved on your Mac"
            }
        case .preparing: french ? "Préparation de l’enregistrement…" : "Preparing recording…"
        case .recording: french ? "ENREGISTREMENT EN COURS" : "RECORDING IN PROGRESS"
        case .paused:
            french
                ? "En pause · le son n’est pas enregistré" : "Paused · audio is not being recorded"
        case .finishing: french ? "Finalisation du fichier…" : "Finishing recording…"
        }
    }

    private func transcribe() {
        guard let url = meetings.recorder.completedURL,
            let root = models.installedDirectory(for: .asr), meetings.modelReady
        else { return }
        meetings.transcribe(
            url: url, asrDirectory: root, french: french, title: meetings.recorder.title)
    }
}
