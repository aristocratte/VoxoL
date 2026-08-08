import Foundation

struct AudioSegment: Equatable {
    let samples: [Float]
    let discardPrefixSamples: Int
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
        precondition(maximumSamples > 0)
        precondition(overlapSamples >= 0 && overlapSamples < maximumSamples)
        let segmentationThresholdSamples =
            segmentationThresholdSamples ?? maximumSamples
        precondition(segmentationThresholdSamples >= maximumSamples)
        guard samples.count > segmentationThresholdSamples else {
            return [
                AudioSegment(
                    samples: samples,
                    discardPrefixSamples: 0
                )
            ]
        }

        var segments = [AudioSegment]()
        var cursor = 0
        while cursor < samples.count {
            let end = min(cursor + maximumSamples, samples.count)
            segments.append(
                AudioSegment(
                    samples: Array(samples[cursor..<end]),
                    discardPrefixSamples: segments.isEmpty ? 0 : overlapSamples
                )
            )
            guard end < samples.count else {
                break
            }
            cursor = end - overlapSamples
        }
        return segments
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
