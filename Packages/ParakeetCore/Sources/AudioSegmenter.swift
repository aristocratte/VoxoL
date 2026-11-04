import Foundation

struct AudioSegment: Equatable {
    let samples: [Float]
    let discardPrefixSamples: Int
}

enum AudioSampleStorage: Sendable {
    case memory([Float])
    case mappedPCM(Data, sampleCount: Int)

    var count: Int {
        switch self {
        case .memory(let samples): samples.count
        case .mappedPCM(_, let sampleCount): sampleCount
        }
    }

    func samples(in range: Range<Int>) -> [Float] {
        precondition(range.lowerBound >= 0 && range.upperBound <= count)
        switch self {
        case .memory(let samples):
            if range.lowerBound == 0, range.upperBound == samples.count {
                return samples
            }
            return Array(samples[range])
        case .mappedPCM(let data, _):
            let count = range.count
            var samples = [Float](repeating: 0, count: count)
            samples.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    guard
                        let destinationBase = destination.baseAddress,
                        let sourceBase = source.baseAddress
                    else { return }
                    memcpy(
                        destinationBase,
                        sourceBase.advanced(
                            by: range.lowerBound * MemoryLayout<Float>.size
                        ),
                        count * MemoryLayout<Float>.size
                    )
                }
            }
            return samples
        }
    }
}

/// Lazily materializes overlapping encoder windows from one waveform.
///
/// Long imports can contain hundreds of windows. Keeping the source waveform
/// plus every copied window at once roughly doubles audio memory before Core ML
/// starts. This plan retains the source array and copies only the window the
/// pipeline is ready to consume.
struct AudioSegmentPlan: Sendable {
    let storage: AudioSampleStorage
    let sampleCount: Int
    let maximumSamples: Int
    let overlapSamples: Int
    let segmentationThresholdSamples: Int
    let count: Int

    init(
        samples: [Float],
        maximumSamples: Int,
        overlapSamples: Int,
        segmentationThresholdSamples: Int
    ) {
        self.init(
            storage: .memory(samples),
            sampleCount: samples.count,
            maximumSamples: maximumSamples,
            overlapSamples: overlapSamples,
            segmentationThresholdSamples: segmentationThresholdSamples
        )
    }

    init(
        storage: AudioSampleStorage,
        sampleCount: Int,
        maximumSamples: Int,
        overlapSamples: Int,
        segmentationThresholdSamples: Int
    ) {
        precondition(maximumSamples > 0)
        precondition(overlapSamples >= 0 && overlapSamples < maximumSamples)
        precondition(segmentationThresholdSamples >= maximumSamples)
        precondition(sampleCount >= 0 && sampleCount <= storage.count)
        self.storage = storage
        self.sampleCount = sampleCount
        self.maximumSamples = maximumSamples
        self.overlapSamples = overlapSamples
        self.segmentationThresholdSamples = segmentationThresholdSamples

        if sampleCount <= segmentationThresholdSamples {
            count = 1
        } else {
            let stride = maximumSamples - overlapSamples
            let remaining = max(0, sampleCount - maximumSamples)
            count = 1 + (remaining + stride - 1) / stride
        }
    }

    var isEmpty: Bool { count == 0 }

    subscript(index: Int) -> AudioSegment {
        precondition(index >= 0 && index < count)
        if count == 1 {
            return AudioSegment(
                samples: storage.samples(in: 0..<sampleCount),
                discardPrefixSamples: 0
            )
        }
        let cursor = index * (maximumSamples - overlapSamples)
        let end = min(cursor + maximumSamples, sampleCount)
        return AudioSegment(
            samples: storage.samples(in: cursor..<end),
            discardPrefixSamples: index == 0 ? 0 : overlapSamples
        )
    }
}

enum AudioSegmenter {
    static func modelWindowSampleCount(
        maximumWaveformSampleCount: Int?,
        chunkMelFrames: Int,
        hopLength: Int
    ) -> Int {
        maximumWaveformSampleCount ?? (chunkMelFrames - 1) * hopLength
    }

    static func singlePassSampleCount(
        inputSampleCount: Int,
        maximumSampleCount: Int,
        overflowToleranceSampleCount: Int
    ) -> Int {
        guard
            inputSampleCount > maximumSampleCount,
            inputSampleCount <= maximumSampleCount + overflowToleranceSampleCount
        else {
            return inputSampleCount
        }
        return maximumSampleCount
    }

    static func makeSegments(
        samples: [Float],
        maximumSamples: Int,
        overlapSamples: Int,
        segmentationThresholdSamples: Int? = nil
    ) -> [AudioSegment] {
        let segmentationThresholdSamples =
            segmentationThresholdSamples ?? maximumSamples
        let plan = makeSegmentPlan(
            samples: samples,
            maximumSamples: maximumSamples,
            overlapSamples: overlapSamples,
            segmentationThresholdSamples: segmentationThresholdSamples
        )
        return (0..<plan.count).map { plan[$0] }
    }

    static func makeSegmentPlan(
        samples: [Float],
        maximumSamples: Int,
        overlapSamples: Int,
        segmentationThresholdSamples: Int
    ) -> AudioSegmentPlan {
        AudioSegmentPlan(
            samples: samples,
            maximumSamples: maximumSamples,
            overlapSamples: overlapSamples,
            segmentationThresholdSamples: segmentationThresholdSamples
        )
    }

    static func makeSegmentPlan(
        storage: AudioSampleStorage,
        sampleCount: Int,
        maximumSamples: Int,
        overlapSamples: Int,
        segmentationThresholdSamples: Int
    ) -> AudioSegmentPlan {
        AudioSegmentPlan(
            storage: storage,
            sampleCount: sampleCount,
            maximumSamples: maximumSamples,
            overlapSamples: overlapSamples,
            segmentationThresholdSamples: segmentationThresholdSamples
        )
    }

    static func discardPrefixFrameCount(
        sampleCount: Int,
        discardPrefixSamples: Int,
        validFrameCount: Int
    ) -> Int {
        guard
            discardPrefixSamples > 0,
            sampleCount > 0,
            validFrameCount > 0
        else {
            return 0
        }
        return min(
            validFrameCount,
            Int(
                Double(validFrameCount)
                    * Double(discardPrefixSamples)
                    / Double(sampleCount)
            )
        )
    }
}

enum LongFormRetryPolicy {
    static func shouldRetry(
        audioDurationSeconds: Double,
        confidence: TranscriptionConfidence,
        configuration: ParakeetRetryConfiguration
    ) -> Bool {
        audioDurationSeconds > configuration.minimumAudioDurationSeconds
            && confidence.lowerDecileTokenLogitMargin
                < configuration.primaryMarginThreshold
    }

    static func shouldPreferFallback(
        audioDurationSeconds: Double,
        primary: TranscriptionConfidence,
        fallback: TranscriptionConfidence,
        configuration: ParakeetRetryConfiguration
    ) -> Bool {
        let marginImprovement =
            fallback.lowerDecileTokenLogitMargin
            - primary.lowerDecileTokenLogitMargin
        let usesStrictSelection =
            configuration.strictSelectionMaximumAudioDurationSeconds.map {
                audioDurationSeconds <= $0
            } ?? false
        guard usesStrictSelection else {
            return marginImprovement > configuration.requiredMarginImprovement
        }
        let tokenCoverage =
            Double(fallback.emittedTokenCount)
            / Double(max(1, primary.emittedTokenCount))
        return marginImprovement
            >= configuration.strictRequiredMarginImprovement
            && tokenCoverage >= configuration.strictMinimumTokenCoverage
    }
}
