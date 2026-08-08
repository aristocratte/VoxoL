// Adapted for VoxoL from parakeet-coreml-swift commit 75aec2a1c991319657ff4dec5f602c12da6c5012.
// Changes are documented in Packages/ParakeetCore/NOTICE.md.
import CoreML
import Foundation

/// Which Core ML compute units the scheduler is allowed to target.
public enum ParakeetComputeUnits: String, Sendable {
    /// Apple Neural Engine + CPU fallback. Default; best power / latency balance
    /// on iOS and most Macs for this model.
    case ane
    /// CPU + GPU (excludes Neural Engine). Fastest for the 4-bit palettized
    /// encoder on Apple silicon, ~1.7x faster than ANE in our benchmarks.
    case gpu
    /// CPU only. Portable fallback; ~half the throughput of ANE.
    case cpu
    /// Let Core ML's scheduler pick from CPU + GPU + ANE.
    case all

    /// Core ML scheduler policy represented by this option.
    public var mlComputeUnits: MLComputeUnits {
        switch self {
        case .ane: return .cpuAndNeuralEngine
        case .gpu: return .cpuAndGPU
        case .cpu: return .cpuOnly
        case .all: return .all
        }
    }
}

/// Audio-window policy used before the fixed-shape Parakeet encoder.
public struct ParakeetSegmentationConfiguration: Equatable, Sendable {
    /// Maximum amount of new audio decoded by one encoder invocation.
    public let maximumSegmentDurationSeconds: Double
    /// Repeated audio prepended to every segment after the first.
    public let overlapDurationSeconds: Double
    /// Audio remains in one encoder invocation until it exceeds this duration.
    public let segmentationThresholdDurationSeconds: Double

    /// Historical behavior: one encoder window with no repeated context.
    public static let modelWindow = ParakeetSegmentationConfiguration(
        maximumSegmentDurationSeconds: 30,
        overlapDurationSeconds: 0,
        segmentationThresholdDurationSeconds: 30
    )

    /// Production policy: preserve the single-pass fast path, then anchor
    /// language context across long-form encoder windows.
    public static let production = ParakeetSegmentationConfiguration(
        maximumSegmentDurationSeconds: 20,
        overlapDurationSeconds: 2.5,
        segmentationThresholdDurationSeconds: 30
    )

    /// Creates a bounded segmentation policy.
    public init(
        maximumSegmentDurationSeconds: Double,
        overlapDurationSeconds: Double,
        segmentationThresholdDurationSeconds: Double? = nil
    ) {
        let segmentationThresholdDurationSeconds =
            segmentationThresholdDurationSeconds
            ?? maximumSegmentDurationSeconds
        precondition(
            maximumSegmentDurationSeconds.isFinite
                && maximumSegmentDurationSeconds > 0
        )
        precondition(
            overlapDurationSeconds.isFinite
                && overlapDurationSeconds >= 0
                && overlapDurationSeconds < maximumSegmentDurationSeconds
        )
        precondition(
            segmentationThresholdDurationSeconds.isFinite
                && segmentationThresholdDurationSeconds
                    >= maximumSegmentDurationSeconds
        )
        self.maximumSegmentDurationSeconds = maximumSegmentDurationSeconds
        self.overlapDurationSeconds = overlapDurationSeconds
        self.segmentationThresholdDurationSeconds =
            segmentationThresholdDurationSeconds
    }
}

/// Conservative second-pass policy for uncertain long-form decoding.
public struct ParakeetRetryConfiguration: Equatable, Sendable {
    /// Shorter segmentation used only after a low-confidence primary pass.
    public let fallbackSegmentation: ParakeetSegmentationConfiguration
    /// Minimum utterance duration eligible for a second pass.
    public let minimumAudioDurationSeconds: Double
    /// Retry when the primary lower-decile margin is below this value.
    public let primaryMarginThreshold: Double
    /// Replace the primary only when the retry exceeds it by this margin.
    public let requiredMarginImprovement: Double
    /// Upper duration bound for the stricter near-window retry selector.
    public let strictSelectionMaximumAudioDurationSeconds: Double?
    /// Margin required when the stricter near-window selector is active.
    public let strictRequiredMarginImprovement: Double
    /// Minimum fallback token coverage under the stricter selector.
    public let strictMinimumTokenCoverage: Double

    /// Conservative production candidate; promotion still requires a frozen test set.
    public static let production = ParakeetRetryConfiguration(
        fallbackSegmentation: ParakeetSegmentationConfiguration(
            maximumSegmentDurationSeconds: 15,
            overlapDurationSeconds: 2.5,
            segmentationThresholdDurationSeconds: 15
        ),
        minimumAudioDurationSeconds: 29.5,
        primaryMarginThreshold: 0.75,
        requiredMarginImprovement: 0.10,
        strictSelectionMaximumAudioDurationSeconds: 30.1,
        strictRequiredMarginImprovement: 0.75,
        strictMinimumTokenCoverage: 0.85
    )

    /// Creates a bounded retry policy.
    public init(
        fallbackSegmentation: ParakeetSegmentationConfiguration,
        minimumAudioDurationSeconds: Double,
        primaryMarginThreshold: Double,
        requiredMarginImprovement: Double,
        strictSelectionMaximumAudioDurationSeconds: Double? = nil,
        strictRequiredMarginImprovement: Double = 0,
        strictMinimumTokenCoverage: Double = 0
    ) {
        precondition(
            minimumAudioDurationSeconds.isFinite
                && minimumAudioDurationSeconds > 0
        )
        precondition(
            primaryMarginThreshold.isFinite
                && primaryMarginThreshold > 0
        )
        precondition(
            requiredMarginImprovement.isFinite
                && requiredMarginImprovement >= 0
        )
        if let strictSelectionMaximumAudioDurationSeconds {
            precondition(
                strictSelectionMaximumAudioDurationSeconds.isFinite
                    && strictSelectionMaximumAudioDurationSeconds
                        > minimumAudioDurationSeconds
            )
        }
        precondition(
            strictRequiredMarginImprovement.isFinite
                && strictRequiredMarginImprovement >= 0
        )
        precondition(
            strictMinimumTokenCoverage.isFinite
                && (0...1).contains(strictMinimumTokenCoverage)
        )
        self.fallbackSegmentation = fallbackSegmentation
        self.minimumAudioDurationSeconds = minimumAudioDurationSeconds
        self.primaryMarginThreshold = primaryMarginThreshold
        self.requiredMarginImprovement = requiredMarginImprovement
        self.strictSelectionMaximumAudioDurationSeconds =
            strictSelectionMaximumAudioDurationSeconds
        self.strictRequiredMarginImprovement = strictRequiredMarginImprovement
        self.strictMinimumTokenCoverage = strictMinimumTokenCoverage
    }
}

/// Breakdown of where inference time went, in seconds.
public struct TranscriptionTiming: Sendable {
    /// Seconds spent extracting normalized log-mel features.
    public var melExtract: Double
    /// Seconds spent in the accelerated encoder.
    public var encoder: Double
    /// Seconds spent in the greedy decoder and joint network.
    public var decoderLoop: Double  // decoder + joint + argmax combined
    /// Seconds spent decoding token pieces into text.
    public var detokenize: Double

    /// Creates a timing breakdown.
    public init(
        melExtract: Double = 0,
        encoder: Double = 0,
        decoderLoop: Double = 0,
        detokenize: Double = 0
    ) {
        self.melExtract = melExtract
        self.encoder = encoder
        self.decoderLoop = decoderLoop
        self.detokenize = detokenize
    }

    /// Total measured inference seconds.
    public var total: Double { melExtract + encoder + decoderLoop + detokenize }
}

/// Content-free decoder signals used to identify uncertain long-form output.
public struct TranscriptionConfidence: Codable, Sendable {
    /// Number of emitted non-blank tokens contributing to the margin statistics.
    public let emittedTokenCount: Int
    /// Mean gap between the winning token logit and its closest alternative.
    public let meanTokenLogitMargin: Double
    /// Lower-decile token margin, which is less sensitive to one outlier.
    public let lowerDecileTokenLogitMargin: Double
    /// Mean gap between the selected TDT duration and its closest alternative.
    public let meanDurationLogitMargin: Double
    /// Lower-decile duration margin across token and blank decisions.
    public let lowerDecileDurationLogitMargin: Double
    /// Fraction of joint decisions that emitted the blank token.
    public let blankDecisionRatio: Double
    /// Longest encoder-frame interval without an emitted lexical token.
    public let maximumFramesWithoutEmission: Int
    /// Lowest token agreement across repeated acoustic boundaries, when present.
    public let minimumOverlapTokenAgreement: Double?
    /// Mean token agreement across repeated acoustic boundaries, when present.
    public let meanOverlapTokenAgreement: Double?
}

/// Result of a successful transcription.
public struct Transcription: Sendable {
    /// Final detokenized text.
    public let text: String
    /// Token IDs emitted by the TDT greedy decoder (blank + duration tokens
    /// already stripped).
    public let tokenIds: [Int]
    /// Per-token encoder-frame indices. Lets callers reconstruct approximate
    /// word-level timings when combined with `durations` and the encoder's
    /// `hopLength * subsamplingFactor` stride.
    public let frameIndices: [Int]
    /// Per-token duration value (in encoder frames) predicted by the joint.
    public let durations: [Int]
    /// Per-token gap between the winning logit and the runner-up.
    ///
    /// Aggregated into ``confidence`` for telemetry, and kept per token here
    /// because that is the only signal saying *where* the recogniser hesitated.
    /// A repair pass that may change words needs to be confined to those spans:
    /// let loose over a confident transcript, a language model rewrites what
    /// the speaker actually said.
    public let tokenLogitMargins: [Float]
    /// Wall-clock audio duration (seconds).
    public let audioDurationSeconds: Double
    /// Wall-clock inference duration (seconds). Excludes model load time.
    public let inferenceDurationSeconds: Double
    /// Per-phase timing breakdown (sums to ``inferenceDurationSeconds``).
    public let timing: TranscriptionTiming
    /// Content-free uncertainty signals collected during greedy decoding.
    public let confidence: TranscriptionConfidence
    /// Number of complete decoder passes used for this result.
    public let inferenceAttemptCount: Int
    /// Whether the shorter fallback segmentation supplied the returned text.
    public let usedFallbackSegmentation: Bool
    /// `audioDurationSeconds / inferenceDurationSeconds`. Higher is better;
    /// >1 means faster than real time.
    public var rtfx: Double {
        inferenceDurationSeconds > 0
            ? audioDurationSeconds / inferenceDurationSeconds
            : 0
    }
}

/// Errors surfaced by the ParakeetTDT pipeline.
public enum ParakeetError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case modelNotFound(url: URL)
    case modelCompileFailed(url: URL, underlying: Error)
    case tokenizerLoadFailed(url: URL, underlying: Error)
    case audioLoadFailed(url: URL, underlying: Error)
    case audioEmpty(url: URL)
    case parityInputOutsideModelWindow(sampleCount: Int, maximumSampleCount: Int)
    case unexpectedOutputShape(name: String, got: [Int], expected: String)
    case missingOutput(name: String)
    case fftSetupFailed
    case runtimeUnavailable

    /// Human-readable failure description without transcript or audio content.
    public var description: String {
        switch self {
        case .modelNotFound(let url):
            return "Model not found at \(url.path)"
        case .modelCompileFailed(let url, let underlying):
            return "Failed to compile model at \(url.path): \(underlying)"
        case .tokenizerLoadFailed(let url, let underlying):
            return "Failed to load tokenizer at \(url.path): \(underlying)"
        case .audioLoadFailed(let url, let underlying):
            return "Failed to load audio at \(url.path): \(underlying)"
        case .audioEmpty(let url):
            return "Audio file at \(url.path) contains no samples"
        case .parityInputOutsideModelWindow(let sampleCount, let maximumSampleCount):
            return
                "Parity input has \(sampleCount) samples; expected 1...\(maximumSampleCount)."
        case .unexpectedOutputShape(let name, let got, let expected):
            return "Output \"\(name)\" has unexpected shape \(got); expected \(expected)"
        case .missingOutput(let name):
            return "Missing expected output \"\(name)\" from Core ML prediction"
        case .fftSetupFailed:
            return "Failed to create vDSP FFT setup"
        case .runtimeUnavailable:
            return "The Parakeet runtime is unavailable."
        }
    }

    /// Localized-error bridge used by the application UI.
    public var errorDescription: String? { description }
}
