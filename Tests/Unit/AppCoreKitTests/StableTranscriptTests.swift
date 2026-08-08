import AppCoreKit
import XCTest

final class StableTranscriptTests: XCTestCase {
    func testCommitsOnlyConsecutiveCommonPrefix() {
        var tracker = StableTranscriptTracker()

        XCTAssertEqual(tracker.observe("hello wor"), "")
        XCTAssertEqual(tracker.observe("hello world from"), "hello")
        XCTAssertEqual(tracker.observe("hello world from VoxoL"), "hello world from")
    }

    func testStablePrefixNeverRegresses() {
        var tracker = StableTranscriptTracker()

        _ = tracker.observe("send it on Tuesday")
        XCTAssertEqual(tracker.observe("send it on Wednesday"), "send it on")
        XCTAssertEqual(tracker.observe("send this on Wednesday"), "send it on")
    }
}
