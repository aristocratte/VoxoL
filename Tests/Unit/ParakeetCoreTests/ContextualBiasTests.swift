import Foundation
import CoreML
import XCTest

@testable import ParakeetCore

final class ContextualBiasTests: XCTestCase {
    /// `humpback` as the tokenizer segments it, with `ack` also ending an
    /// unrelated word — the exact shape that made the flat boost harmful.
    private let humpback = [11, 22, 33, 44]
    private let unrelated = [99, 44]

    private func bias() -> ParakeetContextualBias {
        ParakeetContextualBias(
            termPieces: [humpback],
            entryBoost: 1,
            continuationBoost: 6
        )
    }

    private func logits(_ values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [NSNumber(value: values.count)],
            dataType: .float32
        )
        let pointer = array.dataPointer.bindMemory(
            to: Float32.self,
            capacity: values.count
        )
        for (index, value) in values.enumerated() {
            pointer[index] = value
        }
        return array
    }

    private func referenceArgmax(
        _ row: MLMultiArray,
        staticBias: ParakeetDecodingBias?,
        contextualBias: ParakeetContextualBias,
        state: ParakeetContextualBias.State
    ) -> Int {
        GreedyTDTDecoder.argmax(
            row,
            biasedBy: GreedyTDTDecoder.mergedBias(
                staticBias,
                contextualBias,
                state
            )
        )
    }

    private func directArgmax(
        _ row: MLMultiArray,
        staticBias: ParakeetDecodingBias?,
        contextualBias: ParakeetContextualBias,
        state: ParakeetContextualBias.State
    ) -> Int {
        GreedyTDTDecoder.argmaxApplyingContextualBias(
            row,
            staticBias: staticBias,
            contextualBias: contextualBias,
            contextState: state
        )
    }

    func testOnlyEntryPiecesAreBoostedAtTheStart() {
        let subject = bias()
        let offsets = subject.offsets(for: subject.initialState())

        XCTAssertEqual(offsets, [11: 1])
        // The pieces that wrecked the flat version are absent until earned.
        XCTAssertNil(offsets?[44])
        XCTAssertNil(offsets?[22])
    }

    func testAContinuationIsBoostedOnlyAfterItsPrefix() {
        let subject = bias()
        var state = subject.initialState()
        state = subject.advanced(state, emitting: 11)

        let offsets = subject.offsets(for: state)
        XCTAssertEqual(offsets?[22], 6, "the continuation should be encouraged")
        XCTAssertEqual(offsets?[11], 1, "a term may still start here")
    }

    func testABrokenMatchStopsBoostingTheRestOfTheTerm() {
        // This is the whole point: after `▁h` `x`, the decoder is not spelling
        // humpback any more and `ack` must go back to being an ordinary token.
        let subject = bias()
        var state = subject.initialState()
        state = subject.advanced(state, emitting: 11)
        state = subject.advanced(state, emitting: 77)

        let offsets = subject.offsets(for: state)
        XCTAssertEqual(offsets, [11: 1])
    }

    func testAPieceSharedWithAnotherWordIsNotBoostedOutOfContext() {
        let subject = ParakeetContextualBias(
            termPieces: [humpback, unrelated],
            entryBoost: 1,
            continuationBoost: 6
        )
        var state = subject.initialState()
        // Walk the full term: 11, 22, 33 then 44 is legitimately boosted.
        state = subject.advanced(state, emitting: 11)
        state = subject.advanced(state, emitting: 22)
        state = subject.advanced(state, emitting: 33)
        XCTAssertEqual(subject.offsets(for: state)?[44], 6)

        // From a cold start, 44 is not boosted even though it ends two terms.
        XCTAssertNil(subject.offsets(for: subject.initialState())?[44])
    }

    func testSeveralTermsSharingAPrefixStayActiveTogether() {
        let subject = ParakeetContextualBias(
            termPieces: [[1, 2], [1, 3]],
            entryBoost: 1,
            continuationBoost: 6
        )
        var state = subject.initialState()
        state = subject.advanced(state, emitting: 1)
        let offsets = subject.offsets(for: state)

        XCTAssertEqual(offsets?[2], 6)
        XCTAssertEqual(offsets?[3], 6)
    }

    func testAnEmptyVocabularyCostsNothing() {
        let subject = ParakeetContextualBias(termPieces: [])

        XCTAssertTrue(subject.isEmpty)
        XCTAssertNil(subject.offsets(for: subject.initialState()))
    }

    func testMergingKeepsTheLanguagePenaltyAndTheVocabularyBoost() {
        let penalty = ParakeetDecodingBias.discouraging([500], by: 12)
        let subject = bias()
        let merged = GreedyTDTDecoder.mergedBias(
            penalty,
            subject,
            subject.initialState()
        )

        XCTAssertEqual(merged?.offsets[500], -12)
        XCTAssertEqual(merged?.offsets[11], 1)
    }

    func testNoVocabularyLeavesTheStaticBiasUntouched() {
        let penalty = ParakeetDecodingBias.discouraging([500], by: 12)

        XCTAssertEqual(
            GreedyTDTDecoder.mergedBias(penalty, nil, nil)?.offsets,
            penalty.offsets
        )
    }

    func testDirectContextualArgmaxMatchesMergedReference() throws {
        let subject = ParakeetContextualBias(
            termPieces: [[1, 2], [4, 5]],
            entryBoost: 1,
            continuationBoost: 6
        )
        let state = subject.initialState()
        let row = try logits([0, 4.4, 0.5, 5, 4.2, 0])

        XCTAssertEqual(
            directArgmax(row, staticBias: nil, contextualBias: subject, state: state),
            referenceArgmax(row, staticBias: nil, contextualBias: subject, state: state)
        )
    }

    func testDirectContextualArgmaxMatchesStaticBiasCollision() throws {
        let subject = ParakeetContextualBias(
            termPieces: [[1, 2]],
            entryBoost: 1,
            continuationBoost: 6
        )
        let state = subject.advanced(subject.initialState(), emitting: 1)
        let penalty = ParakeetDecodingBias(offsets: [2: -12, 3: -1])
        let row = try logits([0, 0, 10, 4, 3])

        XCTAssertEqual(
            directArgmax(row, staticBias: penalty, contextualBias: subject, state: state),
            referenceArgmax(row, staticBias: penalty, contextualBias: subject, state: state)
        )
    }

    func testDirectContextualArgmaxKeepsStrongestSharedTokenBoost() throws {
        let subject = ParakeetContextualBias(
            termPieces: [[1], [1, 1], [1, 2]],
            entryBoost: 1,
            continuationBoost: 6
        )
        let state = subject.advanced(subject.initialState(), emitting: 1)
        XCTAssertEqual(subject.offsets(for: state)?[1], 6)
        let row = try logits([0, 1, 6.5, 0])

        XCTAssertEqual(
            directArgmax(row, staticBias: nil, contextualBias: subject, state: state),
            referenceArgmax(row, staticBias: nil, contextualBias: subject, state: state)
        )
    }

    func testDirectContextualArgmaxMatchesReferenceAcrossStatesAndCollisions() throws {
        let subject = ParakeetContextualBias(
            termPieces: [[1, 2, 3], [1, 2, 4], [2, 5], [5, 1]],
            entryBoost: 1,
            continuationBoost: 6
        )
        let staticBiases: [ParakeetDecodingBias?] = [
            nil,
            ParakeetDecodingBias(offsets: [1: -12, 2: -3, 5: 2]),
            ParakeetDecodingBias(offsets: [2: 4, 3: -8, 4: 1, 5: -2]),
        ]
        var state = subject.initialState()
        for step in 0..<12 {
            let values = (0..<8).map { index in
                Float(((index + 3) * (step + 5) * 17) % 113) / 11 - 4
            }
            let row = try logits(values)
            for staticBias in staticBiases {
                XCTAssertEqual(
                    directArgmax(
                        row,
                        staticBias: staticBias,
                        contextualBias: subject,
                        state: state
                    ),
                    referenceArgmax(
                        row,
                        staticBias: staticBias,
                        contextualBias: subject,
                        state: state
                    ),
                    "step=\(step), staticBias=\(String(describing: staticBias?.offsets))"
                )
            }
            state = subject.advanced(state, emitting: [1, 2, 7, 5][step % 4])
        }
    }
}
