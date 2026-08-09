import AppKit
import SwiftUI

struct HistoryStudioView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts

    @AppStorage("voxol.historyEnabled") private var historyEnabled = true
    @State private var searchText = ""

    var body: some View {
        StudioPage(
            eyebrow: "Local history",
            title: "Every retained result, in one place.",
            summary:
                "Review, copy and recover transcript revisions without sending your words anywhere."
        ) {
            ShowcaseSurface {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(
                                historyEnabled
                                    ? "New transcripts are retained"
                                    : "New transcripts are not retained"
                            )
                            .font(.title2.weight(.semibold))
                            Text(
                                historyEnabled
                                    ? "Text is written only to this Mac after a successful dictation."
                                    : "Existing local results remain visible until you remove them."
                            )
                            .foregroundStyle(theme.secondaryInk)
                        }
                        Spacer()
                        Toggle("Local history", isOn: $historyEnabled)
                            .labelsHidden()
                    }

                    Divider()

                    TextField("Search transcriptions", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    if transcripts.usesExampleData {
                        Label(
                            "Example activity for interface review · never persisted",
                            systemImage: "sparkles"
                        )
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                    }
                }
            }

            StudioSection("Transcriptions") {
                if filteredRecords.isEmpty {
                    VoxoLCard {
                        ContentUnavailableView(
                            searchText.isEmpty
                                ? "No transcriptions yet" : "No matching transcriptions",
                            systemImage: "text.bubble",
                            description: Text(
                                searchText.isEmpty
                                    ? "Retained dictations will appear here with their time and source app."
                                    : "Try a different word or application name."
                            )
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    }
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredRecords) { record in
                            TranscriptActivityRow(record: record, store: transcripts)
                        }
                    }
                }
            }

            StudioSection("Retention") {
                VoxoLCard {
                    VStack(spacing: 18) {
                        SettingLine(
                            title: "Store successful dictations",
                            detail: "Keep text locally for recovery and manual correction."
                        ) {
                            Toggle("Store successful dictations", isOn: $historyEnabled)
                                .labelsHidden()
                        }
                        Divider()
                        SettingLine(
                            title: "Audio retention",
                            detail:
                                "Off by default. No audio file is created, so history stays lightweight."
                        ) {
                            StatusPill(title: "Off", symbol: "mic.slash")
                        }
                        Divider()
                        SettingLine(
                            title: "Private mode",
                            detail: "Private mode overrides every history preference."
                        ) {
                            StatusPill(title: "Always respected", symbol: "lock")
                        }
                    }
                }
            }

            LocalOnlyNote(
                text:
                    "Text history is local and opt-in. Audio is not retained by the current capture path."
            )
        }
    }

    private var filteredRecords: [TranscriptRecord] {
        guard !searchText.isEmpty else {
            return transcripts.records
        }
        return transcripts.records.filter { record in
            record.text.localizedCaseInsensitiveContains(searchText)
                || record.applicationName.localizedCaseInsensitiveContains(searchText)
        }
    }
}

struct SystemStudioView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(ModelInstallationStore.self) private var modelInstallation
    @Environment(PermissionCoordinator.self) private var permissions
    @Environment(PersonalizationStore.self) private var personalization
    @Environment(DictationSessionCoordinator.self) private var dictationSession

    @Binding var languageCode: String
    let replayPreflight: () -> Void

    @AppStorage("voxol.privateMode") private var privateMode = false
    @AppStorage("voxol.historyEnabled") private var historyEnabled = true
    @AppStorage("voxol.contextEnabled") private var contextEnabled = true
    @AppStorage("voxol.learningEnabled") private var learningEnabled = true

    var body: some View {
        StudioPage(
            eyebrow: "System",
            title: "Private, measurable and under control.",
            summary:
                "Review local data choices, engine readiness and the budgets that define a fast experience."
        ) {
            StudioSection("Privacy") {
                VoxoLCard {
                    VStack(spacing: 18) {
                        SettingLine(
                            title: "Private mode",
                            detail: "Disable history and learning regardless of other preferences."
                        ) {
                            Toggle("Private mode", isOn: $privateMode)
                                .labelsHidden()
                        }
                        Divider()
                        SettingLine(
                            title: "Local history",
                            detail: "Keep transcripts on this Mac for recovery."
                        ) {
                            Toggle("Local history", isOn: $historyEnabled)
                                .labelsHidden()
                                .disabled(privateMode)
                        }
                        Divider()
                        SettingLine(
                            title: "Bounded context",
                            detail: "Use nearby text only while preparing the current dictation."
                        ) {
                            Toggle("Bounded context", isOn: $contextEnabled)
                                .labelsHidden()
                        }
                        Divider()
                        SettingLine(
                            title: "Correction learning",
                            detail:
                                "Keep a training pair only when you explicitly edit a retained transcript."
                        ) {
                            Toggle("Correction learning", isOn: $learningEnabled)
                                .labelsHidden()
                                .disabled(privateMode)
                        }
                    }
                }
            }

            StudioSection("Learning data") {
                VoxoLCard {
                    VStack(spacing: 18) {
                        SettingLine(
                            title: "Approved correction pairs",
                            detail:
                                "Encrypted locally and excluded whenever Private mode is active."
                        ) {
                            Text(personalization.corrections.count.formatted())
                                .monospacedDigit()
                        }
                        Divider()
                        HStack {
                            Button("Export reviewed pairs") {
                                exportCorrections()
                            }
                            .disabled(personalization.corrections.isEmpty)
                            Spacer()
                            Button("Delete correction data", role: .destructive) {
                                Task { await personalization.removeAllCorrections() }
                            }
                            .disabled(personalization.corrections.isEmpty)
                        }
                    }
                }
            }

            StudioSection(
                "Local engines",
                summary:
                    "The UI reports actual bootstrap state rather than simulating installed models."
            ) {
                VStack(spacing: 12) {
                    ForEach(modelInstallation.items) { item in
                        ModelInstallationRow(item: item, store: modelInstallation)
                    }
                    if modelInstallation.items.isEmpty {
                        ProgressView("Checking runtime artifacts…")
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                }
            }

            StudioSection("Permissions") {
                VStack(spacing: 12) {
                    PermissionSetupRow(
                        permission: .microphone,
                        symbol: "mic",
                        title: "Microphone",
                        detail: "Hear the words you choose to dictate",
                        coordinator: permissions
                    )
                    PermissionSetupRow(
                        permission: .accessibility,
                        symbol: "cursorarrow.rays",
                        title: "Accessibility",
                        detail: "Insert prepared text into the active app",
                        coordinator: permissions
                    )
                    PermissionSetupRow(
                        permission: .inputMonitoring,
                        symbol: "keyboard",
                        title: "Input Monitoring",
                        detail: "Detect the VoxoL shortcut while another app is active",
                        coordinator: permissions
                    )
                }
            }

            StudioSection("Performance budgets") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: 14)],
                    spacing: 14
                ) {
                    metric(value: "< 100 ms", label: "First overlay update")
                    metric(value: "< 1.3 s", label: "p95 release to paste")
                    metric(value: "< 5.5 GB", label: "Warm total memory")
                    metric(value: "0", label: "Network calls during dictation")
                }
            }

            StudioSection("Content-free diagnostics") {
                VoxoLCard {
                    SettingLine(
                        title: "Last dictation report",
                        detail:
                            "Export timings, routes and failure codes without transcript text or audio."
                    ) {
                        Button("Export diagnostics") {
                            exportDiagnostics()
                        }
                        .disabled(dictationSession.lastReport == nil)
                    }
                }
            }

            StudioSection("Interface") {
                VoxoLCard {
                    VStack(spacing: 18) {
                        SettingLine(
                            title: "Language",
                            detail: "French and English are designed together."
                        ) {
                            Picker("Language", selection: $languageCode) {
                                ForEach(AppLanguage.allCases) { language in
                                    Text(language.displayName).tag(language.rawValue)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                        }
                        Divider()
                        SettingLine(
                            title: "Preflight",
                            detail: "Replay the guided setup and interactive product tour."
                        ) {
                            Button("Replay", action: replayPreflight)
                                .buttonStyle(VoxoLSecondaryButtonStyle())
                        }
                    }
                }
            }

            LocalOnlyNote(
                text:
                    "Diagnostics are designed to contain timings and versions, never audio or transcript text."
            )
        }
    }

    private func metric(value: String, label: LocalizedStringKey) -> some View {
        VoxoLCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.ink)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func exportCorrections() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voxol-reviewed-corrections.jsonl"
        guard panel.runModal() == .OK, let url = panel.url,
            let data = try? personalization.correctionExportData()
        else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voxol-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url,
            let data = try? dictationSession.diagnosticsExportData()
        else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
