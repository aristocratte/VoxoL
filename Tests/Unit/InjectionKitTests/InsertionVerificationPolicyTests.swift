import InjectionKit
import XCTest

final class InsertionVerificationPolicyTests: XCTestCase {
    func testCaretThatDidNotMoveMeansNothingWasInserted() {
        // What a Chromium web view does: it accepts the write, answers success, inserts nothing.
        let caret = TextSelection(location: 12, length: 0)
        XCTAssertFalse(
            InsertionVerificationPolicy.landed(
                before: caret,
                after: caret,
                insertedCharacterCount: 24
            )
        )
    }

    func testCaretThatAdvancedMeansTheTextLanded() {
        XCTAssertTrue(
            InsertionVerificationPolicy.landed(
                before: TextSelection(location: 12, length: 0),
                after: TextSelection(location: 36, length: 0),
                insertedCharacterCount: 24
            )
        )
    }

    func testReplacingASelectionCountsAsLanded() {
        // The caret can stay put while a selection collapses; that is still a real insertion.
        XCTAssertTrue(
            InsertionVerificationPolicy.landed(
                before: TextSelection(location: 4, length: 10),
                after: TextSelection(location: 4, length: 0),
                insertedCharacterCount: 10
            )
        )
    }

    func testUnreadableSelectionsAreTrustedRatherThanPastedTwice() {
        XCTAssertTrue(
            InsertionVerificationPolicy.landed(
                before: nil,
                after: TextSelection(location: 3, length: 0),
                insertedCharacterCount: 5
            )
        )
        XCTAssertTrue(
            InsertionVerificationPolicy.landed(
                before: TextSelection(location: 3, length: 0),
                after: nil,
                insertedCharacterCount: 5
            )
        )
    }
}
