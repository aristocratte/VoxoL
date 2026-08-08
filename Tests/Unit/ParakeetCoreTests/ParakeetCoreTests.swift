import CoreML
import Foundation
@testable import ParakeetCore
import XCTest

final class ParakeetCoreTests: XCTestCase {
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
