import Foundation

/// Signal measurements for one fixed-duration audio frame.
public struct EndpointFeatures: Equatable, Sendable {
    /// Frame energy after removing its mean.
    public let rootMeanSquare: Float
    /// Share of adjacent samples whose signs differ.
    public let zeroCrossingRate: Float
    /// Root-mean-square energy of adjacent sample differences.
    public let activity: Float
    /// Adaptive energy estimate for the current background noise.
    public let noiseFloor: Float

    /// Creates an immutable frame measurement.
    public init(
        rootMeanSquare: Float,
        zeroCrossingRate: Float,
        activity: Float,
        noiseFloor: Float
    ) {
        self.rootMeanSquare = rootMeanSquare
        self.zeroCrossingRate = zeroCrossingRate
        self.activity = activity
        self.noiseFloor = noiseFloor
    }
}

/// A deterministic endpoint transition for a 20 ms frame.
public enum EndpointEvent: Equatable, Sendable {
    case silence
    case speechStarted
    case speechContinued
    case speechEnded
}

/// Thresholds for mono 16 kHz Float32 audio split into 20 ms frames.
public struct EndpointConfiguration: Equatable, Sendable {
    /// Expected input sample rate.
    public var sampleRate: Int
    /// Duration represented by every processed frame.
    public var frameDurationMilliseconds: Int
    /// Minimum voiced frames required before speech can be confirmed.
    public var minimumSpeechFrames: Int
    /// Consecutive voiced frames required to enter speech state.
    public var speechStartFrames: Int
    /// Consecutive quiet frames required to leave speech state.
    public var speechEndFrames: Int
    /// Absolute energy floor below which a frame cannot be speech.
    public var minimumRootMeanSquare: Float
    /// Multiplier applied to the adaptive noise floor.
    public var noiseMultiplier: Float
    /// Noise estimate used before quiet frames have been observed.
    public var initialNoiseFloor: Float

    /// Creates endpoint thresholds for fixed-duration audio frames.
    public init(
        sampleRate: Int = 16_000,
        frameDurationMilliseconds: Int = 20,
        minimumSpeechFrames: Int = 5,
        speechStartFrames: Int = 3,
        speechEndFrames: Int = 18,
        minimumRootMeanSquare: Float = 0.012,
        noiseMultiplier: Float = 3.5,
        initialNoiseFloor: Float = 0.003
    ) {
        self.sampleRate = sampleRate
        self.frameDurationMilliseconds = frameDurationMilliseconds
        self.minimumSpeechFrames = minimumSpeechFrames
        self.speechStartFrames = speechStartFrames
        self.speechEndFrames = speechEndFrames
        self.minimumRootMeanSquare = minimumRootMeanSquare
        self.noiseMultiplier = noiseMultiplier
        self.initialNoiseFloor = initialNoiseFloor
    }

    /// Number of samples required by each call to the detector.
    public var frameSampleCount: Int {
        sampleRate * frameDurationMilliseconds / 1_000
    }
}

/// Lightweight speech endpointing with adaptive noise estimation and hysteresis.
/// Push-to-talk remains authoritative: this detector reports state but never stops capture.
public struct DeterministicEndpointDetector: Sendable {
    /// Fixed thresholds and frame dimensions used by this detector.
    public let configuration: EndpointConfiguration
    /// Measurements produced for the most recently accepted frame.
    public private(set) var lastFeatures: EndpointFeatures

    private var noiseFloor: Float
    private var candidateSpeechFrames = 0
    private var confirmedSpeechFrames = 0
    private var trailingSilenceFrames = 0
    private var isSpeaking = false

    /// Creates a reset detector with an initial background-noise estimate.
    public init(configuration: EndpointConfiguration = EndpointConfiguration()) {
        self.configuration = configuration
        noiseFloor = configuration.initialNoiseFloor
        lastFeatures = EndpointFeatures(
            rootMeanSquare: 0,
            zeroCrossingRate: 0,
            activity: 0,
            noiseFloor: configuration.initialNoiseFloor
        )
    }

    /// Processes exactly one configured frame without retaining its samples.
    public mutating func process(_ samples: UnsafeBufferPointer<Float>) -> EndpointEvent {
        guard samples.count == configuration.frameSampleCount, !samples.isEmpty else {
            return .silence
        }

        var sum: Float = 0
        for sample in samples {
            sum += sample
        }
        let mean = sum / Float(samples.count)

        var squareSum: Float = 0
        var differenceSquareSum: Float = 0
        var zeroCrossings = 0
        var previous = samples[0] - mean

        for index in samples.indices {
            let centered = samples[index] - mean
            squareSum += centered * centered
            if index > samples.startIndex {
                let difference = centered - previous
                differenceSquareSum += difference * difference
                if (centered >= 0) != (previous >= 0) {
                    zeroCrossings += 1
                }
            }
            previous = centered
        }

        let rms = sqrt(squareSum / Float(samples.count))
        let activity = sqrt(differenceSquareSum / Float(max(1, samples.count - 1)))
        let zeroCrossingRate = Float(zeroCrossings) / Float(max(1, samples.count - 1))
        let speechThreshold = max(
            configuration.minimumRootMeanSquare,
            noiseFloor * configuration.noiseMultiplier
        )
        let looksLikeSpeech = rms >= speechThreshold && zeroCrossingRate < 0.65

        if !looksLikeSpeech {
            let boundedObservation = min(rms, configuration.minimumRootMeanSquare)
            noiseFloor = max(
                0.000_5,
                noiseFloor * 0.96 + boundedObservation * 0.04
            )
        }

        lastFeatures = EndpointFeatures(
            rootMeanSquare: rms,
            zeroCrossingRate: zeroCrossingRate,
            activity: activity,
            noiseFloor: noiseFloor
        )

        if looksLikeSpeech {
            candidateSpeechFrames += 1
            trailingSilenceFrames = 0

            if isSpeaking {
                confirmedSpeechFrames += 1
                return .speechContinued
            }

            let confirmationFrames = max(
                configuration.speechStartFrames,
                configuration.minimumSpeechFrames
            )
            if candidateSpeechFrames >= confirmationFrames {
                isSpeaking = true
                confirmedSpeechFrames = candidateSpeechFrames
                return .speechStarted
            }
            return .silence
        }

        candidateSpeechFrames = 0
        guard isSpeaking else {
            return .silence
        }

        trailingSilenceFrames += 1
        guard
            confirmedSpeechFrames >= configuration.minimumSpeechFrames,
            trailingSilenceFrames >= configuration.speechEndFrames
        else {
            return .speechContinued
        }

        isSpeaking = false
        confirmedSpeechFrames = 0
        trailingSilenceFrames = 0
        return .speechEnded
    }
}
