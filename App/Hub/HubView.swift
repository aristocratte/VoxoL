import SwiftUI

enum HubDestination: String, CaseIterable, Identifiable {
    case today
    case dictation
    case insights
    case meetings
    case library
    case settings

    var id: String { rawValue }

    /// Destinations the sidebar offers.
    ///
    /// `meetings` is deliberately absent. Its screen is a mock-up with no
    /// engine behind it, and the competitor ships a real meeting mode with
    /// calendar detection and note-taking integrations. An empty tab beside
    /// theirs advertises the gap rather than hiding it. The view and its enum
    /// case stay so the v2 work resumes from where it stopped; only the door
    /// is closed. Restore it here once transcription and diarisation are
    /// measured on a real meeting corpus.
    ///
    /// `dictation` is absent for the opposite reason: everything it showed now
    /// exists elsewhere. The live before/after belongs to a result and lives in
    /// Today, the history lives in Today and Library, and its three controls
    /// moved into Settings › Dictation. A tab that only repeats other tabs
    /// makes the app look bigger than it is.
    static var navigable: [HubDestination] {
        allCases.filter { $0 != .meetings && $0 != .dictation }
    }

    var title: LocalizedStringKey {
        switch self {
        case .today: "Today"
        case .dictation: "Dictation"
        case .insights: "Insights"
        case .meetings: "Meetings"
        case .library: "Library"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .today: "house"
        case .dictation: "waveform"
        case .insights: "chart-line-up"
        case .meetings: "users-three"
        case .library: "books"
        case .settings: "gear-six"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .today: "1"
        case .dictation: "2"
        case .insights: "3"
        case .meetings: "4"
        case .library: "5"
        case .settings: "6"
        }
    }
}

private struct HubScreenTransitionModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? 4 : 0)
            .offset(y: active ? 12 : 0)
    }
}

struct HubView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PermissionCoordinator.self) private var permissions
    @Environment(ModelInstallationStore.self) private var models
    @Environment(DictationSessionCoordinator.self) private var dictationSession
    @Environment(TranscriptStore.self) private var transcripts
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var languageCode: String
    let replayPreflight: () -> Void

    @AppStorage("voxol.openSetupOnNextHub") private var openSetupOnNextHub = false

    @State private var selection = HubDestination.today
    @State private var settingsSection = EditorialSettingsSection.general
    @State private var toastVisible = false
    @Namespace private var sidebarNamespace

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width <= 980

            ZStack(alignment: .bottom) {
                theme.canvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    windowBar
                    HStack(spacing: 8) {
                        sidebar(compact: compact)
                            .frame(width: compact ? 186 : 210)
                        detailPanel
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .ignoresSafeArea(.container, edges: .top)

                if toastVisible, let toast = transcripts.toast {
                    Text(toastTitle(toast))
                        .font(
                            VoxoLTypography.font(
                                size: 12,
                                weight: .semibold,
                                relativeTo: .body
                            )
                        )
                        .foregroundStyle(theme.surface)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(theme.ink)
                        .clipShape(Capsule())
                        .shadow(color: Color.black.opacity(0.16), radius: 16, y: 6)
                        .padding(.bottom, 22)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
        }
        .preferredColorScheme(.light)
        .tint(theme.cobalt)
        .font(VoxoLTypography.font(size: 13, relativeTo: .body))
        .onAppear {
            guard openSetupOnNextHub else { return }
            openSetupOnNextHub = false
            settingsSection = .setup
            selection = .settings
        }
        .onChange(of: transcripts.toast) { _, toast in
            guard toast != nil else { return }
            withAnimation(reduceMotion ? nil : EditorialMotion.soft) {
                toastVisible = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(reduceMotion ? nil : EditorialMotion.soft) {
                    toastVisible = false
                }
                transcripts.dismissToast()
            }
        }
    }

    private var windowBar: some View {
        ZStack {
            Text(verbatim: "VoxoL")
                .font(VoxoLTypography.font(size: 12, weight: .medium, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VoxoLMark(size: compact ? 30 : 34)
                Text(verbatim: "VoxoL")
                    .font(
                        VoxoLTypography.font(
                            size: compact ? 22 : 25, weight: .semibold, relativeTo: .title2)
                    )
                    .foregroundStyle(theme.ink)
                    .tracking(-0.8)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: compact ? 56 : 62)

            VStack(spacing: compact ? 4 : 6) {
                ForEach(HubDestination.navigable) { destination in
                    navigationButton(destination, compact: compact)
                }
            }
            .padding(.top, compact ? 14 : 20)

            Spacer(minLength: 12)

            // Sits above the readiness row on purpose: an update is news, and
            // news belongs where the eye already goes to check that things are
            // fine. It stays until the version is actually installed rather
            // than until it is acknowledged.
            if let update = UpdateNotifier.shared.available {
                Button {
                    UpdateNotifier.shared.openDownloadPage()
                } label: {
                    HStack(spacing: 8) {
                        // Cobalt rather than coral: an update is news, not a
                        // fault, and coral is already what "something is wrong"
                        // looks like one row below.
                        EditorialIcon(name: "download-simple", size: 13)
                            .foregroundStyle(theme.cobalt)
                            .frame(width: compact ? 24 : 26, height: compact ? 24 : 26)
                            .background(theme.cobaltSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 0) {
                            Text("Update available")
                                .font(
                                    VoxoLTypography.font(
                                        size: 11,
                                        weight: .semibold,
                                        relativeTo: .caption
                                    )
                                )
                                .foregroundStyle(theme.ink)
                                .lineLimit(1)
                            Text(verbatim: "VoxoL \(update.version)")
                                .font(VoxoLTypography.font(size: 10.5, relativeTo: .caption))
                                .foregroundStyle(theme.secondaryInk)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        EditorialIcon(name: "caret-right", size: 16)
                            .foregroundStyle(theme.secondaryInk)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: compact ? 64 : 58)
                    .background(theme.cobaltSoft.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(SignalPressButtonStyle())
                .padding(.bottom, 8)
            }

            Button {
                if systemReady {
                    settingsSection = .general
                    select(.settings)
                } else {
                    openSetup()
                }
            } label: {
                HStack(spacing: 8) {
                    EditorialIcon(name: "shield-check", size: 13)
                        .foregroundStyle(systemReady ? theme.success : theme.coral)
                        .frame(width: compact ? 24 : 26, height: compact ? 24 : 26)
                        .background(systemReady ? theme.sageSoft : theme.coralSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 0) {
                        Text(systemReady ? "Everything works" : "Finish setup")
                            .font(
                                VoxoLTypography.font(
                                    size: 11,
                                    weight: .semibold,
                                    relativeTo: .caption
                                )
                            )
                            .foregroundStyle(theme.ink)
                            .lineLimit(compact ? 2 : 1)
                        Text(localStatusDetail)
                            .font(VoxoLTypography.font(size: 10.5, relativeTo: .caption))
                            .foregroundStyle(theme.secondaryInk)
                            .lineLimit(compact ? 2 : 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    EditorialIcon(name: "caret-right", size: 16)
                        .foregroundStyle(theme.secondaryInk)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: compact ? 64 : 58)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(SignalPressButtonStyle())
        }
        .padding(.horizontal, 10)
        .padding(.top, compact ? 12 : 18)
        .padding(.bottom, 10)
    }

    private func navigationButton(_ destination: HubDestination, compact: Bool) -> some View {
        Button {
            if destination == .settings {
                settingsSection = systemReady ? .general : .setup
            }
            select(destination)
        } label: {
            HStack(spacing: 11) {
                EditorialIcon(name: destination.icon, size: 16)
                    .foregroundStyle(theme.ink.opacity(0.7))
                    .frame(width: 16)
                HStack(spacing: 0) {
                    Text(destination.title)
                        .font(
                            VoxoLTypography.font(
                                size: 13,
                                weight: .medium,
                                relativeTo: .body
                            )
                        )
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, compact ? 11 : 13)
            .frame(maxWidth: .infinity, minHeight: compact ? 40 : 42, alignment: .leading)
            .background {
                if selection == destination {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.surface)
                        .matchedGeometryEffect(id: "sidebar-selection", in: sidebarNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SignalPressButtonStyle())
        .keyboardShortcut(destination.shortcut, modifiers: .command)
        .accessibilityAddTraits(selection == destination ? .isSelected : [])
    }

    private var detailPanel: some View {
        ZStack {
            theme.surface
            detail(for: selection)
                .id(selection)
                .transition(
                    .modifier(
                        active: HubScreenTransitionModifier(active: true),
                        identity: HubScreenTransitionModifier(active: false)
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        }
        .clipped()
    }

    @ViewBuilder
    private func detail(for destination: HubDestination) -> some View {
        switch destination {
        case .today:
            EditorialTodayView(
                setupReady: systemReady,
                openInsights: { select(.insights) },
                openSettings: {
                    settingsSection = .general
                    select(.settings)
                },
                openSetup: openSetup
            )
        case .dictation:
            EditorialDictationView(setupReady: systemReady, openSetup: openSetup)
        case .insights:
            EditorialInsightsView()
        case .meetings:
            EditorialMeetingsView()
        case .library:
            EditorialLibraryView()
        case .settings:
            EditorialSettingsView(
                languageCode: $languageCode,
                section: $settingsSection,
                replayPreflight: replayPreflight
            )
        }
    }

    private func openSetup() {
        settingsSection = .setup
        select(.settings)
    }

    private func select(_ destination: HubDestination) {
        guard destination != selection else { return }
        withAnimation(reduceMotion ? nil : EditorialMotion.fluid) {
            selection = destination
        }
    }

    private var grantedPermissionCount: Int {
        VoxoLPermission.allCases.count { permissions.status(for: $0) == .granted }
    }

    private var systemReady: Bool {
        permissions.requiredPermissionsGranted
            && models.allInstalled
            && dictationSession.shortcutIsActive
    }

    private var localStatusDetail: String {
        let engineCount = models.installedCount
        let permissionCount = grantedPermissionCount

        if languageCode == AppLanguage.french.rawValue {
            let engines = engineCount == 1 ? "moteur" : "moteurs"
            return "\(engineCount) \(engines) · \(permissionCount) accès"
        }

        let engines = engineCount == 1 ? "engine" : "engines"
        let permissions = permissionCount == 1 ? "permission" : "permissions"
        return "\(engineCount) \(engines) · \(permissionCount) \(permissions)"
    }

    private func toastTitle(_ toast: TranscriptToast) -> LocalizedStringKey {
        switch toast {
        case .copied: "Copied to clipboard"
        case .previousVersionRestored: "Previous version restored"
        case .laterVersionRestored: "Later version restored"
        case .audioExported: "Audio exported"
        case .noAudioRetained: "No audio was retained"
        case .audioExportFailed: "Audio export failed"
        case .historyLoadFailed: "History could not be loaded"
        case .historySaveFailed: "History could not be saved"
        case .editSaved: "Edit saved"
        }
    }
}

#Preview("Signal editorial · 1120 × 760") {
    HubView(languageCode: .constant("fr"), replayPreflight: {})
        .frame(width: 1120, height: 760)
        .environment(VoxoLTheme())
        .environment(PermissionCoordinator())
        .environment(ModelInstallationStore())
        .environment(DictationSessionCoordinator.shared)
        .environment(TranscriptStore())
        .environment(PersonalizationStore())
        .environment(\.locale, Locale(identifier: "fr"))
}
