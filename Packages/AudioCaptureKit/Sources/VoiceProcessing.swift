import Foundation

/// Whether Apple's voice processing wraps the capture.
///
/// Voice processing is the echo-cancellation, noise-suppression and gain stage
/// Apple ships for its own microphones — the same one FaceTime uses. On a
/// MacBook's built-in mic at arm's length it is the difference between a
/// usable take and one drowned in fan noise and room reverb. On an external
/// microphone it is mostly a downgrade: the signal is already close-miked and
/// clean, and the processing colours it for no benefit.
///
/// Hence three positions instead of a switch: the default follows the
/// microphone, and both overrides stay available because "automatic" is a
/// heuristic, not a guarantee.
public enum VoiceProcessingMode: String, Codable, CaseIterable, Sendable {
    /// Enabled exactly when capturing from a built-in microphone.
    case automatic
    /// Always enabled, whatever the device.
    case enabled
    /// Never enabled; the raw converter path only.
    case disabled

    /// Resolves the mode against the microphone actually in use.
    public func shouldEnable(forBuiltInMicrophone isBuiltIn: Bool) -> Bool {
        switch self {
        case .automatic: isBuiltIn
        case .enabled: true
        case .disabled: false
        }
    }
}

/// A verdict on how usable a finished take was, mechanically.
///
/// The recogniser degrades quietly: a too-distant microphone or a clipped
/// input still produces *a* transcript, just a worse one, and nothing tells
/// the user why quality dropped. These two conditions are cheap to measure
/// and each has a one-gesture fix — move closer, or lower the input gain —
/// so they are worth one short hint. Everything subtler is not: a capsule
/// that second-guesses good takes trains people to ignore it.
public enum CaptureTakeQuality: Equatable, Sendable {
    case good
    /// Speech was detected but stayed very quiet throughout.
    case tooQuiet
    /// A meaningful share of samples hit the converter's ceiling.
    case clipped

    /// Peak RMS below this never happens with a well-placed microphone once
    /// the automatic gain stage has had its say.
    public static let quietPeakThreshold: Float = 0.03

    /// Fraction of clipped samples above which distortion is audible — and
    /// audible distortion is exactly what recognisers mis-hear.
    public static let clippedFractionThreshold: Double = 0.005

    /// Judges a completed capture.
    public static func assess(_ audio: CapturedAudio) -> CaptureTakeQuality {
        guard !audio.samples.isEmpty else {
            return .good
        }
        // Clipping is only meaningful with speech in it: a stray electrical
        // pop in an otherwise silent take distorts nothing anyone said.
        if audio.speechDetected,
            Double(audio.clippedSampleCount) / Double(audio.samples.count)
                > clippedFractionThreshold
        {
            return .clipped
        }
        // A quiet verdict needs either detected speech (spoke, but faintly) or
        // a take long enough that silence-by-choice is implausible: holding
        // the key for two seconds while the endpointer hears nothing is the
        // too-far microphone's exact signature.
        let plausiblyTriedToSpeak = audio.speechDetected || audio.durationSeconds >= 2
        if plausiblyTriedToSpeak, audio.maximumRootMeanSquare < quietPeakThreshold {
            return .tooQuiet
        }
        return .good
    }
}
