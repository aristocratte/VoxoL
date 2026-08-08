import Foundation
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
}
