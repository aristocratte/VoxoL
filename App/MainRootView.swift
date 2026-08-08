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
        .task {
            await permissions.monitorChanges()
        }
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }
}

#Preview("Main root") {
    MainRootView()
        .frame(width: 1120, height: 760)
}
