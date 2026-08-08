import CoreML
import Foundation

extension ParakeetTranscriber {
    /// Captures one unsegmented source/Core ML comparison fixture.
    ///
    /// This diagnostic path is intentionally separate from production
    /// transcription so it cannot change segmentation, retry or latency.
    public func paritySnapshot(
        audioURL: URL,
        sourceCompatibleFeatures: Bool = false
    ) throws -> ParakeetParitySnapshot {
        try paritySnapshot(
            samples: AudioLoader.loadMono16k(at: audioURL),
            sourceCompatibleFeatures: sourceCompatibleFeatures
        )
    }

    /// Captures one unsegmented source/Core ML comparison fixture.
    public func paritySnapshot(
        samples: [Float],
        sourceCompatibleFeatures: Bool = false
    ) throws -> ParakeetParitySnapshot {
        let maximumSampleCount = AudioSegmenter.modelWindowSampleCount(
            maximumWaveformSampleCount: runner.maximumWaveformSampleCount,
            chunkMelFrames: chunkMelFrames,
            hopLength: featureExtractor.hopLength
        )
        guard !samples.isEmpty, samples.count <= maximumSampleCount else {
            throw ParakeetError.parityInputOutsideModelWindow(
                sampleCount: samples.count,
                maximumSampleCount: maximumSampleCount
            )
        }

        let features = featureExtractor.extract(
            from: samples,
            capturePowerSpectrogram: true,
            captureUnnormalizedLogMel: true,
            sourceCompatibleNormalization: sourceCompatibleFeatures
        )
        guard
            let powerSpectrogram = features.powerSpectrogram,
            let unnormalizedLogMel = features.unnormalizedLogMel
        else {
            throw ParakeetError.runtimeUnavailable
        }
        let (encoderHidden, encoderMask): (MLMultiArray, MLMultiArray)
        if runner.encoderInputKind == .waveform {
            (encoderHidden, encoderMask) = try runner.runEncoder(samples: samples)
        } else {
            (encoderHidden, encoderMask) = try runner.runEncoder(
                features: features.mel,
                mask: features.attentionMask
            )
        }
        guard let worker = runner.acquireWorker() else {
            throw ParakeetError.runtimeUnavailable
        }
        defer { runner.releaseWorker(worker) }

        let decoded = try GreedyTDTDecoder.decode(
            encoderHidden: encoderHidden,
            encoderMask: encoderMask,
            worker: worker,
            blankTokenId: runner.blankTokenId,
            durations: runner.durations,
            maxSymbolsPerStep: runner.maxSymbolsPerStep,
            captureParityTrace: true
        )

        return ParakeetParitySnapshot(
            sampleRate: sampleRate,
            audioSamples: samples,
            powerSpectrogram: ParakeetParityTensor(
                shape: [1, features.numFrames, featureExtractor.nFFT / 2 + 1],
                values: powerSpectrogram.flatMap { $0 }
            ),
            unnormalizedLogMel: ParakeetParityTensor(
                shape: [1, features.numFrames, featureExtractor.numMelFilters],
                values: unnormalizedLogMel.flatMap { $0 }
            ),
            inputFeatures: ParakeetParityTensor(
                shape: [1, features.numFrames, featureExtractor.numMelFilters],
                values: features.mel.flatMap { $0 }
            ),
            attentionMask: features.attentionMask,
            encoderHidden: ParakeetParityTensor(
                shape: encoderHidden.shape.map(\.intValue),
                values: floatValues(from: encoderHidden)
            ),
            encoderMask: int32Values(from: encoderMask),
            transcript: tokenizer.decode(decoded.tokenIds, skipSpecial: true),
            tokenIDs: decoded.tokenIds,
            frameIndices: decoded.frameIndices,
            durations: decoded.durations,
            decisions: decoded.parityDecisions
        )
    }
}

private func floatValues(from array: MLMultiArray) -> [Float] {
    precondition(array.dataType == .float32)
    let pointer = array.dataPointer.bindMemory(
        to: Float32.self,
        capacity: array.count
    )
    return Array(UnsafeBufferPointer(start: pointer, count: array.count))
}

private func int32Values(from array: MLMultiArray) -> [Int32] {
    precondition(array.dataType == .int32)
    let pointer = array.dataPointer.bindMemory(
        to: Int32.self,
        capacity: array.count
    )
    return Array(UnsafeBufferPointer(start: pointer, count: array.count))
}
