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
    /// `dictation` is absent for the opposite reason: everything it showed now
    /// exists elsewhere. The live before/after belongs to a result and lives in
    /// Today, the history lives in Today and Library, and its three controls
    /// moved into Settings › Dictation. A tab that only repeats other tabs
    /// makes the app look bigger than it is.
    static var navigable: [HubDestination] {
        allCases.filter { $0 != .dictation }
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
    @AppStorage("voxol.activationMode") private var activationMode = ActivationMode.hold
    @AppStorage("voxol.dictationShortcut") private var shortcut = DictationShortcut.optionSpace

    @State private var selection = HubView.initialDestination
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
        .task(id: transcripts.toastID) {
            guard transcripts.toast != nil else { return }
            withAnimation(reduceMotion ? nil : EditorialMotion.soft) {
                toastVisible = true
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : EditorialMotion.soft) {
                toastVisible = false
            }
            transcripts.dismissToast()
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

            if transcripts.historyIssue != nil {
                Button {
                    select(.today)
                } label: {
                    sidebarRow(
                        compact: compact,
                        icon: Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 13)),
                        tint: theme.warning,
                        tintSoft: theme.selection,
                        title: "History needs attention",
                        detail: Text("Review and retry")
                    )
                }
                .buttonStyle(SignalPressButtonStyle())
                .padding(.bottom, 8)
            }

            // The runtime, on every screen: its state, the shortcut, and a place to hold and
            // dictate without going back to Today first.
            dictationCard(compact: compact)
                .padding(.bottom, 8)

            // The update row sits above the readiness row on purpose: an update is news, and
            // news belongs where the eye already goes to check that things are fine. Once the
            // setup is complete the readiness row has nothing left to say, so the corner becomes
            // the one place to ask for a new version instead of repeating that everything works.
            if systemReady || UpdateNotifier.shared.state.phase != .idle {
                updateRow(compact: compact)
            }

            if !systemReady {
                Button(action: openSetup) {
                    sidebarRow(
                        compact: compact,
                        icon: EditorialIcon(name: "shield-check", size: 13),
                        tint: theme.coral,
                        tintSoft: theme.coralSoft,
                        title: "Finish setup",
                        detail: Text(verbatim: localStatusDetail)
                    )
                }
                .buttonStyle(SignalPressButtonStyle())
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, compact ? 12 : 18)
        .padding(.bottom, 10)
    }

    /// One corner for the version: it names the running build, checks the feed on a click, and
    /// turns into the install button for as long as a newer version is waiting.
    private func updateRow(compact: Bool) -> some View {
        let notifier = UpdateNotifier.shared
        return Button {
            if notifier.available != nil {
                notifier.installAvailableUpdate()
            } else {
                Task {
                    await notifier.check(announce: false)
                }
            }
        } label: {
            if let update = notifier.available {
                // Cobalt rather than coral: an update is news, not a fault, and coral is
                // already what "something is wrong" looks like one row below.
                sidebarRow(
                    compact: compact,
                    icon: EditorialIcon(name: "download-simple", size: 13),
                    tint: theme.cobalt,
                    tintSoft: theme.cobaltSoft,
                    background: theme.cobaltSoft.opacity(0.5),
                    title: "Update available",
                    detail: Text(verbatim: "VoxoL \(update.version)")
                )
            } else if notifier.isChecking {
                sidebarRow(
                    compact: compact,
                    icon: updateGlyph,
                    tint: theme.secondaryInk,
                    tintSoft: theme.selection,
                    title: LocalizedStringKey(versionTitle),
                    detail: Text("Checking…")
                )
            } else if notifier.state.phase == .failed {
                sidebarRow(
                    compact: compact,
                    icon: updateGlyph,
                    tint: theme.warning,
                    tintSoft: theme.selection,
                    title: "Could not check for updates",
                    detail: Text("Retry")
                )
            } else if notifier.state.phase == .current {
                sidebarRow(
                    compact: compact,
                    icon: EditorialIcon(name: "check", size: 13),
                    tint: theme.success,
                    tintSoft: theme.sageSoft,
                    title: LocalizedStringKey(versionTitle),
                    detail: Text("Up to date")
                )
            } else {
                sidebarRow(
                    compact: compact,
                    icon: updateGlyph,
                    tint: theme.ink,
                    tintSoft: theme.selection,
                    title: LocalizedStringKey(versionTitle),
                    detail: Text("Check for updates")
                )
            }
        }
        .buttonStyle(SignalPressButtonStyle())
        .disabled(notifier.isChecking)
    }

    private var updateGlyph: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .semibold))
    }

    /// Verbatim: a version number has nothing to translate, and wrapping it in a key would
    /// only send the localization check looking for one.
    private var versionTitle: String {
        "VoxoL \(BugReportComposer.Environment.current().applicationVersion)"
    }

    private func sidebarRow(
        compact: Bool,
        icon: some View,
        tint: Color,
        tintSoft: Color,
        background: Color? = nil,
        title: LocalizedStringKey,
        detail: Text
    ) -> some View {
        HStack(spacing: 8) {
            icon
                .foregroundStyle(tint)
                .frame(width: compact ? 24 : 26, height: compact ? 24 : 26)
                .background(tintSoft)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(VoxoLTypography.font(size: 11, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(theme.ink)
                    .lineLimit(compact ? 2 : 1)
                detail
                    .font(VoxoLTypography.font(size: 10.5, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            EditorialIcon(name: "caret-right", size: 16)
                .foregroundStyle(theme.secondaryInk)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: compact ? 64 : 58)
        .background(background ?? theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// What the day has produced so far, and where attention is still needed.
    @ViewBuilder
    private func navigationBadge(_ destination: HubDestination) -> some View {
        switch destination {
        case .today where todayCount > 0:
            Text(verbatim: todayCount.formatted())
                .font(VoxoLTypography.font(size: 10.5, weight: .semibold, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryInk)
                .padding(.horizontal, 7)
                .frame(minWidth: 22, minHeight: 20)
                .background(theme.ink.opacity(0.06))
                .clipShape(Capsule())
                .accessibilityLabel(Text(LocalizedStringKey("\(todayCount) dictations")))
        case .settings where !systemReady:
            Circle()
                .fill(theme.coral)
                .frame(width: 7, height: 7)
                .accessibilityLabel(Text("Setup required"))
        default:
            EmptyView()
        }
    }

    /// Dictations retained today. Records are newest first, so the count stops at the first
    /// older one instead of walking the whole history.
    private var todayCount: Int {
        let calendar = Calendar.current
        return transcripts.records.prefix { calendar.isDateInToday($0.createdAt) }.count
    }

    /// The runtime in the sidebar, and a trigger: hold it to dictate from any screen.
    private func dictationCard(compact: Bool) -> some View {
        let runtime = EditorialRuntimePresentation(dictationSession)
        let tone = runtime.tone(theme)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(systemReady ? tone : theme.warning)
                    .frame(width: 7, height: 7)
                Text(systemReady ? runtime.title : LocalizedStringKey("Setup required"))
                    .font(
                        VoxoLTypography.font(size: 11.5, weight: .semibold, relativeTo: .caption)
                    )
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if runtime.isListening {
                    EditorialWaveMini()
                }
            }
            HStack(spacing: 6) {
                Text(verbatim: shortcut.label)
                    .font(VoxoLTypography.font(size: 10.5, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(theme.selection)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(activationMode == .hold ? "Hold to dictate" : "Press to dictate")
                    .font(VoxoLTypography.font(size: 10.5, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(runtime.isActive ? tone.opacity(0.5) : Color.clear, lineWidth: 1)
        }
        .editorialDictationTrigger(setupReady: systemReady, openSetup: openSetup)
        .help(systemReady ? Text("Hold to dictate from any screen") : Text("Open guided setup"))
        .accessibilityLabel(systemReady ? Text(runtime.title) : Text("Setup required"))
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
                    navigationBadge(destination)
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
            NativeMeetingsView()
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

    /// Debug builds can open straight onto a destination — `-voxol.debugHubDestination insights` —
    /// so a screen can be captured from a fresh launch without driving the interface.
    private static var initialDestination: HubDestination {
        #if DEBUG
            if let raw = UserDefaults.standard.string(forKey: "voxol.debugHubDestination"),
                let destination = HubDestination(rawValue: raw)
            {
                return destination
            }
        #endif
        return .today
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
        case .recoveryExported: "Recovery copy exported"
        case .recoveryExportFailed: "Recovery copy could not be exported"
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
