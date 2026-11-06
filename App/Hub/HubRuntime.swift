import SwiftUI

// What the dictation runtime is doing, worded once for every surface that shows it, and the
// gesture that lets any of those surfaces start a dictation.

/// How the runtime's state reads on screen: one wording and one colour, shared by every surface
/// that shows it, so Today and the sidebar can never disagree.
@MainActor
struct EditorialRuntimePresentation {
    let state: DictationRuntimeState
    let lastError: String?

    init(_ session: DictationSessionCoordinator) {
        state = session.state
        lastError = session.lastError
    }

    var isListening: Bool {
        switch state {
        case .listening, .speechDetected: true
        default: false
        }
    }

    var isActive: Bool {
        switch state {
        case .listening, .speechDetected, .transcribing, .polishing, .inserting: true
        default: false
        }
    }

    var signalMode: HubSignalMode {
        switch state {
        case .listening, .speechDetected: .voice
        case .transcribing, .polishing, .inserting: .processing
        default: .idle
        }
    }

    /// What the runtime is doing, named for what it is.
    ///
    /// A dictation that failed is not a broken setup: saying "setup required" after one bad
    /// insertion sends the user hunting through permissions for a problem that is not there.
    var title: LocalizedStringKey {
        switch state {
        case .listening, .speechDetected: "Listening"
        case .transcribing, .polishing, .inserting: "Preparing locally"
        case .insertionSucceeded: "Inserted"
        case .copiedForManualPaste: "Copied · press ⌘V"
        case .failed: "Last dictation failed"
        case .captureNeedsModel: "Model unavailable"
        case .waitingForInputMonitoring: "Setup required"
        default: "Ready to listen"
        }
    }

    /// The reason behind a failure, shown on hover rather than hidden in a log.
    var help: LocalizedStringKey? {
        switch state {
        case .failed:
            lastError.map { LocalizedStringKey($0) }
                ?? LocalizedStringKey("The last dictation did not complete.")
        case .captureNeedsModel:
            "The transcription model is not available."
        case .waitingForInputMonitoring:
            "Allow Input Monitoring so the shortcut works everywhere."
        default:
            nil
        }
    }

    func tone(_ theme: VoxoLTheme) -> Color {
        switch state {
        case .listening, .speechDetected: theme.coral
        case .transcribing, .polishing, .inserting: theme.cobalt
        case .failed, .captureNeedsModel, .waitingForInputMonitoring: theme.warning
        default: theme.success
        }
    }
}

struct EditorialWaveMini: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let heights: [CGFloat] = [12, 20, 16, 22, 10]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                    Capsule()
                        .fill(theme.coral)
                        .frame(width: 2, height: height)
                        .scaleEffect(
                            x: 1,
                            y: reduceMotion
                                ? 1
                                : 0.725 + 0.275 * sin(time * 6.55 + Double(index) * 0.82)
                        )
                }
            }
            .frame(height: 24)
        }
        .accessibilityHidden(true)
    }
}

struct EditorialDictationTriggerModifier: ViewModifier {
    @Environment(DictationSessionCoordinator.self) private var dictationSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let setupReady: Bool
    let openSetup: () -> Void

    @State private var pointerDown = false
    @State private var sentPress = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pointerDown && !reduceMotion ? 0.97 : 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pointerDown else { return }
                        pointerDown = true
                        guard setupReady else { return }
                        sentPress = true
                        dictationSession.pressDictationTrigger()
                    }
                    .onEnded { _ in
                        if sentPress {
                            dictationSession.releaseDictationTrigger()
                        } else {
                            openSetup()
                        }
                        sentPress = false
                        pointerDown = false
                    }
            )
            .animation(reduceMotion ? nil : EditorialMotion.soft, value: pointerDown)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if setupReady {
                    dictationSession.toggleDictationFromInterface()
                } else {
                    openSetup()
                }
            }
    }
}

extension View {
    func editorialDictationTrigger(setupReady: Bool, openSetup: @escaping () -> Void) -> some View {
        modifier(EditorialDictationTriggerModifier(setupReady: setupReady, openSetup: openSetup))
    }
}
