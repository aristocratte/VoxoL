import AppKit
import Foundation
import SwiftUI

// MARK: - Grain
//
// The voice is matter. At the centre of a warm paper page lives a sphere drawn entirely in
// dither — thousands of ink dots on a fixed grid, shaded like a ball of grain — the same material
// as the VoxoL mark. Setting the app up literally resolves it: while systems are missing the
// sphere is loose and dispersed, and as each permission, engine and shortcut comes online the
// grain gathers into a crisp form and its orbit ring fills, one arc per system.
//
// The direction is built on three rules:
//   1. One idea per screen, centred, spoken in display type on warm paper.
//   2. Matter is state. The sphere's resolution and its six-arc ring map only to real readiness.
//   3. The sphere is the instrument. On the rehearsal step the user holds the grain itself to
//      rehearse the gesture — nothing is recorded.

private enum PreflightStep: Int, CaseIterable, Identifiable {
    case welcome
    case capabilities
    case access
    case engines
    case rehearsal
    case ready

    var id: Int { rawValue }

    var eyebrow: LocalizedStringKey {
        switch self {
        case .welcome: "01 · Welcome"
        case .capabilities: "02 · What it does"
        case .access: "03 · Access"
        case .engines: "04 · Model"
        case .rehearsal: "05 · Rehearsal"
        case .ready: "06 · Ready"
        }
    }
}

private enum GateState: Equatable {
    case missing
    case working
    case online
    case blocked
}

private enum RehearsalState: Equatable {
    case idle
    case holding
    case tooShort
    case processing
    case complete
}

private enum GrainMotion {
    /// The travel between two screens: one spring shared by the pages, the sphere and the chrome.
    static let travel = Animation.spring(response: 0.62, dampingFraction: 0.86)
    static let settle = Animation.spring(response: 0.45, dampingFraction: 0.9)
    static let quick = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.2)
    static let press = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.14)
}

// MARK: - Metrics

private struct GrainMetrics {
    let size: CGSize

    var compact: Bool { size.width < 940 }
    var short: Bool { size.height < 690 }

    var margin: CGFloat { compact ? 28 : 48 }
    var chromeTop: CGFloat { 56 }
    var chromeBottom: CGFloat { short ? 70 : 86 }
    var columnWidth: CGFloat { min(620, size.width - margin * 2) }
    var headlineSize: CGFloat { compact ? 30 : 40 }

    /// Vertical room reserved for the sphere between the top chrome and the page content. The
    /// ring is the widest part of the mark — 1.3 × the nominal diameter — so the region is
    /// derived from it and the page can never collide with the form. The capabilities step also
    /// has the destination apps orbiting outside the ring.
    func orbRegion(_ step: PreflightStep) -> CGFloat {
        guard step == .capabilities else { return orbSize(step) * 1.3 + 20 }
        return orbitRadius(step) * 2 + orbitCard + 12
    }

    /// Nominal sphere diameter for a step. The drawn view is twice as wide to give the ring and
    /// the listening ripples room.
    func orbSize(_ step: PreflightStep) -> CGFloat {
        switch step {
        case .welcome: short ? 124 : 160
        case .capabilities: short ? 72 : 92
        case .access, .engines: short ? 72 : 90
        case .rehearsal: short ? 132 : 176
        case .ready: short ? 88 : 128
        }
    }

    /// Where the destination apps sit, measured from the sphere's centre. Far enough out that no
    /// card ever touches the sphere's own ring, which sits at 0.65 × its nominal diameter.
    func orbitRadius(_ step: PreflightStep) -> CGFloat {
        orbSize(step) * (short ? 1.38 : 1.35)
    }

    var orbitCard: CGFloat { short ? 42 : 48 }
}

// MARK: - Root

struct PreflightView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PermissionCoordinator.self) private var permissions
    @Environment(ModelInstallationStore.self) private var modelInstallation
    @Environment(DictationSessionCoordinator.self) private var dictationSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var languageCode: String
    let previewCapsule: () -> Void
    let complete: () -> Void

    @AppStorage("voxol.openSetupOnNextHub") private var openSetupOnNextHub = false
    @AppStorage("voxol.dictationShortcut") private var dictationShortcutRaw =
        DictationShortcut.optionSpace.rawValue
    @State private var step = PreflightStep.welcome
    @State private var forwardTravel = true
    @State private var revealed = false
    @State private var bloom: Double = 0

    @State private var demoIndex = 0
    @State private var demoRawDissolve: Double = 0
    @State private var demoReadyArrival: Double = 1
    /// Which orbiting application VoxoL is currently explaining itself through.
    @State private var orbitHighlight = 0

    @State private var rehearsal = RehearsalState.idle
    /// Stays true once the gesture has been completed, so replaying it never locks the page.
    @State private var hasRehearsed = false
    @State private var rehearsalRawDissolve: Double = 0
    @State private var rehearsalReadyArrival: Double = 1
    @State private var holdBegan: Date?
    @State private var rehearsalTask: Task<Void, Never>?
    @State private var rehearsalWatchdog: Task<Void, Never>?
    /// The real pipeline's answer for the live rehearsal: raw transcript and finished text.
    @State private var liveRaw: String?
    @State private var livePolished: String?

    var body: some View {
        GeometryReader { geometry in
            let metrics = GrainMetrics(size: geometry.size)

            ZStack(alignment: .top) {
                GrainBackdrop(size: geometry.size, readiness: readiness)

                ZStack(alignment: .top) {
                    page(step, metrics: metrics)
                        .id(step)
                        .transition(pageTransition)
                }
                .reveal(revealed, delay: 0.25, reduceMotion: reduceMotion)

                sphere(metrics: metrics)
                    .reveal(revealed, delay: 0, reduceMotion: reduceMotion)

                chrome(metrics: metrics)
                    .reveal(revealed, delay: 0.45, reduceMotion: reduceMotion)

                dawnLine(width: geometry.size.width)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .ignoresSafeArea(.container, edges: .top)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(PreflightWindowChrome())
        .preferredColorScheme(.light)
        .tint(theme.ink)
        .task {
            if modelInstallation.items.isEmpty {
                await modelInstallation.load()
            }
        }
        .task {
            guard !reduceMotion else {
                revealed = true
                return
            }
            try? await Task.sleep(for: .milliseconds(160))
            revealed = true
        }
        .task(id: step) { await runWelcomeDemo() }
        .task(id: step) { await runOrbitHighlight() }
        .onChange(of: rehearsal) { _, state in
            switch state {
            case .idle, .holding, .tooShort:
                withAnimation(GrainMotion.quick) {
                    rehearsalRawDissolve = 0
                    rehearsalReadyArrival = 1
                }
            case .processing:
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.7)) {
                    rehearsalRawDissolve = 1
                }
            case .complete:
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.9)) {
                    rehearsalReadyArrival = 0
                }
            }
        }
        .onChange(of: dictationSession.state) { _, runtimeState in
            guard step == .rehearsal, liveRehearsalAvailable,
                rehearsal == .holding || rehearsal == .processing
            else {
                return
            }
            switch runtimeState {
            case .noSpeech:
                rehearsalWatchdog?.cancel()
                withAnimation(GrainMotion.quick) { rehearsal = .tooShort }
            case .failed, .captureNeedsModel:
                rehearsalWatchdog?.cancel()
                withAnimation(GrainMotion.quick) { rehearsal = .idle }
            default:
                break
            }
        }
        .onDisappear {
            rehearsalTask?.cancel()
            rehearsalWatchdog?.cancel()
            if dictationSession.rehearsalIsActive {
                dictationSession.cancelRehearsal()
            }
        }
    }

    // MARK: The sphere

    private func sphere(metrics: GrainMetrics) -> some View {
        let side = metrics.orbSize(step)
        return VoxoLGrainSphere(
            ring: ringValues,
            resolution: readiness,
            energy: sphereEnergy,
            bloom: bloom,
            paused: reduceMotion
        )
        .animation(reduceMotion ? nil : GrainMotion.settle, value: ringValues)
        .animation(reduceMotion ? nil : .linear(duration: 0.12), value: sphereEnergy)
        .frame(width: side * 2, height: side * 2)
        .contentShape(Circle().inset(by: side * 0.4))
        .gesture(holdGesture, isEnabled: step == .rehearsal)
        .accessibilityHidden(step != .rehearsal)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("Hold to try"))
        .accessibilityAction(named: Text("Run the demonstration")) { completeRehearsalQuietly() }
        .overlay {
            if step == .capabilities {
                AppOrbit(
                    apps: destinations,
                    highlight: orbitHighlight,
                    radius: metrics.orbitRadius(step),
                    card: metrics.orbitCard,
                    paused: reduceMotion
                )
                .transition(.opacity)
            }
        }
        .frame(height: metrics.orbRegion(step))
        .frame(maxWidth: .infinity)
        .padding(.top, metrics.chromeTop)
    }

    /// While a live rehearsal is being held, the grain moves with the actual microphone level.
    private var sphereEnergy: Double {
        guard rehearsal == .holding else { return 0 }
        guard liveRehearsalAvailable else { return 1 }
        return 0.35 + min(0.65, Double(dictationSession.liveInputLevel) * 2.6)
    }

    /// The real pipeline can rehearse only once the microphone and the model are actually there.
    private var liveRehearsalAvailable: Bool {
        permissions.status(for: .microphone) == .granted && modelInstallation.allInstalled
    }

    private var selectedShortcut: DictationShortcut {
        DictationShortcut(rawValue: dictationShortcutRaw) ?? .optionSpace
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in beginHold() }
            .onEnded { _ in endHold() }
    }

    // MARK: Pages

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let entering: CGFloat = forwardTravel ? 42 : -42
        let exiting: CGFloat = forwardTravel ? -30 : 30
        return .asymmetric(
            insertion: .modifier(
                active: StepEffect(visible: false, offset: entering),
                identity: StepEffect(visible: true, offset: entering)
            ),
            removal: .modifier(
                active: StepEffect(visible: false, offset: exiting),
                identity: StepEffect(visible: true, offset: exiting)
            )
        )
    }

    private func page(_ step: PreflightStep, metrics: GrainMetrics) -> some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: metrics.chromeTop + metrics.orbRegion(step))

            Group {
                switch step {
                case .welcome: welcomePage(metrics: metrics)
                case .capabilities: capabilitiesPage(metrics: metrics)
                case .access: accessPage(metrics: metrics)
                case .engines: enginesPage(metrics: metrics)
                case .rehearsal: rehearsalPage(metrics: metrics)
                case .ready: readyPage(metrics: metrics)
                }
            }
            .frame(width: metrics.columnWidth)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(.bottom, metrics.chromeBottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func headline(
        _ step: PreflightStep,
        title: LocalizedStringKey,
        support: LocalizedStringKey?,
        metrics: GrainMetrics
    ) -> some View {
        VStack(spacing: 0) {
            Text(step.eyebrow)
                .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .caption))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(theme.secondaryInk)

            Text(title)
                .font(
                    VoxoLTypography.font(
                        size: metrics.headlineSize,
                        weight: .semibold,
                        relativeTo: .largeTitle
                    )
                )
                .tracking(metrics.compact ? -0.8 : -1.4)
                .foregroundStyle(theme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            if let support {
                Text(support)
                    .font(VoxoLTypography.font(size: 14, relativeTo: .body))
                    .foregroundStyle(theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    // MARK: 01 · Welcome

    private func welcomePage(metrics: GrainMetrics) -> some View {
        VStack(spacing: 0) {
            headline(
                .welcome,
                title: "Speak. VoxoL writes.",
                support: nil,
                metrics: metrics
            )

            GrainSentence(
                raw: PreflightExample.samples[demoIndex].raw,
                ready: PreflightExample.samples[demoIndex].ready,
                rawDissolve: demoRawDissolve,
                readyArrival: demoReadyArrival,
                font: VoxoLTypography.font(size: 17, relativeTo: .body),
                rawTone: theme.secondaryInk,
                readyTone: theme.ink
            )
            .frame(height: metrics.short ? 58 : 72)
            .padding(.top, metrics.short ? 20 : 30)

            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("No account. Nothing leaves this Mac.")
                    .font(VoxoLTypography.font(size: 12, weight: .medium, relativeTo: .caption))
            }
            .foregroundStyle(theme.secondaryInk)
            .padding(.top, metrics.short ? 14 : 22)

            VStack(spacing: 10) {
                Text("Interface language")
                    .font(VoxoLTypography.font(size: 11, weight: .semibold, relativeTo: .caption))
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(theme.secondaryInk)

                HStack(spacing: 10) {
                    languagePill(.french)
                    languagePill(.english)
                }
            }
            .padding(.top, metrics.short ? 18 : 28)
        }
    }

    private func languagePill(_ language: AppLanguage) -> some View {
        let selected = currentLanguage == language
        return Button {
            withAnimation(GrainMotion.quick) { languageCode = language.rawValue }
        } label: {
            Text(verbatim: language.displayName)
                .font(VoxoLTypography.font(size: 13, weight: .semibold, relativeTo: .body))
                .foregroundStyle(selected ? theme.canvas : theme.ink)
                .padding(.horizontal, 18)
                .frame(height: 36)
                .background(Capsule().fill(selected ? theme.ink : theme.surface))
                .overlay(Capsule().stroke(selected ? Color.clear : theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: 02 · What it does

    private func capabilitiesPage(metrics: GrainMetrics) -> some View {
        VStack(spacing: 0) {
            headline(
                .capabilities,
                title: "It writes like the app you are in.",
                support: highlightedDestination?.promise
                    ?? "VoxoL reads which app you are writing in and shapes the text for it.",
                metrics: metrics
            )
            .animation(GrainMotion.settle, value: orbitHighlight)

            HStack(alignment: .top, spacing: 10) {
                FeatureTile(
                    symbol: "character.book.closed",
                    title: "Your vocabulary",
                    subtitle: "Names, jargon and acronyms spelled your way"
                )
                FeatureTile(
                    symbol: "bolt.horizontal",
                    title: "Voice shortcuts",
                    subtitle: "Say a cue, VoxoL inserts the exact block"
                )
                FeatureTile(
                    symbol: "lock.shield",
                    title: "Secure fields skipped",
                    subtitle: "Password fields are never read"
                )
            }
            .padding(.top, metrics.short ? 16 : 26)
        }
    }

    /// The applications actually installed on this Mac, discovered once.
    private var destinations: [DestinationApp] {
        DestinationRoster.installed
    }

    private var highlightedDestination: DestinationApp? {
        let apps = destinations
        guard !apps.isEmpty else { return nil }
        return apps[min(orbitHighlight, apps.count - 1)]
    }

    private func runOrbitHighlight() async {
        guard step == .capabilities, !reduceMotion, destinations.count > 1 else { return }
        while !Task.isCancelled, step == .capabilities {
            do {
                try await Task.sleep(for: .milliseconds(2_600))
            } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(GrainMotion.settle) {
                orbitHighlight = (orbitHighlight + 1) % destinations.count
            }
        }
    }

    // MARK: 03 · Access

    private func accessPage(metrics: GrainMetrics) -> some View {
        VStack(spacing: 0) {
            headline(
                .access,
                title: "Three permissions. Nothing more.",
                support: "Each permission maps to one visible action that you trigger yourself.",
                metrics: metrics
            )

            VStack(spacing: 10) {
                permissionRow(
                    .microphone,
                    symbol: "mic.fill",
                    title: "Microphone",
                    subtitle: "Hears you while the shortcut is held"
                )
                permissionRow(
                    .accessibility,
                    symbol: "text.cursor",
                    title: "Accessibility",
                    subtitle: "Places the finished text in the active field"
                )
                permissionRow(
                    .inputMonitoring,
                    symbol: "command",
                    title: "Input Monitoring",
                    subtitle: "Detects \(selectedShortcut.label) in any app"
                )
            }
            .padding(.top, metrics.short ? 18 : 28)
        }
    }

    private func permissionRow(
        _ permission: VoxoLPermission,
        symbol: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey
    ) -> some View {
        let status = permissions.status(for: permission)
        return GlassRow(symbol: symbol, title: title, subtitle: subtitle) {
            switch status {
            case .granted:
                RowBadge(text: "Allowed", symbol: "checkmark.circle.fill", tone: theme.success)
            case .requesting where permission == .microphone:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting…")
                        .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                }
            case .requesting:
                Button("Open Settings") {
                    permissions.openSystemSettings(for: permission)
                }
                .buttonStyle(GrainRowButtonStyle())
            case .denied:
                Button("Open Settings") {
                    permissions.openSystemSettings(for: permission)
                }
                .buttonStyle(GrainRowButtonStyle())
            case .restricted:
                Text("Unavailable")
                    .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
            case .notRequested:
                Button("Allow") {
                    Task { await permissions.request(permission) }
                }
                .buttonStyle(GrainRowButtonStyle(prominent: true))
            }
        }
    }

    // MARK: 04 · Model

    private func enginesPage(metrics: GrainMetrics) -> some View {
        VStack(spacing: 0) {
            headline(
                .engines,
                title: "One model. Fully local.",
                support: "About 1.3 GB, downloaded and verified once.",
                metrics: metrics
            )

            modelRow
                .padding(.top, metrics.short ? 18 : 28)
        }
    }

    /// The two runtime engines presented as what they are to the user: the VoxoL model, one
    /// download with one real, aggregated progress.
    private var modelRow: some View {
        let items = modelInstallation.items
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.totalBytes }
        let downloadedBytes = items.reduce(Int64(0)) {
            $0 + ($1.phase == .installed ? $1.totalBytes : $1.downloadedBytes)
        }
        let progress = totalBytes > 0 ? Double(downloadedBytes) / Double(totalBytes) : 0
        let anyDownloading = items.contains { $0.phase == .downloading }
        let anyVerifying = items.contains { $0.phase == .verifying }
        let anyPaused = items.contains { $0.phase == .paused }
        let anyFailed = items.contains { $0.phase == .failed }
        let anyAwaiting = items.contains { $0.phase == .awaitingVerifiedArtifact }
        let anyReady = items.contains { $0.phase == .readyToDownload }
        let installed = modelInstallation.allInstalled && !items.isEmpty

        return GlassRow(
            symbol: "cpu",
            title: "The VoxoL model",
            subtitle: "From voice to finished text, on this Mac",
            trailing: {
                if installed {
                    RowBadge(
                        verbatim: Self.byteText(totalBytes),
                        symbol: "checkmark.circle.fill",
                        tone: theme.success
                    )
                } else if anyFailed {
                    Button("Retry") { installMissingModelParts() }
                        .buttonStyle(GrainRowButtonStyle(tone: theme.coral))
                } else if anyDownloading {
                    Button("Pause") { pauseModelDownloads() }
                        .buttonStyle(GrainRowButtonStyle())
                } else if anyVerifying {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Verifying SHA-256…")
                            .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                            .foregroundStyle(theme.secondaryInk)
                    }
                } else if anyPaused {
                    Button("Resume") { installMissingModelParts() }
                        .buttonStyle(GrainRowButtonStyle(prominent: true))
                } else if anyReady {
                    Button("Download") { installMissingModelParts() }
                        .buttonStyle(GrainRowButtonStyle(prominent: true))
                } else if anyAwaiting {
                    Text("Artifact pending")
                        .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                } else {
                    Text("Checking local files…")
                        .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                }
            },
            footer: {
                if anyDownloading || anyPaused {
                    ModelProgressFooter(
                        progress: progress,
                        downloadedBytes: downloadedBytes,
                        totalBytes: totalBytes,
                        paused: !anyDownloading
                    )
                }
            }
        )
    }

    private func installMissingModelParts() {
        for item in modelInstallation.items where item.phase != .installed {
            guard item.phase != .downloading, item.phase != .verifying else { continue }
            modelInstallation.install(item.id)
        }
    }

    private func pauseModelDownloads() {
        for item in modelInstallation.items where item.phase == .downloading {
            modelInstallation.pause(item.id)
        }
    }

    private var modelProgressFraction: Double {
        let items = modelInstallation.items
        let total = items.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return 0 }
        let downloaded = items.reduce(Int64(0)) {
            $0 + ($1.phase == .installed ? $1.totalBytes : $1.downloadedBytes)
        }
        return Double(downloaded) / Double(total)
    }

    private static func byteText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: 05 · Rehearsal

    private func rehearsalPage(metrics: GrainMetrics) -> some View {
        VStack(spacing: 0) {
            Text(rehearsalPrompt)
                .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .caption))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(rehearsalPromptTone)
                .contentTransition(.opacity)
                .animation(GrainMotion.quick, value: rehearsal)
                .padding(.bottom, metrics.short ? 14 : 20)

            headline(
                .rehearsal,
                title: "Hold. Speak. Release.",
                support: liveRehearsalAvailable
                    ? "Hold the sphere and speak — the real pipeline runs on this Mac."
                    : "This guided demonstration records no audio.",
                metrics: metrics
            )

            rehearsalStage(metrics: metrics)
                .padding(.top, metrics.short ? 16 : 24)

            HStack(spacing: 10) {
                Text("Shortcut")
                    .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                shortcutPill(.optionSpace)
                shortcutPill(.controlSpace)

                if rehearsal == .complete {
                    Text(verbatim: "·")
                        .foregroundStyle(theme.secondaryInk)
                    Button("Preview the capsule") { previewCapsule() }
                        .buttonStyle(GrainQuietButtonStyle())
                }
            }
            .padding(.top, metrics.short ? 12 : 18)
            .animation(GrainMotion.settle, value: rehearsal == .complete)
        }
    }

    /// What sits under the rehearsal headline: the live pipeline when it can actually run, the
    /// guided demonstration otherwise.
    @ViewBuilder
    private func rehearsalStage(metrics: GrainMetrics) -> some View {
        if liveRehearsalAvailable {
            Group {
                switch rehearsal {
                case .idle, .tooShort:
                    VStack(spacing: 6) {
                        Text("Try saying")
                            .font(
                                VoxoLTypography.font(
                                    size: 11, weight: .semibold, relativeTo: .caption)
                            )
                            .textCase(.uppercase)
                            .tracking(1)
                            .foregroundStyle(theme.secondaryInk)
                        Text("Um, move the check-in to Tuesday—no, Thursday at nine.")
                            .font(VoxoLTypography.font(size: 16, relativeTo: .body))
                            .foregroundStyle(theme.ink)
                            .multilineTextAlignment(.center)
                    }
                case .holding:
                    Group {
                        if dictationSession.livePartialTranscript.isEmpty {
                            Text("Listening")
                                .foregroundStyle(theme.secondaryInk)
                        } else {
                            Text(verbatim: dictationSession.livePartialTranscript)
                                .foregroundStyle(theme.ink)
                        }
                    }
                    .font(VoxoLTypography.font(size: 17, relativeTo: .body))
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                case .processing:
                    ProgressView()
                        .controlSize(.small)
                case .complete:
                    VStack(alignment: .leading, spacing: 10) {
                        comparisonLine(
                            label: "Before",
                            text: liveRaw ?? "",
                            tone: theme.secondaryInk
                        )
                        comparisonLine(
                            label: "After",
                            text: livePolished ?? "",
                            tone: theme.ink,
                            emphasized: true
                        )
                    }
                }
            }
            .frame(minHeight: metrics.short ? 64 : 84, alignment: .center)
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 12) {
                GrainSentence(
                    raw: "Um, move the check-in to Tuesday—no, Thursday at nine.",
                    ready: "Move the check-in to Thursday at 9 a.m.",
                    rawDissolve: rehearsalRawDissolve,
                    readyArrival: rehearsalReadyArrival,
                    font: VoxoLTypography.font(size: 16, relativeTo: .body),
                    rawTone: theme.secondaryInk,
                    readyTone: theme.ink
                )
                .frame(height: metrics.short ? 48 : 60)

                Text("Install the model and allow the microphone to rehearse live.")
                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
            }
        }
    }

    private func comparisonLine(
        label: LocalizedStringKey,
        text: String,
        tone: Color,
        emphasized: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(VoxoLTypography.font(size: 11, weight: .semibold, relativeTo: .caption))
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(theme.secondaryInk)
                .frame(width: 56, alignment: .trailing)
            Text(verbatim: text)
                .font(
                    VoxoLTypography.font(
                        size: emphasized ? 16 : 14,
                        weight: emphasized ? .semibold : .regular,
                        relativeTo: .body
                    )
                )
                .foregroundStyle(tone)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shortcutPill(_ shortcut: DictationShortcut) -> some View {
        let selected = selectedShortcut == shortcut
        return Button {
            withAnimation(GrainMotion.quick) { dictationShortcutRaw = shortcut.rawValue }
        } label: {
            Text(verbatim: shortcut.label)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(selected ? theme.canvas : theme.ink)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(Capsule().fill(selected ? theme.ink : theme.raisedSurface))
                .overlay(Capsule().stroke(selected ? Color.clear : theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(shortcut.localizedTitle))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var rehearsalPrompt: LocalizedStringKey {
        switch rehearsal {
        case .idle: "Hold to try"
        case .holding: "Listening"
        case .tooShort: "Keep holding while you speak."
        case .processing: "Preparing text"
        case .complete: "Gesture complete"
        }
    }

    private var rehearsalPromptTone: Color {
        switch rehearsal {
        case .holding: theme.coral
        case .complete: theme.success
        default: theme.secondaryInk
        }
    }

    // MARK: 06 · Ready

    private func readyPage(metrics: GrainMetrics) -> some View {
        VStack(spacing: 0) {
            headline(
                .ready,
                title: setupReady ? "Everything is ready. Just speak." : "Almost there.",
                support: setupReady
                    ? "Press \(selectedShortcut.label) in any app and start speaking."
                    : "Finish the remaining steps whenever you like.",
                metrics: metrics
            )

            VStack(spacing: 10) {
                GlassRow(
                    symbol: "hand.raised.fill",
                    title: "Permissions",
                    subtitle: permissions.requiredPermissionsGranted
                        ? "macOS access ready" : "Review missing access"
                ) {
                    readyBadge(
                        done: permissions.requiredPermissionsGranted,
                        count: "\(grantedCount)/3"
                    )
                }
                GlassRow(
                    symbol: "cpu",
                    title: "Model",
                    subtitle: modelInstallation.allInstalled
                        ? "Installed locally" : "Installation required"
                ) {
                    readyBadge(
                        done: modelInstallation.allInstalled,
                        count: "\(Int(modelProgressFraction * 100)) %"
                    )
                }
                GlassRow(
                    symbol: "keyboard",
                    title: "Shortcut",
                    subtitle: dictationSession.shortcutIsActive
                        ? "Shortcut ready" : "Allow Input Monitoring"
                ) {
                    readyBadge(
                        done: dictationSession.shortcutIsActive,
                        count: selectedShortcut.label
                    )
                }
            }
            .padding(.top, metrics.short ? 18 : 28)
        }
    }

    private func readyBadge(done: Bool, count: String) -> some View {
        HStack(spacing: 7) {
            Text(verbatim: count)
                .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(done ? theme.success : theme.secondaryInk)
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(done ? theme.success : theme.secondaryInk)
        }
    }

    private var grantedCount: Int {
        VoxoLPermission.allCases.count { permissions.status(for: $0) == .granted }
    }

    // MARK: Chrome

    private func chrome(metrics: GrainMetrics) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(verbatim: "voxol")
                    .font(VoxoLTypography.font(size: 17, weight: .semibold, relativeTo: .headline))
                    .tracking(-0.4)
                    .foregroundStyle(theme.ink)

                Spacer()

                HStack(spacing: 7) {
                    Circle()
                        .fill(theme.success)
                        .frame(width: 6, height: 6)
                    Text("On this Mac")
                        .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                }

                if step != .welcome {
                    Button(action: cycleLanguage) {
                        Text(verbatim: currentLanguage.displayName)
                            .font(
                                VoxoLTypography.font(
                                    size: 12, weight: .semibold, relativeTo: .caption)
                            )
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, 11)
                            .frame(height: 28)
                            .background(
                                Capsule().stroke(theme.ink.opacity(0.22), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Language"))
                }
            }
            .frame(height: metrics.chromeTop, alignment: .center)

            Spacer(minLength: 0)

            HStack(spacing: 16) {
                Button("Back", action: goBack)
                    .buttonStyle(GrainQuietButtonStyle())
                    .opacity(step == .welcome ? 0 : 1)
                    .disabled(step == .welcome)

                Spacer(minLength: 8)

                stepDots

                Spacer(minLength: 8)

                // Never disabled. The rehearsal is worth doing and the label says so until it
                // has been, but a gesture that can fail for reasons outside the user's control —
                // a quiet microphone, a model still downloading, a hold read as a click — must
                // never be the thing standing between them and their app.
                Button(action: goForward) {
                    HStack(spacing: 9) {
                        Text(forwardLabel)
                        EditorialIcon(name: "arrow-right", size: 16)
                    }
                }
                .buttonStyle(GrainPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .frame(height: metrics.chromeBottom)
        }
        .padding(.horizontal, metrics.margin)
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(PreflightStep.allCases) { item in
                let passed = item.rawValue < step.rawValue
                let current = item == step
                Capsule()
                    .fill(
                        current
                            ? theme.ink
                            : (passed ? theme.ink.opacity(0.45) : theme.ink.opacity(0.16))
                    )
                    .frame(width: current ? 20 : 7, height: 7)
                    .shadow(
                        color: current ? theme.ink.opacity(0.25) : .clear,
                        radius: 3
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("Step \(step.rawValue + 1) of \(PreflightStep.allCases.count)")
        )
    }

    /// The thread of ink spreading along the top edge as the preflight advances.
    private func dawnLine(width: CGFloat) -> some View {
        let fraction = (Double(step.rawValue) + 1) / Double(PreflightStep.allCases.count)
        return Rectangle()
            .fill(
                LinearGradient(
                    colors: [theme.coral, theme.cobalt],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: max(0, width * fraction), height: 2)
            .shadow(color: theme.coral.opacity(0.3), radius: 3, y: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: State

    private func gate(_ permission: VoxoLPermission) -> GateState {
        switch permissions.status(for: permission) {
        case .granted: .online
        case .requesting: .working
        case .restricted: .blocked
        case .notRequested, .denied: .missing
        }
    }

    private func gate(_ role: RuntimeModelRole) -> GateState {
        guard let item = modelInstallation.items.first(where: { $0.id == role }) else {
            return .working
        }
        switch item.phase {
        case .installed: return .online
        case .downloading, .verifying, .loading: return .working
        case .readyToDownload, .paused: return .missing
        case .failed, .awaitingVerifiedArtifact: return .blocked
        }
    }

    /// The ring's six arcs: three permissions, two engines, the shortcut.
    private var ringValues: VoxoLRingVector {
        let gates: [GateState] = [
            gate(.microphone), gate(.accessibility), gate(.inputMonitoring),
            gate(.asr), gate(.polisher),
            dictationSession.shortcutIsActive ? .online : .missing,
        ]
        return VoxoLRingVector(
            values: gates.map { state in
                switch state {
                case .online: 1
                case .working: 0.42
                case .missing, .blocked: 0
                }
            }
        )
    }

    private var readiness: Double {
        ringValues.values.reduce(0, +) / Double(ringValues.values.count)
    }

    private var setupReady: Bool {
        permissions.requiredPermissionsGranted
            && modelInstallation.allInstalled
            && dictationSession.shortcutIsActive
    }

    private var forwardLabel: LocalizedStringKey {
        switch step {
        case .welcome: "Begin"
        case .capabilities: "Set up VoxoL"
        case .rehearsal: hasRehearsed ? "Continue" : "Skip the rehearsal"
        case .access, .engines: "Continue"
        case .ready: setupReady ? "Open VoxoL" : "Review remaining setup"
        }
    }

    private var currentLanguage: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .french
    }

    private func cycleLanguage() {
        languageCode =
            currentLanguage == .french ? AppLanguage.english.rawValue : AppLanguage.french.rawValue
    }

    // MARK: Travel

    private func goBack() {
        guard let previous = PreflightStep(rawValue: step.rawValue - 1) else { return }
        travel(to: previous)
    }

    private func goForward() {
        guard step != .ready else {
            openSetupOnNextHub = !setupReady
            complete()
            return
        }
        guard let next = PreflightStep(rawValue: step.rawValue + 1) else { return }
        travel(to: next)
    }

    private func travel(to destination: PreflightStep) {
        guard destination != step else { return }
        rehearsalTask?.cancel()
        rehearsalWatchdog?.cancel()
        if dictationSession.rehearsalIsActive {
            dictationSession.cancelRehearsal()
        }
        if rehearsal != .complete {
            rehearsal = .idle
        }
        forwardTravel = destination.rawValue > step.rawValue

        guard !reduceMotion else {
            step = destination
            return
        }

        withAnimation(GrainMotion.travel) { step = destination }
        withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.4)) { bloom = 1 }
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.85).delay(0.38)) { bloom = 0 }
    }

    // MARK: Rehearsal machine

    private func beginHold() {
        guard step == .rehearsal else { return }
        guard rehearsal != .holding, rehearsal != .processing else { return }
        rehearsalTask?.cancel()
        rehearsalWatchdog?.cancel()
        holdBegan = Date()

        if liveRehearsalAvailable {
            liveRaw = nil
            livePolished = nil
            dictationSession.beginRehearsal { raw, polished in
                liveRaw = raw
                livePolished = polished
                hasRehearsed = true
                rehearsalWatchdog?.cancel()
                withAnimation(GrainMotion.settle) { rehearsal = .complete }
                withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.35)) { bloom = 1 }
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.9).delay(0.32)) {
                    bloom = 0
                }
            }
        }

        withAnimation(GrainMotion.press) { rehearsal = .holding }
    }

    private func endHold() {
        guard rehearsal == .holding else { return }
        let held = Date().timeIntervalSince(holdBegan ?? Date())

        if liveRehearsalAvailable {
            guard held >= 0.45 else {
                dictationSession.cancelRehearsal()
                withAnimation(GrainMotion.quick) { rehearsal = .tooShort }
                return
            }
            dictationSession.endRehearsal()
            withAnimation(GrainMotion.quick) { rehearsal = .processing }
            rehearsalWatchdog = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(25))
                } catch { return }
                guard !Task.isCancelled, rehearsal == .processing else { return }
                dictationSession.cancelRehearsal()
                withAnimation(GrainMotion.quick) { rehearsal = .idle }
            }
            return
        }

        guard held >= 0.45 else {
            withAnimation(GrainMotion.quick) { rehearsal = .tooShort }
            return
        }

        withAnimation(GrainMotion.quick) { rehearsal = .processing }
        rehearsalTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch { return }
            guard !Task.isCancelled else { return }
            hasRehearsed = true
            withAnimation(GrainMotion.settle) { rehearsal = .complete }
            withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.35)) { bloom = 1 }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.9).delay(0.32)) { bloom = 0 }
            rehearsalTask = nil
        }
    }

    /// Accessibility path: performs the rehearsal without requiring a pointer hold.
    private func completeRehearsalQuietly() {
        guard step == .rehearsal else { return }
        rehearsalTask?.cancel()
        withAnimation(GrainMotion.quick) { rehearsal = .processing }
        rehearsalTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch { return }
            guard !Task.isCancelled else { return }
            hasRehearsed = true
            withAnimation(GrainMotion.settle) { rehearsal = .complete }
            rehearsalTask = nil
        }
    }

    // MARK: Welcome demonstration

    private func runWelcomeDemo() async {
        guard step == .welcome, !reduceMotion else {
            demoRawDissolve = 0
            demoReadyArrival = 1
            return
        }

        func pause(_ seconds: Double) async -> Bool {
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch { return false }
            return !Task.isCancelled && step == .welcome
        }

        demoRawDissolve = 0
        demoReadyArrival = 1
        guard await pause(1.6) else { return }

        while !Task.isCancelled, step == .welcome {
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.85)) { demoRawDissolve = 1 }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.9).delay(0.26)) {
                demoReadyArrival = 0
            }
            guard await pause(3.0) else { return }

            withAnimation(.timingCurve(0.4, 0, 0.8, 0.2, duration: 0.5)) { demoReadyArrival = 1 }
            guard await pause(0.44) else { return }

            demoIndex = (demoIndex + 1) % PreflightExample.samples.count
            demoRawDissolve = 1
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.66)) { demoRawDissolve = 0 }
            guard await pause(2.0) else { return }
        }
    }
}

// MARK: - Reveal

private struct RevealEffect: ViewModifier {
    let revealed: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 16)
            .animation(
                reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 1.1).delay(delay),
                value: revealed
            )
    }
}

extension View {
    fileprivate func reveal(_ revealed: Bool, delay: Double, reduceMotion: Bool) -> some View {
        modifier(RevealEffect(revealed: revealed, delay: delay, reduceMotion: reduceMotion))
    }
}

// MARK: - Step transition

private struct StepEffect: ViewModifier {
    let visible: Bool
    let offset: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .blur(radius: visible ? 0 : 10)
            .offset(y: visible ? 0 : offset)
            .scaleEffect(visible ? 1 : 0.985, anchor: .top)
    }
}

// MARK: - Backdrop

/// The page. Warm paper with the faintest breath of colour behind the sphere's region — the
/// atmosphere deepens a touch as readiness rises, but the surface always reads as paper.
private struct GrainBackdrop: View {
    @Environment(VoxoLTheme.self) private var theme

    let size: CGSize
    let readiness: Double

    var body: some View {
        ZStack {
            Rectangle()
                .fill(theme.canvas)

            VoxoLSignalField(
                mode: .transformation,
                secondaryMode: .ready,
                blend: readiness,
                cadence: .ambient,
                cellSize: 9
            )
            .opacity(0.3)

            RadialGradient(
                colors: [theme.coral.opacity(0.05 + readiness * 0.03), .clear],
                center: UnitPoint(x: 0.56, y: 0.2),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.4
            )

            RadialGradient(
                colors: [theme.cobalt.opacity(0.04 + readiness * 0.02), .clear],
                center: UnitPoint(x: 0.44, y: 0.26),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.5
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - The demonstration

private struct PreflightExample: Identifiable {
    let id: Int
    let raw: LocalizedStringKey
    let ready: LocalizedStringKey

    @MainActor static let samples = [
        PreflightExample(
            id: 0,
            raw: "Um, send it Tuesday—no, Wednesday morning.",
            ready: "Send it Wednesday morning."
        ),
        PreflightExample(
            id: 1,
            raw: "Hi Lea thanks for getting back to me we are good for Friday.",
            ready: "Hi Lea, thanks for getting back to me. We are good for Friday."
        ),
        PreflightExample(
            id: 2,
            raw: "The budget is four thousand five hundred euros.",
            ready: "The budget is €4,500."
        ),
    ]
}

/// Sinks a sentence into the dark glyph by glyph, or condenses it back out of the light.
private struct GlyphTide: TextRenderer {
    var progress: Double
    var rise: Double
    var seed: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let total = max(1, layout.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } })
        var index = 0

        for line in layout {
            for run in line {
                for slice in run {
                    defer { index += 1 }
                    let phase = sweep(index: index, total: total)

                    guard phase > 0.0005 else {
                        context.draw(slice)
                        continue
                    }
                    guard phase < 0.9995 else { continue }

                    var glyph = context
                    let rect = slice.typographicBounds.rect
                    let drift = (random(index, 1) - 0.5) * 16
                    let scale = 1 - 0.3 * phase

                    glyph.translateBy(
                        x: drift * phase,
                        y: (14 + 10 * random(index, 2)) * phase * rise
                    )
                    glyph.translateBy(x: rect.midX, y: rect.midY)
                    glyph.scaleBy(x: scale, y: scale)
                    glyph.translateBy(x: -rect.midX, y: -rect.midY)
                    glyph.opacity = 1 - phase
                    glyph.addFilter(.blur(radius: 5 * phase))
                    glyph.draw(slice)
                }
            }
        }
    }

    private func sweep(index: Int, total: Int) -> Double {
        let start = Double(index) / Double(total) * 0.5
        return min(max((progress - start) / 0.5, 0), 1)
    }

    private func random(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + Double(salt) * 78.233 + seed) * 43758.5453
        return value - value.rounded(.down)
    }
}

private struct GrainSentence: View {
    let raw: LocalizedStringKey
    let ready: LocalizedStringKey
    let rawDissolve: Double
    let readyArrival: Double
    let font: Font
    let rawTone: Color
    let readyTone: Color

    var body: some View {
        ZStack(alignment: .top) {
            Text(raw)
                .foregroundStyle(rawTone)
                .textRenderer(GlyphTide(progress: rawDissolve, rise: 1, seed: 11))
            Text(ready)
                .foregroundStyle(readyTone)
                .textRenderer(GlyphTide(progress: readyArrival, rise: -1, seed: 29))
        }
        .font(font)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Destinations

/// One application VoxoL can write into, with the writing profile it resolves to.
///
/// The profiles mirror `ProfileResolver.resolve` in TextProcessingKit: what the orbit promises is
/// what the pipeline actually does when the text lands in that application.
private struct DestinationApp: Identifiable, Equatable {
    enum Shape {
        case email
        case chat
        case developer
        case document
        case prompt
    }

    let id: String
    let name: String
    let icon: NSImage
    let shape: Shape

    var promise: LocalizedStringKey {
        switch shape {
        case .email: "In \(name), a structured message with a clean sign-off."
        case .chat: "In \(name), a short message that stays spoken."
        case .developer: "In \(name), technical terms and identifiers kept exact."
        case .document: "In \(name), clean paragraphs and real punctuation."
        case .prompt: "In \(name), a clear instruction without filler."
        }
    }

    static func == (lhs: DestinationApp, rhs: DestinationApp) -> Bool {
        lhs.id == rhs.id
    }
}

/// Finds the applications the user actually has, so the orbit is their Mac and not a stock image.
@MainActor
private enum DestinationRoster {
    private static let candidates: [(bundle: String, shape: DestinationApp.Shape)] = [
        ("com.apple.mail", .email),
        ("com.microsoft.Outlook", .email),
        ("com.tinyspeck.slackmacgap", .chat),
        ("com.apple.MobileSMS", .chat),
        ("com.hnc.Discord", .chat),
        ("com.apple.dt.Xcode", .developer),
        ("com.microsoft.VSCode", .developer),
        ("com.todesktop.230313mzl4w4u92", .developer),
        ("com.apple.Terminal", .developer),
        ("com.apple.Notes", .document),
        ("notion.id", .document),
        ("md.obsidian", .document),
        ("com.apple.Safari", .prompt),
        ("com.google.Chrome", .prompt),
        ("company.thebrowser.Browser", .prompt),
        ("com.openai.chat", .prompt),
    ]

    /// Up to seven installed applications, one per writing profile first so the orbit shows the
    /// full range before it shows a second browser.
    static let installed: [DestinationApp] = {
        var byShape: [DestinationApp.Shape: [DestinationApp]] = [:]
        var order: [DestinationApp.Shape] = []

        for candidate in candidates {
            guard let app = resolve(candidate.bundle, shape: candidate.shape) else { continue }
            if byShape[candidate.shape] == nil {
                byShape[candidate.shape] = []
                order.append(candidate.shape)
            }
            byShape[candidate.shape]?.append(app)
        }

        var result: [DestinationApp] = []
        var round = 0
        while result.count < 7 {
            var addedThisRound = false
            for shape in order {
                guard let apps = byShape[shape], round < apps.count else { continue }
                result.append(apps[round])
                addedThisRound = true
                if result.count == 7 { break }
            }
            guard addedThisRound else { break }
            round += 1
        }
        return result
    }()

    private static func resolve(_ bundle: String, shape: DestinationApp.Shape) -> DestinationApp? {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let name =
            FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return DestinationApp(id: bundle, name: name, icon: icon, shape: shape)
    }
}

/// The destination applications orbiting the sphere, one lit at a time.
private struct AppOrbit: View {
    @Environment(VoxoLTheme.self) private var theme

    let apps: [DestinationApp]
    let highlight: Int
    let radius: CGFloat
    let card: CGFloat
    let paused: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    theme.ink.opacity(0.14),
                    style: StrokeStyle(lineWidth: 1, dash: [1.5, 7])
                )
                .frame(width: radius * 2, height: radius * 2)

            TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { timeline in
                let spin =
                    paused
                    ? 0
                    : timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 3600) * 0.055

                ZStack {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        let angle =
                            spin - Double.pi / 2
                            + Double(index) / Double(max(1, apps.count)) * 2 * Double.pi
                        tile(app, active: index == highlight)
                            .offset(
                                x: cos(angle) * radius,
                                y: sin(angle) * radius
                            )
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Applications VoxoL adapts to"))
    }

    private func tile(_ app: DestinationApp, active: Bool) -> some View {
        Image(nsImage: app.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: card * 0.62, height: card * 0.62)
            .frame(width: card, height: card)
            .background(
                RoundedRectangle(cornerRadius: card * 0.29, style: .continuous)
                    .fill(theme.surface)
                    .shadow(
                        color: theme.ink.opacity(active ? 0.16 : 0.06),
                        radius: active ? 12 : 6,
                        y: active ? 5 : 2
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: card * 0.29, style: .continuous)
                    .stroke(active ? theme.ink.opacity(0.55) : theme.line, lineWidth: 1)
            )
            .saturation(active ? 1 : 0.45)
            .opacity(active ? 1 : 0.72)
            .scaleEffect(active ? 1.14 : 1)
            .animation(GrainMotion.settle, value: active)
    }
}

/// One capability, sold in three lines.
private struct FeatureTile: View {
    @Environment(VoxoLTheme.self) private var theme

    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.ink)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(theme.selection.opacity(0.85))
                )

            Text(title)
                .font(VoxoLTypography.font(size: 13, weight: .semibold, relativeTo: .body))
                .foregroundStyle(theme.ink)
                .padding(.top, 10)

            Text(subtitle)
                .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.ink.opacity(0.05), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.line, lineWidth: 1)
        )
    }
}

// MARK: - Glass rows

/// The only container of the direction: a sheet of the page's own paper, lifted just above it.
private struct GlassRow<Trailing: View, Footer: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.selection.opacity(0.85))
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.ink)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(VoxoLTypography.font(size: 14, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(theme.ink)
                    Text(subtitle)
                        .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                trailing
            }

            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.ink.opacity(0.05), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.line, lineWidth: 1)
        )
    }
}

extension GlassRow where Footer == EmptyView {
    fileprivate init(
        symbol: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.init(
            symbol: symbol,
            title: title,
            subtitle: subtitle,
            trailing: trailing,
            footer: { EmptyView() }
        )
    }
}

private struct RowBadge: View {
    let text: Text
    let symbol: String
    let tone: Color

    init(text: LocalizedStringKey, symbol: String, tone: Color) {
        self.text = Text(text)
        self.symbol = symbol
        self.tone = tone
    }

    init(verbatim: String, symbol: String, tone: Color) {
        self.text = Text(verbatim: verbatim)
        self.symbol = symbol
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
            text
                .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .caption))
        }
        .foregroundStyle(tone)
    }
}

/// The live download state, in the same grain as the dawn line: ink filling a paper track.
private struct ModelProgressFooter: View {
    @Environment(VoxoLTheme.self) private var theme

    let progress: Double
    let downloadedBytes: Int64
    let totalBytes: Int64
    let paused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.ink.opacity(0.1))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [theme.cobalt, theme.coral],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(3, geometry.size.width * progress))
                }
            }
            .frame(height: 3)
            .animation(GrainMotion.settle, value: progress)

            HStack {
                if paused {
                    Label("Paused · progress saved locally", systemImage: "pause.fill")
                        .labelStyle(.titleAndIcon)
                } else {
                    Text(verbatim: byteProgress)
                }
                Spacer()
                Text(verbatim: "\(Int(progress * 100)) %")
                    .monospacedDigit()
            }
            .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
            .foregroundStyle(theme.secondaryInk)
        }
        .padding(.top, 12)
    }

    private var byteProgress: String {
        let downloaded = ByteCountFormatter.string(
            fromByteCount: downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(downloaded) / \(total)"
    }
}

// MARK: - Controls

private struct GrainPrimaryButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoxoLTypography.font(size: 15, weight: .semibold, relativeTo: .body))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isEnabled ? theme.canvas : theme.secondaryInk)
            .padding(.leading, 21)
            .padding(.trailing, 17)
            .frame(minHeight: 46)
            .background(
                Capsule()
                    .fill(
                        isEnabled
                            ? (configuration.isPressed
                                ? theme.ink.opacity(0.85) : theme.ink)
                            : theme.ink.opacity(0.14)
                    )
            )
            .shadow(
                color: isEnabled ? theme.ink.opacity(0.18) : .clear,
                radius: 10,
                y: 3
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(GrainMotion.press, value: configuration.isPressed)
    }
}

private struct GrainQuietButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoxoLTypography.font(size: 13, weight: .medium, relativeTo: .body))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(configuration.isPressed ? theme.ink : theme.secondaryInk)
            .padding(.horizontal, 4)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
    }
}

private struct GrainRowButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme

    var prominent = false
    var tone: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .caption))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(tone ?? theme.ink)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(
                Capsule()
                    .fill(
                        theme.ink.opacity(
                            configuration.isPressed ? 0.2 : (prominent ? 0.13 : 0.07))
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        (tone ?? theme.ink).opacity(prominent ? 0.35 : 0.16),
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
            .animation(GrainMotion.press, value: configuration.isPressed)
    }
}

// MARK: - Window chrome

private final class PreflightWindowProbeView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}

private struct PreflightWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> PreflightWindowProbeView {
        let view = PreflightWindowProbeView(frame: .zero)
        view.windowChanged = hideWindowButtons
        DispatchQueue.main.async { hideWindowButtons(view.window) }
        return view
    }

    func updateNSView(_ nsView: PreflightWindowProbeView, context: Context) {
        hideWindowButtons(nsView.window)
    }

    static func dismantleNSView(_ nsView: PreflightWindowProbeView, coordinator: ()) {
        setWindowButtons(hidden: false, in: nsView.window)
    }

    private func hideWindowButtons(_ window: NSWindow?) {
        Self.setWindowButtons(hidden: true, in: window)
    }

    private static func setWindowButtons(hidden: Bool, in window: NSWindow?) {
        guard let window else { return }
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            window.standardWindowButton($0)?.isHidden = hidden
        }
    }
}

#Preview("Grain · minimum") {
    PreflightView(languageCode: .constant("fr"), previewCapsule: {}, complete: {})
        .frame(width: 820, height: 620)
        .environment(VoxoLTheme())
        .environment(PermissionCoordinator())
        .environment(ModelInstallationStore())
}

#Preview("Grain · default") {
    PreflightView(languageCode: .constant("fr"), previewCapsule: {}, complete: {})
        .frame(width: 1200, height: 780)
        .environment(VoxoLTheme())
        .environment(PermissionCoordinator())
        .environment(ModelInstallationStore())
}
