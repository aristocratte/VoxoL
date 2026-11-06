import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Hashable {
    case general
    case dictation
    case engines
    case permissions
    case privacy
    case about

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .engines: "Engines"
        case .permissions: "Authorizations"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }
}

struct SettingsView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(ModelInstallationStore.self) private var models
    @Environment(PermissionCoordinator.self) private var permissions
    @Environment(PersonalizationStore.self) private var personalization
    @Environment(DictationSessionCoordinator.self) private var dictationSession
    @Environment(\.locale) private var locale

    @Binding var languageCode: String
    @Binding var section: SettingsSection
    let replayPreflight: () -> Void

    @AppStorage("voxol.activationMode") private var activationMode = ActivationMode.hold
    @AppStorage("voxol.dictationShortcut") private var shortcut = DictationShortcut.optionSpace
    @AppStorage("voxol.dictationLanguage") private var language =
        DictationLanguagePreference.preferred
    @AppStorage("voxol.cleanupMode") private var cleanup = DictationCleanupMode.faithful
    @AppStorage("voxol.inputDeviceUID") private var inputDeviceUID = ""
    @AppStorage("voxol.privateMode") private var privateMode = false
    @AppStorage("voxol.historyEnabled") private var historyEnabled = true
    @AppStorage("voxol.contextEnabled") private var contextEnabled = true
    @AppStorage("voxol.learningEnabled") private var learningEnabled = true
    @AppStorage("voxol.correctionCapture") private var correctionCapture = false

    var body: some View {
        HubPage {
            HubPageHeader(title: "Settings")
            HubSegmented(options: SettingsSection.allCases, selection: $section) {
                Text($0.title)
            }
            .padding(.top, 16)

            Group {
                switch section {
                case .general: general
                case .dictation: dictation
                case .engines: engines
                case .permissions: permissionsSection
                case .privacy: privacy
                case .about: about
                }
            }
            .id(section)
            .transition(.opacity)
        }
        .editorialDropdownHost()
        .onChange(of: privateMode) { _, enabled in
            if enabled {
                historyEnabled = false
                learningEnabled = false
            }
        }
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubGroupTitle(title: "Interface")
            HubPanel {
                HubField(title: "Language") {
                    EditorialDropdown(
                        options: AppLanguage.allCases.map {
                            EditorialDropdownOption(id: $0.rawValue, verbatim: $0.displayName)
                        },
                        selectedID: languageCode,
                        select: { languageCode = $0 }
                    )
                }
                HubField(title: "Guided setup", detail: Text("Replay the tour and re-check this Mac")) {
                    Button("Replay", action: replayPreflight)
                        .buttonStyle(HubButtonStyle(kind: .onWell))
                }
            }
        }
    }

    // MARK: Dictation

    private var dictation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubGroupTitle(title: "Trigger")
            HubPanel {
                HubField(title: "Shortcut") {
                    EditorialDropdown(
                        options: DictationShortcut.allCases.map {
                            EditorialDropdownOption(
                                id: $0.rawValue, verbatim: String($0.localizedTitle, in: locale))
                        },
                        selectedID: shortcut.rawValue,
                        select: { shortcut = DictationShortcut(rawValue: $0) ?? .optionSpace }
                    )
                }
                HubField(title: "Mode") {
                    HubSegmented(
                        options: ActivationMode.allCases, selection: $activationMode,
                        track: theme.selection
                    ) {
                        Text($0 == .hold ? "Hold" : "Press")
                    }
                }
            }

            HubGroupTitle(title: "Sound")
            HubPanel {
                HubField(title: "Microphone") {
                    AudioInputPicker(selectedUID: $inputDeviceUID, compact: true)
                }
                HubField(title: "Dictation language") {
                    EditorialDropdown(
                        options: DictationLanguagePreference.allCases.map {
                            EditorialDropdownOption(id: $0.rawValue, $0.title)
                        },
                        selectedID: language.rawValue,
                        select: { language = DictationLanguagePreference(rawValue: $0) ?? .preferred }
                    )
                }
            }

            HubGroupTitle(title: "Text preparation")
            HubPanel {
                HubField(title: "Mode") {
                    HubSegmented(
                        options: [.faithful, .rewrite, .raw], selection: $cleanup,
                        track: theme.selection
                    ) {
                        Text($0.title)
                    }
                }
                preparationPreview
                    .padding(.bottom, 14)
            }
        }
    }

    /// What the chosen preparation does to one sentence, so the choice is not a guess.
    private var preparationPreview: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Heard")
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.secondaryInk)
                Text("“uh so we meet wednesday around ten for the budget”")
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.secondaryInk)
            }
            GridRow {
                Text("Written")
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.secondaryInk)
                Text(preparedExample)
                    .font(VoxoLTypography.serif(size: 16))
                    .foregroundStyle(theme.ink)
                    .contentTransition(.opacity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(EditorialMotion.soft, value: cleanup)
    }

    private var preparedExample: LocalizedStringKey {
        switch cleanup {
        case .faithful: "We meet Wednesday around 10 for the budget."
        case .rewrite: "Meeting on Wednesday at 10 to review the budget."
        case .raw: "uh so we meet wednesday around ten for the budget"
        }
    }

    // MARK: Engines

    private var engines: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubGroupTitle(title: "On this Mac")
            HubPanel {
                if models.items.isEmpty {
                    HubField(
                        title: "Local engines",
                        detail: models.manifestLoadFailed
                            ? Text("The verified manifest could not be loaded")
                            : Text("Checking verified artifacts…")
                    ) {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    ForEach(models.items) { item in
                        HubField(
                            title: item.model.role == .asr ? "Parakeet" : "Qwen",
                            detail: Text(modelDetail(item))
                        ) {
                            modelAction(item)
                        }
                    }
                }
            }

            HubGroupTitle(title: "Diagnostics")
            HubPanel {
                HubField(
                    title: "Content-free diagnostics",
                    detail: Text("Timings and failure codes, without text or audio")
                ) {
                    Button("Export") { exportDiagnostics() }
                        .buttonStyle(HubButtonStyle(kind: .onWell))
                        .disabled(dictationSession.lastReport == nil)
                }
            }
        }
    }

    @ViewBuilder
    private func modelAction(_ item: ModelInstallationItem) -> some View {
        switch item.phase {
        case .loading, .verifying:
            ProgressView().controlSize(.small)
        case .downloading:
            Button("Pause") { models.pause(item.id) }
                .buttonStyle(HubButtonStyle(kind: .onWell))
        case .readyToDownload, .paused, .failed:
            Button(item.phase == .failed ? "Retry" : "Install") { models.install(item.id) }
                .buttonStyle(HubButtonStyle(kind: .onWell))
        case .installed:
            Label("Ready", systemImage: "checkmark")
                .font(VoxoLTypography.font(size: 13, weight: .medium))
                .foregroundStyle(theme.success)
        case .awaitingVerifiedArtifact:
            Text("Unavailable")
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.secondaryInk)
        }
    }

    private func modelDetail(_ item: ModelInstallationItem) -> LocalizedStringKey {
        switch item.phase {
        case .loading: "Checking the local artifact"
        case .awaitingVerifiedArtifact: "No release artifact has passed verification"
        case .readyToDownload: "Verified artifact ready to install"
        case .downloading:
            LocalizedStringKey("Downloading · \(Int((item.progress * 100).rounded())) %")
        case .paused:
            LocalizedStringKey("Paused · \(Int((item.progress * 100).rounded())) %")
        case .verifying: "Verifying checksum and runtime"
        case .installed: "Installed and verified on this Mac"
        case .failed:
            LocalizedStringKey(item.failureReason ?? String("Installation failed", in: locale))
        }
    }

    // MARK: Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubGroupTitle(title: "This Mac")
            HubPanel {
                permissionField(
                    .microphone, title: "Microphone",
                    detail: "Hear the words you choose to dictate")
                permissionField(
                    .accessibility, title: "Accessibility",
                    detail: "Insert prepared text into the active app")
                permissionField(
                    .inputMonitoring, title: "Input Monitoring",
                    detail: "Detect your shortcut in other apps")
                HubField(
                    title: "Local engines",
                    detail: Text("\(models.installedCount) of \(models.items.count) installed")
                ) {
                    if models.allInstalled {
                        Label("Ready", systemImage: "checkmark")
                            .font(VoxoLTypography.font(size: 13, weight: .medium))
                            .foregroundStyle(theme.success)
                    } else {
                        Button("Review") {
                            withAnimation(EditorialMotion.soft) { section = .engines }
                        }
                        .buttonStyle(HubButtonStyle(kind: .onWell))
                    }
                }
            }
        }
    }

    private func permissionField(
        _ permission: VoxoLPermission,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HubField(title: title, detail: Text(detail)) {
            let status = permissions.status(for: permission)
            // Accessibility and Input Monitoring are only ever completed in System Settings, so a
            // pending request keeps a live route there rather than an inert "Waiting…".
            let settlesInSettings = permission != .microphone
            if status == .granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(VoxoLTypography.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.success)
            } else {
                Button(permissionActionTitle(status, permission: permission)) {
                    if status == .denied || status == .restricted
                        || (status == .requesting && settlesInSettings)
                    {
                        permissions.openSystemSettings(for: permission)
                    } else {
                        Task { await permissions.request(permission) }
                    }
                }
                .buttonStyle(HubButtonStyle(kind: .primary))
                .disabled(status == .requesting && !settlesInSettings)
            }
        }
    }

    private func permissionActionTitle(
        _ status: VoxoLPermissionStatus,
        permission: VoxoLPermission
    ) -> LocalizedStringKey {
        switch status {
        case .granted: "Allowed"
        case .requesting: permission == .microphone ? "Waiting…" : "Open Settings"
        case .denied, .restricted: "Open Settings"
        case .notRequested: "Allow"
        }
    }

    // MARK: Privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubGroupTitle(title: "What stays on this Mac")
            HubPanel {
                HubField(title: "Private mode", detail: Text("Overrides history and learning")) {
                    Toggle("Private mode", isOn: $privateMode).toggleStyle(HubSwitchStyle())
                }
                HubField(
                    title: "Local history", detail: Text("Keep successful transcriptions on this Mac")
                ) {
                    Toggle("Local history", isOn: $historyEnabled)
                        .toggleStyle(HubSwitchStyle())
                        .disabled(privateMode)
                }
                HubField(
                    title: "Bounded context",
                    detail: Text("Use nearby text only for the current dictation")
                ) {
                    Toggle("Bounded context", isOn: $contextEnabled).toggleStyle(HubSwitchStyle())
                }
            }

            HubGroupTitle(title: "Learning")
            HubPanel {
                HubField(
                    title: "Correction learning",
                    detail: Text("\(personalization.corrections.count) approved local pairs")
                ) {
                    HStack(spacing: 8) {
                        Menu {
                            Button("Export reviewed pairs") { exportCorrections() }
                                .disabled(personalization.corrections.isEmpty)
                            Button("Delete correction data", role: .destructive) {
                                Task { await personalization.removeAllCorrections() }
                            }
                            .disabled(personalization.corrections.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(theme.secondaryInk)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .tint(theme.secondaryInk)
                        .fixedSize()
                        Toggle("Correction learning", isOn: $learningEnabled)
                            .toggleStyle(HubSwitchStyle())
                            .disabled(privateMode)
                    }
                }
                HubField(
                    title: "Personal benchmark capture",
                    detail: Text(
                        "Keeps each dictation’s audio on this Mac to measure accuracy on your own voice. 500 MB at most, off in private mode."
                    )
                ) {
                    Toggle("Personal benchmark capture", isOn: $correctionCapture)
                        .toggleStyle(HubSwitchStyle())
                        .disabled(privateMode)
                }
            }
        }
    }

    // MARK: About

    /// Update check and bug reporting.
    ///
    /// Both exist because a shipped build is otherwise a dead end: a user has no way to learn a
    /// fix exists, and no way to tell anyone it is needed. Neither sends anything on its own —
    /// the check reads a public release list, and the report opens a prefilled issue the user
    /// submits.
    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            HubGroupTitle(title: "VoxoL")
            HubPanel {
                HubField(
                    title: "Version",
                    detail: Text(
                        verbatim: BugReportComposer.Environment.current().applicationVersion)
                ) {
                    Button(updateStatusTitle) {
                        Task { await checkForUpdate() }
                    }
                    .buttonStyle(HubButtonStyle(kind: .onWell))
                    .disabled(UpdateNotifier.shared.isChecking)
                }
                HubField(
                    title: "Report a problem",
                    detail: Text("Opens a prefilled issue · timings only, never your text")
                ) {
                    Button("Report") { openBugReport() }
                        .buttonStyle(HubButtonStyle(kind: .onWell))
                }
            }
        }
    }

    private var updateStatusTitle: LocalizedStringKey {
        let notifier = UpdateNotifier.shared
        if notifier.isChecking { return "Checking…" }
        if let available = notifier.available { return "Update to \(available.version)" }
        if notifier.state.phase == .failed { return "Check failed · Retry" }
        return notifier.state.phase == .current ? "Up to date" : "Check for updates"
    }

    private func checkForUpdate() async {
        if UpdateNotifier.shared.available != nil {
            UpdateNotifier.shared.installAvailableUpdate()
            return
        }
        // One reader for the whole app, so this row and the sidebar can never disagree about
        // whether an update exists. `announce: false` keeps the alert away from someone who is
        // already looking at the result.
        await UpdateNotifier.shared.check(announce: false)
    }

    private func openBugReport() {
        let diagnostics = try? DictationSessionCoordinator.shared.diagnosticsExportData()
        let body = BugReportComposer.body(
            summary: "",
            steps: "",
            environment: .current(),
            diagnostics: diagnostics.flatMap { String(data: $0, encoding: .utf8) }
        )
        guard let url = BugReportComposer.issueURL(title: "", body: body) else { return }
        NSWorkspace.shared.open(url)
    }

    private func exportCorrections() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voxol-reviewed-corrections.jsonl"
        guard panel.runModal() == .OK, let url = panel.url,
            let data = try? personalization.correctionExportData()
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voxol-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url,
            let data = try? dictationSession.diagnosticsExportData()
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
