import XCTest

@testable import ParakeetCore

final class TokenSeamAlignmentTests: XCTestCase {
    func testUniqueAlignedAnchorReplacesTheTruncatedTail() {
        let result = TokenSeamAlignment.select(
            previousTokens: [1, 2, 3, 4, 5, 6, 999],
            previousFrames: [0, 20, 40, 45, 50, 55, 59], previousValidFrames: 60,
            minimumPreviousIndex: 0, currentTokens: [3, 4, 5, 6, 7, 8],
            currentFrames: [0, 5, 10, 15, 20, 25], overlapFrames: 20)
        XCTAssertEqual(result, .init(previousEnd: 2, currentStart: 0))
    }

    func testNoOverlapDoesNotChangeASeam() {
        XCTAssertNil(
            TokenSeamAlignment.select(
                previousTokens: [1, 2, 3, 4], previousFrames: [0, 1, 2, 3],
                previousValidFrames: 4, minimumPreviousIndex: 0,
                currentTokens: [1, 2, 3, 4], currentFrames: [0, 1, 2, 3], overlapFrames: 0))
    }

    func testRepeatedAnchorsAreAmbiguous() {
        XCTAssertNil(
            TokenSeamAlignment.select(
                previousTokens: [7, 7, 7, 7, 7, 7], previousFrames: [0, 1, 2, 3, 4, 5],
                previousValidFrames: 6, minimumPreviousIndex: 0,
                currentTokens: [7, 7, 7, 7, 7, 7], currentFrames: [0, 1, 2, 3, 4, 5],
                overlapFrames: 6))
    }

    func testTokenEqualityWithoutTimeAgreementIsInsufficient() {
        XCTAssertNil(
            TokenSeamAlignment.select(
                previousTokens: [1, 2, 3, 4], previousFrames: [70, 75, 80, 85],
                previousValidFrames: 100, minimumPreviousIndex: 0,
                currentTokens: [1, 2, 3, 4], currentFrames: [0, 5, 10, 15], overlapFrames: 40))
    }

    func testNoApproximateOrVocabularySpecificMatching() {
        XCTAssertNil(
            TokenSeamAlignment.select(
                previousTokens: [1, 2, 3, 4], previousFrames: [0, 1, 2, 3],
                previousValidFrames: 4, minimumPreviousIndex: 0,
                currentTokens: [1, 2, 9, 4], currentFrames: [0, 1, 2, 3], overlapFrames: 4))
    }

    func testMalformedParallelArraysFailClosed() {
        XCTAssertNil(
            TokenSeamAlignment.select(
                previousTokens: [1, 2, 3, 4], previousFrames: [0],
                previousValidFrames: 4, minimumPreviousIndex: 0,
                currentTokens: [1, 2, 3, 4], currentFrames: [0, 1, 2, 3], overlapFrames: 4))
    }

    func testCannotBringBackAnAlreadyDiscardedPrefix() {
        XCTAssertNil(
            TokenSeamAlignment.select(
                previousTokens: [1, 2, 3, 4], previousFrames: [0, 1, 2, 3],
                previousValidFrames: 4, minimumPreviousIndex: 1,
                currentTokens: [1, 2, 3, 4], currentFrames: [0, 1, 2, 3], overlapFrames: 4))
    }
}
