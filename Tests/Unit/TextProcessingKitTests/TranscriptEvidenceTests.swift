import XCTest

@testable import TextProcessingKit

final class TranscriptEvidenceTests: XCTestCase {
    func testEvidenceRangesStayAlignedAcrossNormalizationAndPlaceholders() throws {
        let raw = "envoie   42 fichiers"
        let words = TranscriptEvidence.unknown(text: raw, source: .parakeet).words
        let evidence = TranscriptEvidence(
            sourceText: raw,
            source: .parakeet,
            words: words.enumerated().map { index, word in
                TranscriptWordEvidence(
                    surface: word.surface,
                    sourceRange: word.sourceRange,
                    tokens: [
                        TranscriptTokenEvidence(
                            tokenID: index,
                            tokenIndex: index,
                            frameIndex: index * 4,
                            durationFrames: 2,
                            logitMargin: Float(index + 1)
                        )
                    ],
                    frameRange: (index * 4)..<(index * 4 + 2),
                    minimumLogitMargin: Float(index + 1),
                    meanLogitMargin: Float(index + 1),
                    contextBiasActive: true,
                    nearChunkBoundary: false
                )
            }
        )
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: raw,
                preferredLanguage: .french,
                preferences: TextProcessingPreferences(fastPathEnabled: false),
                transcriptEvidence: evidence
            )
        )

        let preparedEvidence = try XCTUnwrap(preparation.transcriptEvidence)
        XCTAssertEqual(preparedEvidence.sourceText, preparation.promptText)
        XCTAssertTrue(preparedEvidence.hasValidSourceRanges)
        let placeholder = try XCTUnwrap(
            preparedEvidence.words.first(where: { $0.surface.hasPrefix("VOXOLP") })
        )
        XCTAssertEqual(placeholder.minimumLogitMargin, 2)
        XCTAssertEqual(placeholder.tokens.map(\.tokenID), [1])
    }

    func testChunkingSlicesEvidenceInsteadOfReusingWholeTranscriptOffsets() throws {
        let text = "Premier rapport terminé. Deuxième rapport envoyé."
        let evidence = TranscriptEvidence.unknown(text: text, source: .appleSpeech)

        let chunks = TranscriptChunker.split(text, evidence: evidence, maximumWords: 3)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].evidence?.sourceText, chunks[0].text)
        XCTAssertEqual(chunks[1].evidence?.sourceText, chunks[1].text)
        XCTAssertTrue(try XCTUnwrap(chunks[0].evidence).hasValidSourceRanges)
        XCTAssertTrue(try XCTUnwrap(chunks[1].evidence).hasValidSourceRanges)
        XCTAssertEqual(chunks[0].evidence?.words.count, 3)
        XCTAssertEqual(chunks[1].evidence?.words.count, 3)
    }

    func testCalibrationInterpolatesRiskAndLeavesUnknownEnginesUnknown() throws {
        let table = ASRWordRiskCalibration(
            knots: [
                .init(margin: 0, errorProbability: 0.9),
                .init(margin: 2, errorProbability: 0.1),
            ]
        )
        let token = TranscriptTokenEvidence(
            tokenID: 1,
            tokenIndex: 0,
            frameIndex: 2,
            durationFrames: 1,
            logitMargin: 1
        )
        let known = TranscriptEvidence(
            sourceText: "terme",
            source: .parakeet,
            words: [
                TranscriptWordEvidence(
                    surface: "terme",
                    sourceRange: 0..<5,
                    tokens: [token],
                    minimumLogitMargin: 1
                )
            ]
        )

        XCTAssertEqual(
            try XCTUnwrap(table.applying(to: known).words.first?.calibratedErrorProbability),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertNil(
            table.applying(to: .unknown(text: "terme", source: .appleSpeech))
                .words.first?.calibratedErrorProbability
        )
    }

    func testFeatureFlagsAreAllDisabledByDefault() {
        XCTAssertEqual(TextQualityFeatureFlags.disabled, TextQualityFeatureFlags())
        XCTAssertFalse(TextQualityFeatureFlags.disabled.textQualityV3Shadow)
        XCTAssertFalse(TextQualityFeatureFlags.disabled.editGateV3)
        XCTAssertFalse(TextQualityFeatureFlags.disabled.codeDictationV1)
        XCTAssertFalse(TextQualityFeatureFlags.disabled.qwenPatchMode)
        XCTAssertFalse(TextQualityFeatureFlags.disabled.selectiveASRRescue)
    }
}
