import SwiftUI

struct MainRootView: View {
    @State private var theme = VoxoLTheme()
    @State private var permissions = PermissionCoordinator.shared
    @State private var dictationSession = DictationSessionCoordinator.shared
    @State private var modelInstallation = ModelInstallationStore()
    @State private var transcripts = TranscriptStore()
    @State private var personalization = PersonalizationStore()
    @AppStorage("voxol.hasCompletedPreflight") private var hasCompletedPreflight = false
    @AppStorage("voxol.interfaceLanguage") private var languageCode = AppLanguage.preferred.rawValue
    @AppStorage("voxol.dictationLanguage") private var dictationLanguageCode =
        DictationLanguagePreference.preferred.rawValue
    /// Empty means "follow the system default input", which is the shipping behaviour.
    @AppStorage("voxol.inputDeviceUID") private var inputDeviceUID = ""
    @AppStorage("voxol.voiceProcessingMode") private var voiceProcessingMode = "disabled"
    /// The version that ran last, so an update can be told from a first launch.
    @AppStorage("voxol.lastLaunchedVersion") private var lastLaunchedVersion = ""
    @State private var releaseNotes: ReleaseNotes.Entry?

    var body: some View {
        Group {
            if hasCompletedPreflight {
                HubView(
                    languageCode: $languageCode,
                    replayPreflight: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            hasCompletedPreflight = false
                        }
                    }
                )
            } else {
                PreflightView(
                    languageCode: $languageCode,
                    previewCapsule: {
                        VoiceCapsuleController.shared.playPreview()
                    },
                    complete: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            hasCompletedPreflight = true
                        }
                    }
                )
            }
        }
        .blur(radius: releaseNotes == nil ? 0 : 9)
        .overlay {
            if let entry = releaseNotes {
                ZStack {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .onTapGesture { dismissReleaseNotes() }
                    ReleaseNotesCard(entry: entry) { dismissReleaseNotes() }
                }
                .transition(.opacity)
            }
        }
        .task { presentReleaseNotesAfterUpdate() }
        .environment(theme)
        .environment(permissions)
        .environment(dictationSession)
        .environment(modelInstallation)
        .environment(transcripts)
        .environment(personalization)
        .environment(\.locale, selectedLanguage.locale)
        .tint(theme.ink)
        .task {
            async let modelLoad: Void = modelInstallation.load()
            async let transcriptLoad: Void = transcripts.load()
            async let personalizationLoad: Void = personalization.load()
            _ = await (modelLoad, transcriptLoad, personalizationLoad)
        }
        .task(id: modelInstallation.installedCount) {
            if let modelRoot = modelInstallation.installedDirectory(for: .asr) {
                dictationSession.configureASR(
                    modelRoot: modelRoot,
                    transcriptStore: transcripts
                )
            }
            dictationSession.configureTextProcessing(
                modelRoot: modelInstallation.installedDirectory(for: .polisher),
                personalizationStore: personalization
            )
        }
        .task(id: dictationLanguageCode) {
            let preference =
                DictationLanguagePreference(
                    rawValue: dictationLanguageCode
                )
                ?? .preferred
            dictationSession.configureDictationLanguage(preference)
        }
        .task(id: inputDeviceUID) {
            dictationSession.configureInputDevice(uid: inputDeviceUID)
        }
        .task(id: voiceProcessingMode) {
            dictationSession.configureVoiceProcessing(rawMode: voiceProcessingMode)
        }
        .task {
            await permissions.monitorChanges()
        }
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    /// Shows the notes once, when the running version differs from the one that
    /// ran last.
    ///
    /// A first install is deliberately silent: someone opening the app for the
    /// first time has not just fixed anything, and a changelog is the wrong
    /// first screen. The version is still recorded, so the *next* update is the
    /// one that gets the card.
    private func presentReleaseNotesAfterUpdate() {
        let current = BugReportComposer.Environment.current().applicationVersion
        guard lastLaunchedVersion != current else { return }
        // An empty stored version does not mean a first install: builds before
        // this feature never recorded one, so every user updating from them
        // arrives here empty-handed — precisely the update the card exists to
        // explain. A completed preflight is the proof the app ran before.
        let isUpdate = !lastLaunchedVersion.isEmpty || hasCompletedPreflight
        guard isUpdate, let entry = ReleaseNotes.entry(for: current) else {
            lastLaunchedVersion = current
            return
        }
        withAnimation(.easeOut(duration: 0.22)) {
            releaseNotes = entry
        }
    }

    private func dismissReleaseNotes() {
        // Recorded on dismissal rather than on display, so a crash or a force
        // quit while the card is up does not consume the one time it shows.
        lastLaunchedVersion = BugReportComposer.Environment.current().applicationVersion
        withAnimation(.easeOut(duration: 0.18)) {
            releaseNotes = nil
        }
    }
}

#Preview("Main root") {
    MainRootView()
        .frame(width: 1120, height: 760)
}
