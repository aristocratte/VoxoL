import AppKit
import SwiftUI

struct MenuBarView: View {
    @State private var theme = VoxoLTheme()
    @State private var dictationSession = DictationSessionCoordinator.shared
    @AppStorage("voxol.interfaceLanguage") private var languageCode = AppLanguage.preferred.rawValue

    let openMainWindow: () -> Void
    let previewCapsule: () -> Void

    var body: some View {
        MenuBarContent(
            openMainWindow: openMainWindow,
            previewCapsule: previewCapsule
        )
        .environment(theme)
        .environment(dictationSession)
        .environment(\.locale, selectedLanguage.locale)
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }
}

private struct MenuBarContent: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(DictationSessionCoordinator.self) private var dictationSession

    let openMainWindow: () -> Void
    let previewCapsule: () -> Void

    @AppStorage("voxol.privateMode") private var privateMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VoxoLMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("VoxoL")
                        .font(.headline)
                    Text(runtimeTitle)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                }
                Spacer()
                StatusPill(title: runtimePillTitle, symbol: runtimePillSymbol)
            }

            Divider()

            Toggle("Private mode", isOn: $privateMode)

            HStack {
                Text("Dictate")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
                Spacer()
                KeyboardShortcutBadge(keys: "⌥ Space")
            }

            HStack {
                Text("Insertion test")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
                Spacer()
                KeyboardShortcutBadge(keys: "⌥ ⇧ Space")
            }

            Button(action: previewCapsule) {
                Label("Preview capsule", systemImage: "waveform")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: openMainWindow) {
                Label("Open VoxoL", systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keyboardShortcut("o")

            Divider()

            Button("Quit VoxoL") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 300)
        .background(theme.surface)
    }

    private var runtimeTitle: LocalizedStringKey {
        switch dictationSession.state {
        case .waitingForInputMonitoring:
            "Permission setup required"
        case .listening:
            "Capturing locally"
        case .speechDetected:
            "Speech detected"
        case .transcribing:
            "Transcribing locally"
        case .polishing:
            "Refining locally"
        case .inserting:
            "Inserting text"
        case .captureNeedsModel:
            "Transcription model pending"
        case .noSpeech:
            "No speech detected"
        case .insertionSucceeded:
            "Insertion complete"
        case .copiedForManualPaste:
            "Copied · press ⌘V"
        case .failed:
            "Check permissions"
        case .ready:
            "Ready in every app"
        }
    }

    private var runtimePillTitle: LocalizedStringKey {
        switch dictationSession.state {
        case .waitingForInputMonitoring, .failed:
            "Setup"
        case .listening, .speechDetected, .transcribing, .polishing:
            "Live"
        case .inserting:
            "Insert"
        case .captureNeedsModel:
            "Model"
        case .noSpeech, .insertionSucceeded, .ready:
            "Local"
        case .copiedForManualPaste:
            "Paste"
        }
    }

    private var runtimePillSymbol: String {
        switch dictationSession.state {
        case .waitingForInputMonitoring, .failed:
            "exclamationmark.circle"
        case .listening, .speechDetected, .transcribing, .polishing:
            "waveform"
        case .inserting:
            "text.cursor"
        case .captureNeedsModel:
            "arrow.down.circle"
        case .noSpeech, .insertionSucceeded, .ready:
            "lock"
        case .copiedForManualPaste:
            "doc.on.clipboard"
        }
    }
}

#Preview("Menu bar") {
    MenuBarView(openMainWindow: {}, previewCapsule: {})
}
