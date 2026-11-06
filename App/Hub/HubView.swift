import PersonalizationKit
import SwiftUI

enum HubDestination: String, CaseIterable, Identifiable {
    case today
    case insights
    case meetings
    case dictionary
    case snippets
    case style
    case review
    case settings

    var id: String { rawValue }

    /// The everyday screens, then the ones that change how VoxoL writes.
    static let primary: [HubDestination] = [.today, .insights, .meetings]
    static let personalize: [HubDestination] = [.dictionary, .snippets, .style, .review]

    var title: LocalizedStringKey {
        switch self {
        case .today: "Home"
        case .insights: "Statistics"
        case .meetings: "Meetings"
        case .dictionary: "Dictionary"
        case .snippets: "Shortcuts"
        case .style: "Style"
        case .review: "Review recordings"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .today: "house"
        case .insights: "chart.bar"
        case .meetings: "person.2"
        case .dictionary: "book.closed"
        case .snippets: "bolt"
        case .style: "pencil"
        case .review: "checkmark.circle"
        case .settings: "gearshape"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .today: "1"
        case .insights: "2"
        case .meetings: "3"
        case .dictionary: "4"
        case .snippets: "5"
        case .style: "6"
        case .review: "7"
        case .settings: ","
        }
    }
}

struct HubView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PermissionCoordinator.self) private var permissions
    @Environment(ModelInstallationStore.self) private var models
    @Environment(DictationSessionCoordinator.self) private var dictationSession
    @Environment(TranscriptStore.self) private var transcripts
    @Environment(PersonalizationStore.self) private var personalization
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var languageCode: String
    let replayPreflight: () -> Void

    @AppStorage("voxol.openSetupOnNextHub") private var openSetupOnNextHub = false
    @AppStorage("voxol.dictationShortcut") private var shortcut = DictationShortcut.optionSpace
    @AppStorage("voxol.learningEnabled") private var learningEnabled = true
    @AppStorage("voxol.privateMode") private var privateMode = false

    @State private var selection = HubView.initialDestination
    @State private var settingsSection = HubView.initialSettingsSection
    @State private var toastVisible = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width <= 980

            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: compact ? 204 : 228)
                    page
                        .padding([.top, .trailing, .bottom], 8)
                }
                .background(theme.canvas)
                .ignoresSafeArea(.container, edges: .top)

                if toastVisible, let toast = transcripts.toast {
                    Text(toastTitle(toast))
                        .font(VoxoLTypography.font(size: 13, weight: .medium))
                        .foregroundStyle(theme.surface)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(theme.ink, in: Capsule())
                        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
                        .padding(.bottom, 24)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
        }
        .preferredColorScheme(.light)
        .tint(theme.cobalt)
        .font(VoxoLTypography.font(size: 13))
        .onAppear {
            guard openSetupOnNextHub else { return }
            openSetupOnNextHub = false
            openSetup()
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

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VoxoLMark(size: 20)
                Text(verbatim: "VoxoL")
                    .font(VoxoLTypography.font(size: 14, weight: .semibold))
                    .foregroundStyle(theme.ink)
            }
            .padding(.horizontal, 10)
            .padding(.top, 52)
            .padding(.bottom, 12)

            navigationGroup(HubDestination.primary)

            Text("Personalize")
                .font(VoxoLTypography.font(size: 12))
                .foregroundStyle(theme.secondaryInk)
                .padding(.horizontal, 10)
                .padding(.top, 20)
                .padding(.bottom, 4)

            navigationGroup(HubDestination.personalize)

            Spacer(minLength: 12)

            if transcripts.historyIssue != nil {
                noticeRow(
                    symbol: "exclamationmark.triangle",
                    tone: theme.warning,
                    title: "History needs attention"
                ) { select(.today) }
            }

            if let update = UpdateNotifier.shared.available {
                noticeRow(
                    symbol: "arrow.down.circle",
                    tone: theme.cobalt,
                    title: LocalizedStringKey("Update to \(update.version)")
                ) { UpdateNotifier.shared.installAvailableUpdate() }
            }

            navigationRow(.settings)
            stateRow
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func navigationGroup(_ destinations: [HubDestination]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(destinations) { navigationRow($0) }
        }
    }

    private func navigationRow(_ destination: HubDestination) -> some View {
        let selected = selection == destination
        return Button {
            if destination == .settings {
                settingsSection = systemReady ? .general : .permissions
            }
            select(destination)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(selected ? theme.ink : theme.secondaryInk)
                    .frame(width: 16)
                Text(destination.title)
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                navigationBadge(destination)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(
                selected ? theme.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(destination.shortcut, modifiers: .command)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A count only where something waits to be done.
    @ViewBuilder
    private func navigationBadge(_ destination: HubDestination) -> some View {
        switch destination {
        case .dictionary where pendingSuggestions > 0:
            Text(verbatim: pendingSuggestions.formatted())
                .font(VoxoLTypography.font(size: 12))
                .foregroundStyle(theme.secondaryInk)
                .monospacedDigit()
                .accessibilityLabel(Text("\(pendingSuggestions) words to confirm"))
        case .settings where !systemReady:
            Circle()
                .fill(theme.warning)
                .frame(width: 6, height: 6)
                .accessibilityLabel(Text("Setup required"))
        default:
            EmptyView()
        }
    }

    private var pendingSuggestions: Int {
        DictionarySuggestions.pending(
            in: personalization, learningEnabled: learningEnabled, privateMode: privateMode
        ).count
    }

    private func noticeRow(
        symbol: String,
        tone: Color,
        title: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(tone)
                    .frame(width: 16)
                Text(title)
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The runtime, on every screen: its state and the shortcut. Holding it dictates from here.
    private var stateRow: some View {
        let runtime = EditorialRuntimePresentation(dictationSession)
        return HStack(spacing: 8) {
            Circle()
                .fill(systemReady ? runtime.tone(theme) : theme.warning)
                .frame(width: 7, height: 7)
            Text(systemReady ? runtime.title : LocalizedStringKey("Setup required"))
                .font(VoxoLTypography.font(size: 13, weight: .medium))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if runtime.isListening {
                EditorialWaveMini()
            } else if systemReady {
                HubKeycap(label: shortcut.label, fill: theme.surface)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 36)
        .padding(.top, 6)
        .editorialDictationTrigger(setupReady: systemReady, openSetup: openSetup)
        .help(systemReady ? Text("Hold to dictate from any screen") : Text("Open guided setup"))
        .accessibilityLabel(systemReady ? Text(runtime.title) : Text("Setup required"))
    }

    // MARK: Page

    private var page: some View {
        detail(for: selection)
            .id(selection)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func detail(for destination: HubDestination) -> some View {
        switch destination {
        case .today:
            HomeView(setupReady: systemReady, openSetup: openSetup)
        case .insights:
            StatisticsView()
        case .meetings:
            NativeMeetingsView()
        case .dictionary:
            DictionaryView()
        case .snippets:
            SnippetsView()
        case .style:
            StyleView()
        case .review:
            ReviewView()
        case .settings:
            SettingsView(
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

    /// `-voxol.debugSettingsSection dictation` opens Settings on that tab, for the same reason.
    private static var initialSettingsSection: SettingsSection {
        #if DEBUG
            if let raw = UserDefaults.standard.string(forKey: "voxol.debugSettingsSection"),
                let section = SettingsSection(rawValue: raw)
            {
                return section
            }
        #endif
        return .general
    }

    private func openSetup() {
        settingsSection = .permissions
        select(.settings)
    }

    private func select(_ destination: HubDestination) {
        guard destination != selection else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
            selection = destination
        }
    }

    private var systemReady: Bool {
        permissions.requiredPermissionsGranted
            && models.allInstalled
            && dictationSession.shortcutIsActive
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

#Preview("Hub · 1120 × 760") {
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
