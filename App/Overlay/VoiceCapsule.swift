import AppKit
import Observation
import QuartzCore
import SwiftUI

enum VoiceCapsulePhase: String, CaseIterable, Identifiable {
    case listening
    case speechDetected
    case transcribing
    case polishing
    case inserting
    case success
    case copiedFallback
    case noSpeech
    case tooQuiet
    case tooLoud
    case learned
    case error

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .listening:
            "Listening…"
        case .speechDetected:
            "Got it"
        case .transcribing:
            "Transcribing…"
        case .polishing:
            "Refining…"
        case .inserting:
            "Inserting…"
        case .success:
            "Inserted"
        case .copiedFallback:
            "Copied · press ⌘V"
        case .noSpeech:
            "No speech heard"
        case .tooQuiet:
            "Weak signal — closer to the mic?"
        case .tooLoud:
            "Input too loud — lower the gain"
        case .learned:
            // Placeholder only: the rendered label interpolates the term.
            "New word learned"
        case .error:
            "Something went wrong"
        }
    }

    /// Sized for the longest translation of each label, not the English one: French runs about a
    /// third wider ("Transcription…", "Mise en forme…") and the capsule never truncates.
    var panelSize: NSSize {
        switch self {
        case .listening:
            NSSize(width: 142, height: 48)
        case .speechDetected:
            NSSize(width: 126, height: 48)
        case .transcribing:
            NSSize(width: 186, height: 48)
        case .polishing:
            NSSize(width: 190, height: 48)
        case .inserting:
            NSSize(width: 158, height: 48)
        case .success:
            NSSize(width: 48, height: 48)
        case .copiedFallback:
            NSSize(width: 216, height: 48)
        case .noSpeech:
            NSSize(width: 212, height: 48)
        case .tooQuiet:
            NSSize(width: 292, height: 48)
        case .tooLoud:
            NSSize(width: 300, height: 48)
        case .learned:
            NSSize(width: 260, height: 48)
        case .error:
            NSSize(width: 244, height: 48)
        }
    }
}

enum VoiceCapsuleFailure: CaseIterable {
    case microphoneUnavailable
    case modelsUnavailable
    case transcriptionFailed
    case insertionFailed

    var label: LocalizedStringKey {
        switch self {
        case .microphoneUnavailable:
            "Microphone unavailable"
        case .modelsUnavailable:
            "Models unavailable"
        case .transcriptionFailed:
            "Couldn’t transcribe"
        case .insertionFailed:
            "Couldn’t insert text"
        }
    }
}

@MainActor
@Observable
final class VoiceCapsuleModel {
    var phase = VoiceCapsulePhase.listening
    var failure = VoiceCapsuleFailure.transcriptionFailed
    var inputLevel: Float = 0
    /// The word behind a `.learned` toast.
    var learnedTerm = ""
}

@MainActor
final class VoiceCapsuleController {
    static let shared = VoiceCapsuleController()

    private let model = VoiceCapsuleModel()
    private var panel: NSPanel?
    private var previewTask: Task<Void, Never>?

    private init() {}

    func prepare() {
        guard panel == nil else {
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: model.phase.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: VoiceCapsuleRootView(model: model))
        self.panel = panel
    }

    func show(_ phase: VoiceCapsulePhase) {
        previewTask?.cancel()
        previewTask = nil
        prepare()
        transition(to: phase, animated: panel?.isVisible == true)
        panel?.orderFrontRegardless()
    }

    func updateInputLevel(_ level: Float) {
        model.inputLevel = min(1, max(0, level))
    }

    /// Briefly confirms a word the dictionary just learned on its own.
    ///
    /// Self-dismissing, because it arrives outside the dictation flow —
    /// seconds after insertion, when nothing else is scheduled to close the
    /// capsule. It also yields: if a new dictation starts meanwhile, the phase
    /// has moved on and the delayed dismissal below leaves it alone.
    func showLearnedWord(_ term: String) {
        model.learnedTerm = term
        show(.learned)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2_400))
            guard let self, self.model.phase == .learned else { return }
            self.dismiss()
        }
    }

    func showError(_ failure: VoiceCapsuleFailure) {
        model.failure = failure
        show(.error)
    }

    func playPreview() {
        prepare()
        previewTask?.cancel()
        transition(to: .listening, animated: panel?.isVisible == true)
        panel?.orderFrontRegardless()

        previewTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let sequence: [(VoiceCapsulePhase, Duration)] = [
                (.speechDetected, .milliseconds(820)),
                (.transcribing, .milliseconds(360)),
                (.polishing, .milliseconds(460)),
                (.inserting, .milliseconds(420)),
                (.success, .milliseconds(300)),
            ]

            for (phase, delay) in sequence {
                guard await wait(for: delay) else {
                    return
                }
                transition(to: phase, animated: true)
            }

            guard await wait(for: .milliseconds(620)) else {
                return
            }
            panel?.orderOut(nil)
        }
    }

    func dismiss() {
        previewTask?.cancel()
        previewTask = nil
        panel?.orderOut(nil)
    }

    private func transition(to phase: VoiceCapsulePhase, animated: Bool) {
        model.phase = phase
        guard let panel, let frame = frame(for: phase.panelSize) else {
            return
        }

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func wait(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func frame(for size: NSSize) -> NSRect? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }
        let visibleFrame = screen.visibleFrame
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 42,
            width: size.width,
            height: size.height
        )
    }
}

private struct VoiceCapsuleRootView: View {
    @State private var theme = VoxoLTheme()
    @AppStorage("voxol.interfaceLanguage") private var languageCode = AppLanguage.preferred.rawValue

    let model: VoiceCapsuleModel

    var body: some View {
        VoiceCapsulePanelView(model: model)
            .padding(4)
            .environment(theme)
            .environment(\.locale, selectedLanguage.locale)
            // The capsule is the same paper as the rest of VoxoL, whatever the system appearance
            // of the app it floats over.
            .preferredColorScheme(.light)
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }
}

private struct VoiceCapsulePanelView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let model: VoiceCapsuleModel

    var body: some View {
        Group {
            if model.phase == .success {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.success)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else {
                HStack(spacing: 8) {
                    leadingState
                        .frame(width: 24, height: 24)

                    Text(currentLabel)
                        .font(
                            VoxoLTypography.font(
                                size: 12.5, weight: .semibold, relativeTo: .caption)
                        )
                        .foregroundStyle(labelTone)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                        .id(labelIdentity)
                        .transition(.opacity)
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Warm paper with the page's own grain in it, not a glass slab.
            ZStack {
                Capsule().fill(
                    reduceTransparency ? theme.surface : theme.surface.opacity(0.96)
                )
                VoxoLGrainTexture(pitch: 3, intensity: reduceTransparency ? 0.5 : 0.85)
                    .clipShape(Capsule())
            }
        }
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(theme.line, lineWidth: 1)
        }
        .shadow(color: theme.ink.opacity(0.16), radius: 12, y: 5)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.phase)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(currentLabel))
    }

    private var currentLabel: LocalizedStringKey {
        switch model.phase {
        case .error:
            model.failure.label
        case .learned:
            "Learned: \(model.learnedTerm)"
        default:
            model.phase.label
        }
    }

    private var labelIdentity: String {
        model.phase == .error ? "error-\(String(describing: model.failure))" : model.phase.rawValue
    }

    private var labelTone: Color {
        switch model.phase {
        case .error:
            theme.recording
        case .noSpeech:
            theme.coral
        case .copiedFallback:
            theme.warning
        default:
            theme.ink
        }
    }

    /// The same mark the rest of VoxoL is built from, at 24 pt. Its state is the pipeline's
    /// state: loose grain while nothing has been heard, live and rippling while you speak, the
    /// light sweeping round it while the model works, crisp once the text is ready.
    @ViewBuilder
    private var leadingState: some View {
        switch model.phase {
        case .listening, .speechDetected, .transcribing, .polishing, .inserting, .noSpeech:
            VoxoLGrainSphere(
                resolution: sphereResolution,
                energy: sphereEnergy,
                radiusFactor: 0.46,
                cellDivisor: 7,
                churn: sphereChurn,
                showsRing: false,
                paused: reduceMotion
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: sphereResolution)
            .animation(reduceMotion ? nil : .linear(duration: 0.1), value: sphereEnergy)
        case .success:
            EmptyView()
        case .copiedFallback:
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(theme.warning)
        case .tooQuiet:
            Image(systemName: "mic.badge.xmark")
                .foregroundStyle(theme.warning)
        case .tooLoud:
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundStyle(theme.warning)
        case .learned:
            Image(systemName: "sparkles")
                .foregroundStyle(theme.success)
        case .error:
            Image(systemName: "exclamationmark")
                .foregroundStyle(theme.recording)
        }
    }

    /// How gathered the grain is: nothing heard yet reads as loose, finished text as crisp.
    private var sphereResolution: Double {
        switch model.phase {
        case .noSpeech: 0.05
        case .listening: 0.3
        case .speechDetected: 0.55
        case .transcribing: 0.6
        case .polishing: 0.8
        case .inserting: 0.95
        default: 1
        }
    }

    /// Live voice moving through the grain, from the real microphone meter.
    private var sphereEnergy: Double {
        guard model.phase == .listening || model.phase == .speechDetected else { return 0 }
        let decibels = 20 * log10(max(Double(model.inputLevel), 0.000_1))
        let meter = min(1, max(0, (decibels + 55) / 45))
        return 0.22 + 0.78 * meter
    }

    /// Work in progress: the light sweeps round the form while the model runs.
    private var sphereChurn: Double {
        switch model.phase {
        case .transcribing, .polishing: 1
        case .inserting: 0.4
        default: 0
        }
    }
}

#Preview("Capsule states") {
    VStack(spacing: 12) {
        ForEach(VoiceCapsulePhase.allCases) { phase in
            VoiceCapsulePanelView(model: previewModel(phase))
                .frame(width: phase.panelSize.width - 8, height: phase.panelSize.height - 8)
        }
    }
    .padding(30)
    .background(Color.gray.opacity(0.2))
    .environment(VoxoLTheme())
}

@MainActor
private func previewModel(_ phase: VoiceCapsulePhase) -> VoiceCapsuleModel {
    let model = VoiceCapsuleModel()
    model.phase = phase
    return model
}
