/// Pure interaction state for the hold-to-talk gesture.
///
/// Audio endpointing may record that speech happened, but only the physical shortcut release is
/// allowed to move the user-visible interaction from capture to processing.
public struct HoldToTalkStateMachine: Equatable, Sendable {
    /// User-visible phase of the physical hold gesture.
    public enum Phase: Equatable, Sendable {
        case ready
        case listening
        case processing
    }

    /// Input events that can advance or reset the gesture.
    public enum Event: Equatable, Sendable {
        case shortcutPressed
        case captureStarted
        case endpointDetectedSpeech
        case shortcutReleased
        case cancelled
    }

    /// Current user-visible phase.
    public private(set) var phase = Phase.ready
    /// Whether the shortcut is physically held.
    public private(set) var shortcutIsHeld = false
    /// Whether endpointing observed speech during this gesture.
    public private(set) var speechWasDetected = false

    /// Creates a ready hold-to-talk interaction.
    public init() {}

    /// Applies one physical or capture event.
    public mutating func handle(_ event: Event) {
        switch event {
        case .shortcutPressed:
            shortcutIsHeld = true
            speechWasDetected = false
        case .captureStarted:
            if shortcutIsHeld {
                phase = .listening
            }
        case .endpointDetectedSpeech:
            if shortcutIsHeld {
                speechWasDetected = true
            }
        case .shortcutReleased:
            shortcutIsHeld = false
            if phase == .listening {
                phase = .processing
            }
        case .cancelled:
            shortcutIsHeld = false
            speechWasDetected = false
            phase = .ready
        }
    }
}
