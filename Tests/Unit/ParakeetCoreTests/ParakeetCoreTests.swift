import CoreML
import Foundation
@testable import ParakeetCore
import XCTest

final class ParakeetCoreTests: XCTestCase {
    func testInferenceCancellationIsStickyAndVisibleAcrossStages() throws {
        let cancellation = InferenceCancellation()
        try cancellation.check()
        let stopped = expectation(description: "cancellation propagated")
        DispatchQueue.global().async {
            cancellation.cancel()
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)
        XCTAssertThrowsError(try cancellation.check()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        cancellation.cancel()
        XCTAssertThrowsError(try cancellation.check())
    }

    func testPipelineQueueCloseReleasesBlockedProducerAndDrainsExistingItems() {
        let queue = BlockingQueue<Int>(capacity: 1)
        queue.put(1)
        let released = expectation(description: "producer released")
        DispatchQueue.global().async {
            queue.put(2)
            released.fulfill()
        }
        queue.close()
        wait(for: [released], timeout: 2)
        XCTAssertEqual(queue.take(), 1)
        XCTAssertNil(queue.take())
        queue.close()
        XCTAssertNil(queue.take())
    }

    func testPipelineQueueCloseReleasesBlockedConsumer() {
        let queue = BlockingQueue<Int>(capacity: 1)
        let released = expectation(description: "consumer released")
        DispatchQueue.global().async {
            XCTAssertNil(queue.take())
            released.fulfill()
        }
        queue.close()
        wait(for: [released], timeout: 2)
    }

    func testEncoderInputContractDetectionSupportsBothRuntimes() throws {
        XCTAssertEqual(
            try ModelRunner.encoderInputKind(
                inputNames: ["input_features", "attention_mask"]
            ),
            .features
        )
        XCTAssertEqual(
            try ModelRunner.encoderInputKind(
                inputNames: ["audio_signal", "audio_length"]
            ),
            .waveform
        )
        XCTAssertThrowsError(
            try ModelRunner.encoderInputKind(inputNames: ["unexpected"])
        )
    }

    func testWaveformEncoderCapacityChoosesSmallestSufficientFunction() {
        let capacities = [480_000, 320_000, 400_000]
        XCTAssertEqual(
            ModelRunner.waveformEncoderCapacity(
                sampleCount: 160_000,
                availableCapacities: capacities
            ),
            320_000
        )
        XCTAssertEqual(
            ModelRunner.waveformEncoderCapacity(
                sampleCount: 320_000,
                availableCapacities: capacities
            ),
            320_000
        )
        XCTAssertEqual(
            ModelRunner.waveformEncoderCapacity(
                sampleCount: 320_001,
                availableCapacities: capacities
            ),
            400_000
        )
        XCTAssertEqual(
            ModelRunner.waveformEncoderCapacity(
                sampleCount: 400_001,
                availableCapacities: capacities
            ),
            480_000
        )
        XCTAssertNil(
            ModelRunner.waveformEncoderCapacity(
                sampleCount: 480_001,
                availableCapacities: capacities
            )
        )
    }

    func testWaveformRuntimeUsesItsExactThirtySecondCapacity() {
        XCTAssertEqual(
            AudioSegmenter.modelWindowSampleCount(
                maximumWaveformSampleCount: 480_000,
                chunkMelFrames: 3_000,
                hopLength: 160
            ),
            480_000
        )
        XCTAssertEqual(
            AudioSegmenter.modelWindowSampleCount(
                maximumWaveformSampleCount: nil,
                chunkMelFrames: 3_000,
                hopLength: 160
            ),
            479_840
        )
    }

    func testWaveformRuntimeUsesShorterModelCapacity() {
        XCTAssertEqual(
            AudioSegmenter.modelWindowSampleCount(
                maximumWaveformSampleCount: 320_000,
                chunkMelFrames: 3_000,
                hopLength: 160
            ),
            320_000
        )
        XCTAssertEqual(
            AudioSegmenter.singlePassSampleCount(
                inputSampleCount: 320_160,
                maximumSampleCount: 320_000,
                overflowToleranceSampleCount: 160
            ),
            320_000
        )
        XCTAssertEqual(
            AudioSegmenter.singlePassSampleCount(
                inputSampleCount: 320_161,
                maximumSampleCount: 320_000,
                overflowToleranceSampleCount: 160
            ),
            320_161
        )
    }

    func testWaveformRuntimeTrimsOnlyOneHopAtTheWindowBoundary() {
        XCTAssertEqual(
            AudioSegmenter.singlePassSampleCount(
                inputSampleCount: 480_000,
                maximumSampleCount: 479_840,
                overflowToleranceSampleCount: 160
            ),
            479_840
        )
        XCTAssertEqual(
            AudioSegmenter.singlePassSampleCount(
                inputSampleCount: 480_001,
                maximumSampleCount: 479_840,
                overflowToleranceSampleCount: 160
            ),
            480_001
        )
        XCTAssertEqual(
            AudioSegmenter.singlePassSampleCount(
                inputSampleCount: 479_840,
                maximumSampleCount: 479_840,
                overflowToleranceSampleCount: 160
            ),
            479_840
        )
    }

    func testAudioSegmenterUsesOverlapAndMarksOnlyRepeatedPrefix() {
        let samples = (0..<10).map(Float.init)

        let segments = AudioSegmenter.makeSegments(
            samples: samples,
            maximumSamples: 6,
            overlapSamples: 2
        )

        XCTAssertEqual(
            segments,
            [
                AudioSegment(samples: [0, 1, 2, 3, 4, 5], discardPrefixSamples: 0),
                AudioSegment(samples: [4, 5, 6, 7, 8, 9], discardPrefixSamples: 2),
            ]
        )
    }

    func testLazyAudioSegmentPlanMatchesMaterializedSegments() {
        let samples = (0..<37).map(Float.init)
        let eager = AudioSegmenter.makeSegments(
            samples: samples,
            maximumSamples: 10,
            overlapSamples: 3,
            segmentationThresholdSamples: 12
        )
        let plan = AudioSegmenter.makeSegmentPlan(
            samples: samples,
            maximumSamples: 10,
            overlapSamples: 3,
            segmentationThresholdSamples: 12
        )

        XCTAssertEqual(plan.count, eager.count)
        XCTAssertEqual((0..<plan.count).map { plan[$0] }, eager)
    }

    func testMappedAudioSegmentPlanMatchesMemoryStorage() {
        let samples = (0..<37).map(Float.init)
        let data = samples.withUnsafeBytes { Data($0) }
        let memory = AudioSegmenter.makeSegmentPlan(
            samples: samples,
            maximumSamples: 10,
            overlapSamples: 3,
            segmentationThresholdSamples: 12
        )
        let mapped = AudioSegmenter.makeSegmentPlan(
            storage: .mappedPCM(data, sampleCount: samples.count),
            sampleCount: samples.count,
            maximumSamples: 10,
            overlapSamples: 3,
            segmentationThresholdSamples: 12
        )

        XCTAssertEqual(mapped.count, memory.count)
        XCTAssertEqual(
            (0..<mapped.count).map { mapped[$0] },
            (0..<memory.count).map { memory[$0] }
        )
    }

    func testAudioSegmenterLeavesShortInputUntouched() {
        let samples = (0..<5).map(Float.init)

        let segments = AudioSegmenter.makeSegments(
            samples: samples,
            maximumSamples: 6,
            overlapSamples: 2
        )

        XCTAssertEqual(
            segments,
            [AudioSegment(samples: samples, discardPrefixSamples: 0)]
        )
    }

    func testAudioSegmenterKeepsMediumInputWholeUntilThreshold() {
        let samples = (0..<8).map(Float.init)

        let segments = AudioSegmenter.makeSegments(
            samples: samples,
            maximumSamples: 6,
            overlapSamples: 2,
            segmentationThresholdSamples: 10
        )

        XCTAssertEqual(
            segments,
            [AudioSegment(samples: samples, discardPrefixSamples: 0)]
        )
    }

    func testTwentySecondWaveformWindowReconstructsTwentyOneSecondInput() {
        let sampleRate = 16_000
        let samples = (0..<(21 * sampleRate)).map(Float.init)

        let segments = AudioSegmenter.makeSegments(
            samples: samples,
            maximumSamples: 20 * sampleRate,
            overlapSamples: Int(2.5 * Double(sampleRate)),
            segmentationThresholdSamples: 20 * sampleRate
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].samples.count, 320_000)
        XCTAssertEqual(segments[0].discardPrefixSamples, 0)
        XCTAssertEqual(segments[1].samples.count, 56_000)
        XCTAssertEqual(segments[1].discardPrefixSamples, 40_000)

        let reconstructed = segments.enumerated().flatMap { index, segment in
            Array(segment.samples.dropFirst(index == 0 ? 0 : segment.discardPrefixSamples))
        }
        XCTAssertEqual(reconstructed, samples)
    }

    func testAudioSegmenterMapsRepeatedSamplesToEncoderFrames() {
        XCTAssertEqual(
            AudioSegmenter.discardPrefixFrameCount(
                sampleCount: 16_000,
                discardPrefixSamples: 2_000,
                validFrameCount: 100
            ),
            12
        )
    }

    func testOverlapAgreementIsOneForIdenticalTokens() {
        XCTAssertEqual(
            Pipeline.tokenAgreement([10, 20, 30], [10, 20, 30]),
            1
        )
    }

    func testOverlapAgreementPenalizesInsertionsAndSubstitutions() {
        XCTAssertEqual(
            Pipeline.tokenAgreement([10, 20, 30], [10, 40, 30, 50]),
            0.5
        )
    }

    func testLongFormRetryIncludesThirtySecondLowConfidenceAudio() {
        let lowConfidence = confidence(lowerDecileMargin: 0.50)
        let highConfidence = confidence(lowerDecileMargin: 1.20)

        XCTAssertFalse(
            LongFormRetryPolicy.shouldRetry(
                audioDurationSeconds: 20,
                confidence: lowConfidence,
                configuration: .production
            )
        )
        XCTAssertTrue(
            LongFormRetryPolicy.shouldRetry(
                audioDurationSeconds: 30,
                confidence: lowConfidence,
                configuration: .production
            )
        )
        XCTAssertFalse(
            LongFormRetryPolicy.shouldRetry(
                audioDurationSeconds: 40,
                confidence: highConfidence,
                configuration: .production
            )
        )
    }

    func testLongFormRetrySelectsOnlyMaterialConfidenceImprovement() {
        let primary = confidence(lowerDecileMargin: 0.50)

        XCTAssertTrue(
            LongFormRetryPolicy.shouldPreferFallback(
                audioDurationSeconds: 40,
                primary: primary,
                fallback: confidence(lowerDecileMargin: 0.70),
                configuration: .production
            )
        )
        XCTAssertFalse(
            LongFormRetryPolicy.shouldPreferFallback(
                audioDurationSeconds: 40,
                primary: primary,
                fallback: confidence(lowerDecileMargin: 0.55),
                configuration: .production
            )
        )
    }

    func testThirtySecondRetryUsesStrictMarginAndTokenCoverage() {
        let primary = confidence(lowerDecileMargin: 0.50, emittedTokenCount: 10)

        XCTAssertFalse(
            LongFormRetryPolicy.shouldPreferFallback(
                audioDurationSeconds: 30,
                primary: primary,
                fallback: confidence(
                    lowerDecileMargin: 1.00,
                    emittedTokenCount: 10
                ),
                configuration: .production
            )
        )
        XCTAssertFalse(
            LongFormRetryPolicy.shouldPreferFallback(
                audioDurationSeconds: 30,
                primary: primary,
                fallback: confidence(
                    lowerDecileMargin: 1.30,
                    emittedTokenCount: 8
                ),
                configuration: .production
            )
        )
        XCTAssertTrue(
            LongFormRetryPolicy.shouldPreferFallback(
                audioDurationSeconds: 30,
                primary: primary,
                fallback: confidence(
                    lowerDecileMargin: 1.30,
                    emittedTokenCount: 9
                ),
                configuration: .production
            )
        )
    }

    func testSyntheticDecoderForcesBlankDurationZeroForward() {
        let result = TDTDecodePolicy.decodeSynthetic(
            validFrameCount: 3,
            blankTokenID: 99,
            maxSymbolsPerStep: 10,
            decisions: [
                TDTDecision(tokenID: 99, duration: 0),
                TDTDecision(tokenID: 10, duration: 1),
                TDTDecision(tokenID: 99, duration: 0),
            ]
        )

        XCTAssertEqual(result.tokenIDs, [10])
        XCTAssertEqual(result.frameIndices, [1])
        XCTAssertEqual(result.durations, [1])
    }

    func testPredictorStateCommitsOnlyAfterLexicalEmission() {
        let blank = TDTDecodePolicy.transition(
            tokenID: 99,
            blankTokenID: 99,
            duration: 2
        )
        let token = TDTDecodePolicy.transition(
            tokenID: 10,
            blankTokenID: 99,
            duration: 0
        )

        XCTAssertEqual(
            TDTDecodePolicy.predictorStateUpdate(for: blank),
            TDTDecodePolicy.PredictorStateUpdate(
                commitsCandidateState: false,
                invalidatesCachedPrediction: false
            )
        )
        XCTAssertEqual(
            TDTDecodePolicy.predictorStateUpdate(for: token),
            TDTDecodePolicy.PredictorStateUpdate(
                commitsCandidateState: true,
                invalidatesCachedPrediction: true
            )
        )
    }

    func testSyntheticDecoderAllowsSeveralZeroDurationTokensOnOneFrame() {
        let result = TDTDecodePolicy.decodeSynthetic(
            validFrameCount: 2,
            blankTokenID: 99,
            maxSymbolsPerStep: 10,
            decisions: [
                TDTDecision(tokenID: 10, duration: 0),
                TDTDecision(tokenID: 20, duration: 0),
                TDTDecision(tokenID: 30, duration: 1),
                TDTDecision(tokenID: 99, duration: 1),
            ]
        )

        XCTAssertEqual(result.tokenIDs, [10, 20, 30])
        XCTAssertEqual(result.frameIndices, [0, 0, 0])
        XCTAssertEqual(result.durations, [0, 0, 1])
    }

    func testSyntheticDecoderAdvancesAfterMaximumSymbolsAndResetsFrameLimit() {
        let result = TDTDecodePolicy.decodeSynthetic(
            validFrameCount: 3,
            blankTokenID: 99,
            maxSymbolsPerStep: 2,
            decisions: [
                TDTDecision(tokenID: 10, duration: 0),
                TDTDecision(tokenID: 20, duration: 0),
                TDTDecision(tokenID: 30, duration: 0),
                TDTDecision(tokenID: 40, duration: 2),
            ]
        )

        XCTAssertEqual(result.tokenIDs, [10, 20, 30, 40])
        XCTAssertEqual(result.frameIndices, [0, 0, 1, 1])
        XCTAssertEqual(result.durations, [0, 0, 0, 2])
    }

    func testSyntheticDecoderStopsAtEncoderEnd() {
        let result = TDTDecodePolicy.decodeSynthetic(
            validFrameCount: 2,
            blankTokenID: 99,
            maxSymbolsPerStep: 10,
            decisions: [
                TDTDecision(tokenID: 10, duration: 4),
                TDTDecision(tokenID: 20, duration: 1),
            ]
        )

        XCTAssertEqual(result.tokenIDs, [10])
        XCTAssertEqual(result.consumedDecisionCount, 1)
    }

    func testFeatureExtractorProducesFiniteNormalizedFrames() throws {
        let extractor = try MelFeatureExtractor()
        let waveform = (0..<16_000).map { index in
            Float(0.12 * sin(Double(index) * 2 * .pi * 220 / 16_000))
        }

        let features = extractor.extract(from: waveform)

        XCTAssertEqual(features.numFrames, 101)
        XCTAssertEqual(features.attentionMask, [Int32](repeating: 1, count: 101))
        XCTAssertTrue(features.mel.joined().allSatisfy(\.isFinite))
    }

    func testFeatureExtractorCanMirrorTransformersFinalFrameMasking() throws {
        let extractor = try MelFeatureExtractor()
        let waveform = (0..<16_000).map { index in
            Float(0.12 * sin(Double(index) * 2 * .pi * 220 / 16_000))
        }

        let features = extractor.extract(
            from: waveform,
            sourceCompatibleNormalization: true
        )

        XCTAssertEqual(
            features.attentionMask,
            [Int32](repeating: 1, count: 100) + [0]
        )
        XCTAssertTrue(features.mel[100].allSatisfy { $0 == 0 })
    }

    func testFeatureExtractorCentersShortWindowInsideFFTFrame() throws {
        let extractor = try MelFeatureExtractor()
        var waveform = [Float](repeating: 0, count: 1_600)
        waveform[170] = 1

        let features = extractor.extract(
            from: waveform,
            capturePowerSpectrogram: true
        )

        let firstFrameEnergy = try XCTUnwrap(features.powerSpectrogram?.first).reduce(0, +)
        XCTAssertGreaterThan(firstFrameEnergy, 1)
    }

    func testTokenizerDecodesMetaspaceAndSkipsSpecialTokens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokenizerURL = directory.appendingPathComponent("tokenizer.json")
        let tokenizer = """
            {
              "model": {"vocab": {"<unk>": 0, "▁Hello": 1, "▁world": 2, ".": 4}},
              "added_tokens": [{"id": 3, "content": "<blank>", "special": true}]
            }
            """
        try Data(tokenizer.utf8).write(to: tokenizerURL)

        let decoder = try Tokenizer(tokenizerJSONURL: tokenizerURL)

        XCTAssertEqual(decoder.decode([3, 1, 2]), "Hello world")
        XCTAssertEqual(decoder.decode([1, 1, 2, 2]), "Hello Hello world world")
        XCTAssertEqual(decoder.decode([1, 3, 1]), "Hello Hello")
        XCTAssertEqual(decoder.decode([1, 4, 4, 2]), "Hello. world")
    }

    func testLanguagePenaltyOnlyLoadsForFrench() throws {
        let root = try penaltyFixture(ids: [506, 575])

        XCTAssertNotNil(
            ParakeetDecodingBias.languagePenalty(forLanguageCode: "fr", modelsRoot: root)
        )
        XCTAssertNotNil(
            ParakeetDecodingBias.languagePenalty(forLanguageCode: "fr-FR", modelsRoot: root)
        )
        // The suppressed tokens are English function words; applying them to
        // English dictation would suppress most of the transcript.
        XCTAssertNil(
            ParakeetDecodingBias.languagePenalty(forLanguageCode: "en", modelsRoot: root)
        )
        XCTAssertNil(
            ParakeetDecodingBias.languagePenalty(forLanguageCode: "", modelsRoot: root)
        )
    }

    func testLanguagePenaltyIsAbsentWithoutItsFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(
            ParakeetDecodingBias.languagePenalty(forLanguageCode: "fr", modelsRoot: root)
        )
    }

    func testLanguagePenaltyRejectsANonPositiveAmount() throws {
        let root = try penaltyFixture(ids: [506])

        XCTAssertNil(
            ParakeetDecodingBias.languagePenalty(
                forLanguageCode: "fr",
                modelsRoot: root,
                amount: 0
            )
        )
    }

    func testLanguagePenaltyCarriesEveryListedToken() throws {
        let root = try penaltyFixture(ids: [506, 575, 1050])

        let penalty = try XCTUnwrap(
            ParakeetDecodingBias.languagePenalty(
                forLanguageCode: "fr",
                modelsRoot: root,
                amount: 7
            )
        )
        XCTAssertEqual(Set(penalty.offsets.keys), [506, 575, 1050])
        XCTAssertEqual(penalty.offsets[506], -7)
    }

    func testShippedPenaltyListIsNotEmpty() throws {
        // The list is derived from corpus statistics rather than hand-written,
        // so an empty file would silently disable the fix.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Models/language-penalty.json")
        let data = try Data(contentsOf: url)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let ids = try XCTUnwrap(payload["french_suppressed_token_ids"] as? [Int])
        XCTAssertGreaterThan(ids.count, 50)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    private func shippedTokenizer() throws -> Tokenizer {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Artifacts/Training/voxol-wispr-mass-v3/coreml-candidates/"
                    + "nemo-direct-waveform-int8/tokenizer.json"
            )
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "The shipped runtime is not present on this machine."
        )
        return try Tokenizer(tokenizerJSONURL: url)
    }

    func testVocabularySegmentationCoversRealTerms() throws {
        let tokenizer = try shippedTokenizer()

        // The words a user would add are exactly the ones a generic model
        // fumbles, so segmentation has to reach them all.
        for term in ["Kubernetes", "VoxoL", "Parakeet", "Pyroute", "Zphyr"] {
            let pieces = try XCTUnwrap(
                tokenizer.pieces(forWord: term),
                "\(term) has no vocabulary segmentation"
            )
            XCTAssertFalse(pieces.isEmpty)
            // Round-tripping proves the boost targets this word and not a
            // prefix that would drag unrelated words along.
            let decoded = tokenizer.decode(pieces, skipSpecial: false)
            XCTAssertEqual(
                decoded.trimmingCharacters(in: .whitespaces).lowercased(),
                term.lowercased()
            )
        }
    }

    func testVocabularySegmentationMarksTheWordStart() throws {
        let tokenizer = try shippedTokenizer()

        let pieces = try XCTUnwrap(tokenizer.pieces(forWord: "Kubernetes"))
        // Without the SentencePiece word-start marker the boost would only
        // apply mid-word, which is never where a dictated term begins.
        let first = tokenizer.idToPiece[pieces[0]]
        XCTAssertTrue(first.hasPrefix(String(Tokenizer.metaSpace)), first)
    }

    func testVocabularySegmentationRejectsEmptyInput() throws {
        let tokenizer = try shippedTokenizer()

        XCTAssertNil(tokenizer.pieces(forWord: ""))
        XCTAssertNil(tokenizer.pieces(forWord: "   "))
    }

    private func logits(_ values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [NSNumber(value: values.count)], dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: values.count)
        for (index, value) in values.enumerated() { pointer[index] = value }
        return array
    }

    func testUnbiasedArgmaxPicksTheHighestLogit() throws {
        let row = try logits([0.1, 3.0, 2.0])

        XCTAssertEqual(GreedyTDTDecoder.argmax(row, biasedBy: nil), 1)
        XCTAssertEqual(GreedyTDTDecoder.argmax(row, biasedBy: ParakeetDecodingBias()), 1)
    }

    func testVectorizedLogitMarginMatchesScalarReference() throws {
        var values = (0..<8_193).map { index in
            Float((index * 37) % 997) / 13 - 20
        }
        values[4_321] = 91.25
        values[7_777] = 88.5
        let row = try logits(values)

        var runnerUp = -Float.infinity
        for index in values.indices where index != 4_321 {
            runnerUp = max(runnerUp, values[index])
        }

        XCTAssertEqual(
            GreedyTDTDecoder.logitMargin(row, winnerIndex: 4_321),
            max(0, values[4_321] - runnerUp),
            accuracy: 0.000_001
        )
    }

    func testABoostWinsOnlyWhenItClearsEveryCompetitor() throws {
        let row = try logits([0.0, 3.0, 2.0])

        // Two logits is not enough to overturn a one-point lead plus margin.
        XCTAssertEqual(
            GreedyTDTDecoder.argmax(row, biasedBy: .encouraging([2], by: 0.5)),
            1
        )
        // Four is. This is the whole point of a soft bias: it nudges a close
        // acoustic match over the line, it does not overrule the audio.
        XCTAssertEqual(
            GreedyTDTDecoder.argmax(row, biasedBy: .encouraging([2], by: 4)),
            2
        )
    }

    func testAPenalisedTokenStillWinsOnStrongEvidence() throws {
        // "the" does occur in genuine French speech when someone quotes, so a
        // 12-logit penalty must lose to a large enough acoustic margin.
        let row = try logits([0.0, 30.0, 1.0])

        XCTAssertEqual(
            GreedyTDTDecoder.argmax(row, biasedBy: .discouraging([1], by: 12)),
            1
        )
        XCTAssertEqual(
            GreedyTDTDecoder.argmax(row, biasedBy: .discouraging([1], by: 12 + 30)),
            2
        )
    }

    func testBiasLeavesUnlistedTokensUntouched() throws {
        let row = try logits([5.0, 1.0, 1.0])

        // Penalising something else must not promote a token on its own.
        XCTAssertEqual(
            GreedyTDTDecoder.argmax(row, biasedBy: .discouraging([1, 2], by: 100)),
            0
        )
    }

    func testDecodingBiasMergeSumsCollidingOffsets() {
        let boost = ParakeetDecodingBias.encouraging([1, 2], by: 4)
        let penalty = ParakeetDecodingBias.discouraging([2, 3], by: 12)

        let merged = boost.merging(penalty)

        XCTAssertEqual(merged.offsets[1], 4)
        // A term the user added that is also a suppressed English token nets
        // out rather than one side silently winning.
        XCTAssertEqual(merged.offsets[2], 4 - 12)
        XCTAssertEqual(merged.offsets[3], -12)
    }

    func testSparseBiasMatchesOriginalSelectionAndPreservesInputBits() throws {
        var seed: UInt64 = 20260914
        func random() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return seed
        }
        func check(_ values: [Float], offsets: [Int: Float]) throws {
            let row = try logits(values)
            var expected = 0
            var maximum = -Float.infinity
            var adjusted = values
            for index in values.indices {
                let adjusted = values[index] + (offsets[index] ?? 0)
                if adjusted > maximum {
                    expected = index
                    maximum = adjusted
                }
            }
            for (index, offset) in offsets where index >= 0 && index < adjusted.count {
                adjusted[index] += offset
            }
            XCTAssertEqual(
                GreedyTDTDecoder.argmax(row, biasedBy: .init(offsets: offsets)), expected)
            XCTAssertEqual(
                adjusted.withUnsafeBufferPointer {
                    GreedyTDTDecoder.argmaxAdjustedBuffer(
                        $0.baseAddress!, count: $0.count, accelerated: true)
                },
                expected
            )
            let pointer = row.dataPointer.bindMemory(to: Float.self, capacity: values.count)
            XCTAssertEqual(
                values.indices.map { pointer[$0].bitPattern }, values.map(\.bitPattern))
        }
        for count in [3, 127, 8_193] {
            for biasedCount in [1, 8, 80, count] {
                for _ in 0..<8 {
                    let values = (0..<count).map { _ in Float(Int(random() % 201) - 100) / 8 }
                    var offsets = [Int: Float]()
                    for _ in 0..<biasedCount {
                        offsets[Int(random() % UInt64(count))] =
                            Float(Int(random() % 101) - 50) / 8
                    }
                    offsets[-1] = 1_000
                    offsets[count] = 1_000
                    try check(values, offsets: offsets)
                }
            }
        }
        try check([.nan, 1, 3], offsets: [1: 3, 2: 1])
        try check([.infinity, .infinity, 5], offsets: [0: -.infinity])
        try check([-.infinity, -.infinity], offsets: [1: 0])
        try check([0, -0.0, 1], offsets: [2: -1])
        try check([1, 2, 3], offsets: [-1: 999, 3: 999])
    }

    func testNonPositiveBiasFastPathReturnsUnpenalisedWinner() throws {
        let row = try logits([1, 9, 5])
        let bias = ParakeetDecodingBias(offsets: [0: -12, 2: -3])

        XCTAssertTrue(bias.isNonPositive)
        XCTAssertEqual(
            GreedyTDTDecoder.unchangedWinnerForNonPositiveBias(row, bias: bias),
            1
        )
        XCTAssertEqual(GreedyTDTDecoder.argmax(row, biasedBy: bias), 1)
    }

    func testNonPositiveBiasFastPathFallsBackWhenWinnerIsPenalised() throws {
        let row = try logits([1, 9, 8])
        let bias = ParakeetDecodingBias(offsets: [1: -12])

        XCTAssertNil(GreedyTDTDecoder.unchangedWinnerForNonPositiveBias(row, bias: bias))
        XCTAssertEqual(GreedyTDTDecoder.argmax(row, biasedBy: bias), 2)
    }

    func testNonPositiveBiasFastPathRejectsPositiveOffsets() throws {
        let row = try logits([1, 9, 8])
        let bias = ParakeetDecodingBias(offsets: [2: 4])

        XCTAssertFalse(bias.isNonPositive)
        XCTAssertNil(GreedyTDTDecoder.unchangedWinnerForNonPositiveBias(row, bias: bias))
    }

    func testNonPositiveBiasFastPathPreservesFirstIndexTie() throws {
        let row = try logits([9, 9, 8])
        let bias = ParakeetDecodingBias(offsets: [2: -12])

        XCTAssertEqual(
            GreedyTDTDecoder.unchangedWinnerForNonPositiveBias(row, bias: bias),
            0
        )
    }

    func testNonPositiveBiasFastPathMatchesAdjustedReferenceWhenItReturnsWinner() throws {
        var seed: UInt64 = 20260924
        func random() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return seed
        }

        for count in [3, 127, 8_193] {
            for _ in 0..<24 {
                let values = (0..<count).map { _ in
                    Float(Int(random() % 401) - 200) / 8
                }
                var offsets = [Int: Float]()
                for _ in 0..<min(count, 136) {
                    offsets[Int(random() % UInt64(count))] =
                        -Float(random() % 97) / 8
                }
                let row = try logits(values)
                let bias = ParakeetDecodingBias(offsets: offsets)
                guard let fastWinner = GreedyTDTDecoder.unchangedWinnerForNonPositiveBias(
                    row,
                    bias: bias
                ) else { continue }

                var adjusted = values
                for (index, offset) in offsets where index >= 0 && index < count {
                    adjusted[index] += offset
                }
                let reference = adjusted.withUnsafeBufferPointer {
                    GreedyTDTDecoder.argmaxAdjustedBuffer(
                        $0.baseAddress!, count: $0.count, accelerated: true
                    )
                }
                XCTAssertEqual(fastWinner, reference)
            }
        }

        for (values, offsets) in [
            ([Float.nan, 4, 3], [2: Float(-12)]),
            ([Float.infinity, 5, 4], [2: Float(-12)]),
            ([Float.infinity, Float.infinity, 4], [2: Float(-12)]),
            ([Float(0), -Float.zero, -1], [2: Float(-12)]),
        ] {
            let row = try logits(values)
            let bias = ParakeetDecodingBias(offsets: offsets)
            guard let fastWinner = GreedyTDTDecoder.unchangedWinnerForNonPositiveBias(
                row,
                bias: bias
            ) else { continue }
            var adjusted = values
            for (index, offset) in offsets where index >= 0 && index < adjusted.count {
                adjusted[index] += offset
            }
            let reference = adjusted.withUnsafeBufferPointer {
                GreedyTDTDecoder.argmaxAdjustedBuffer(
                    $0.baseAddress!, count: $0.count, accelerated: true
                )
            }
            XCTAssertEqual(fastWinner, reference)
        }
    }

    func testDecodingBiasIsEmptyWhenNothingApplies() {
        XCTAssertTrue(ParakeetDecodingBias().isEmpty)
        XCTAssertFalse(ParakeetDecodingBias.encouraging([1], by: 1).isEmpty)
    }

    private func penaltyFixture(ids: [Int]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let payload: [String: Any] = ["french_suppressed_token_ids": ids]
        try JSONSerialization.data(withJSONObject: payload).write(
            to: root.appendingPathComponent("language-penalty.json")
        )
        return root
    }

    private func confidence(
        lowerDecileMargin: Double,
        emittedTokenCount: Int = 10
    ) -> TranscriptionConfidence {
        TranscriptionConfidence(
            emittedTokenCount: emittedTokenCount,
            meanTokenLogitMargin: lowerDecileMargin + 1,
            lowerDecileTokenLogitMargin: lowerDecileMargin,
            meanDurationLogitMargin: 1,
            lowerDecileDurationLogitMargin: 0.5,
            blankDecisionRatio: 0.4,
            maximumFramesWithoutEmission: 8,
            minimumOverlapTokenAgreement: nil,
            meanOverlapTokenAgreement: nil
        )
    }
}
