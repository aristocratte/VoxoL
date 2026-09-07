import Foundation
import TextProcessingKit
import XCTest

@testable import QwenPolisher

final class SessionPolishingCacheTests: XCTestCase {
    private func key(_ text: String, system: String = "faithful", limit: Int = 384)
        -> PolishingRequestKey
    {
        PolishingRequestKey(.init(system: system, user: text, maximumOutputTokens: limit))
    }

    private func result(_ text: String = "ready") -> QwenPolisherResult {
        .init(
            text: text, durationSeconds: 0.5, promptTokenCount: 200,
            outputTokenCount: 5, promptDurationSeconds: 0.1,
            generationDurationSeconds: 0.4, reusedPromptTokenCount: 160)
    }

    func testNoImplicitCrossDictationMemoization() {
        var cache = SessionPolishingCache()
        cache.store(result(), for: key("hello"), session: nil)
        XCTAssertNil(cache.result(for: key("hello"), session: nil))
        let session = UUID()
        cache.begin(session)
        cache.store(result(), for: key("hello"), session: session)
        XCTAssertEqual(cache.result(for: key("hello"), session: session)?.text, "ready")
        cache.end(session)
        XCTAssertNil(cache.result(for: key("hello"), session: session))
        XCTAssertEqual(cache.byteCount, 0)
    }

    func testLateCompletionCannotWriteIntoNewSession() {
        var cache = SessionPolishingCache()
        let old = UUID(), current = UUID()
        cache.begin(old)
        cache.begin(current)
        cache.store(result(), for: key("late"), session: old)
        XCTAssertNil(cache.result(for: key("late"), session: current))
        cache.store(result(), for: key("current"), session: current)
        cache.end(old)
        XCTAssertNotNil(cache.result(for: key("current"), session: current))
    }

    func testEveryPromptFieldParticipatesInExactMatching() {
        var cache = SessionPolishingCache()
        let id = UUID()
        cache.begin(id)
        cache.store(result(), for: key("context A\ntranscript"), session: id)
        XCTAssertNil(cache.result(for: key("context B\ntranscript"), session: id))
        XCTAssertNil(
            cache.result(for: key("context A\ntranscript", system: "rewrite"), session: id))
        XCTAssertNil(cache.result(for: key("context A\ntranscript", limit: 128), session: id))
        XCTAssertNil(cache.result(for: key("context A\ntranscript "), session: id))
    }

    func testEntryLimitEvictsOldestWithoutMixingSessions() {
        var cache = SessionPolishingCache(maximumEntries: 2)
        let id = UUID()
        cache.begin(id)
        for item in ["one", "two", "three"] { cache.store(result(), for: key(item), session: id) }
        XCTAssertNil(cache.result(for: key("one"), session: id))
        XCTAssertNotNil(cache.result(for: key("two"), session: id))
        XCTAssertNotNil(cache.result(for: key("three"), session: id))
        cache.begin(UUID())
        XCTAssertEqual(cache.byteCount, 0)
    }

    func testByteLimitRejectsOversizedEntries() {
        var cache = SessionPolishingCache(maximumBytes: 256)
        let id = UUID()
        cache.begin(id)
        cache.store(result(String(repeating: "x", count: 300)), for: key("large"), session: id)
        XCTAssertNil(cache.result(for: key("large"), session: id))
        XCTAssertLessThanOrEqual(cache.byteCount, 256)
    }

    func testBeginningSameSessionDoesNotDiscardCompletedWork() {
        var cache = SessionPolishingCache()
        let id = UUID()
        cache.begin(id)
        cache.store(result(), for: key("same"), session: id)
        cache.begin(id)
        XCTAssertNotNil(cache.result(for: key("same"), session: id))
    }

    func testCompletedTerminalFailureIsReusedOnlyForTheExactSessionAndPrompt() {
        var cache = SessionPolishingCache()
        let id = UUID()
        cache.begin(id)
        cache.storeTerminalFailure(.tokenLimitReached, for: key("long"), session: id)
        XCTAssertEqual(cache.terminalFailure(for: key("long"), session: id), .tokenLimitReached)
        XCTAssertNil(cache.result(for: key("long"), session: id))
        XCTAssertNil(cache.terminalFailure(for: key("long", limit: 500), session: id))
        XCTAssertNil(cache.terminalFailure(for: key("long"), session: UUID()))
        XCTAssertNil(cache.terminalFailure(for: key("long"), session: nil))
        cache.end(id)
        XCTAssertNil(cache.terminalFailure(for: key("long"), session: id))
    }

    func testTransientFailuresAreNeverMemoized() {
        var cache = SessionPolishingCache()
        let id = UUID()
        cache.begin(id)
        for error in [QwenPolisherError.timedOut, .adapterLoadFailed("temporary")] {
            cache.storeTerminalFailure(error, for: key("retry"), session: id)
            XCTAssertNil(cache.terminalFailure(for: key("retry"), session: id))
        }
        XCTAssertEqual(cache.byteCount, 0)
        cache.storeTerminalFailure(.emptyOutput, for: key("empty"), session: id)
        XCTAssertEqual(cache.terminalFailure(for: key("empty"), session: id), .emptyOutput)
    }

    func testTerminalFailuresShareTheBoundedEvictionBudget() {
        var cache = SessionPolishingCache(maximumEntries: 1)
        let id = UUID()
        cache.begin(id)
        cache.storeTerminalFailure(.emptyOutput, for: key("empty"), session: id)
        cache.store(result(), for: key("ready"), session: id)
        XCTAssertNil(cache.terminalFailure(for: key("empty"), session: id))
        XCTAssertNotNil(cache.result(for: key("ready"), session: id))
    }

    func testExplicitSessionIDPreventsStaleOrUnscopedReads() {
        var cache = SessionPolishingCache()
        let old = UUID(), current = UUID()
        cache.begin(old)
        cache.begin(current)
        cache.store(result("current text"), for: key("identical request"), session: current)
        XCTAssertNil(cache.result(for: key("identical request"), session: old))
        XCTAssertNil(cache.result(for: key("identical request"), session: nil))
        XCTAssertEqual(
            cache.result(for: key("identical request"), session: current)?.text, "current text")
    }

    func testCanonicalUnicodeEqualityDoesNotMergeDifferentTokenizerInputs() {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(key(composed), key(decomposed))
        XCTAssertNotEqual(key("text", system: composed), key("text", system: decomposed))
        var cache = SessionPolishingCache()
        let id = UUID()
        cache.begin(id)
        cache.store(result(), for: key(composed), session: id)
        XCTAssertNil(cache.result(for: key(decomposed), session: id))
    }

    func testByteBudgetEvictsOldestEntryWithoutLosingAccounting() {
        var cache = SessionPolishingCache(maximumEntries: 96, maximumBytes: 300)
        let id = UUID()
        cache.begin(id)
        cache.store(result(), for: key("one"), session: id)
        cache.store(result(), for: key("two"), session: id)
        XCTAssertNil(cache.result(for: key("one"), session: id))
        XCTAssertNotNil(cache.result(for: key("two"), session: id))
        XCTAssertGreaterThan(cache.byteCount, 0)
        XCTAssertLessThanOrEqual(cache.byteCount, 300)
        cache.end(id)
        XCTAssertEqual(cache.byteCount, 0)
    }
}
