import InjectionKit
import XCTest

final class InsertionPolicyTests: XCTestCase {
    func testRestoresClipboardWhenTemporaryValueStillOwnsIt() {
        XCTAssertTrue(
            InsertionPolicy.shouldRestorePasteboard(
                injectedChangeCount: 12,
                currentChangeCount: 12
            )
        )
    }

    func testPreservesClipboardWhenUserChangedItDuringPaste() {
        XCTAssertFalse(
            InsertionPolicy.shouldRestorePasteboard(
                injectedChangeCount: 12,
                currentChangeCount: 13
            )
        )
    }

    func testManualClipboardRecoveryCoversUnavailableFocusAndPasteEvents() {
        XCTAssertTrue(
            InsertionRecoveryPolicy.allowsManualClipboardRecovery(
                for: .focusedElementUnavailable
            )
        )
        XCTAssertTrue(
            InsertionRecoveryPolicy.allowsManualClipboardRecovery(
                for: .pasteEventUnavailable
            )
        )
    }

    func testManualClipboardRecoveryNeverCopiesIntoSecureFieldFlow() {
        XCTAssertFalse(
            InsertionRecoveryPolicy.allowsManualClipboardRecovery(for: .secureField)
        )
        XCTAssertFalse(
            InsertionRecoveryPolicy.allowsManualClipboardRecovery(for: .pasteboardWriteFailed)
        )
    }

    func testAutomaticPasteAllowsMissingAccessibilityElementInSameApplication() {
        XCTAssertTrue(
            InsertionDestinationPolicy.allowsAutomaticPaste(
                capturedProcessIdentifier: 42,
                currentProcessIdentifier: 42,
                secureFieldDetected: false,
                secureEventInputEnabled: false
            )
        )
    }

    func testAutomaticPasteRejectsChangedApplicationAndSecureInput() {
        XCTAssertFalse(
            InsertionDestinationPolicy.allowsAutomaticPaste(
                capturedProcessIdentifier: 42,
                currentProcessIdentifier: 43,
                secureFieldDetected: false,
                secureEventInputEnabled: false
            )
        )
        XCTAssertFalse(
            InsertionDestinationPolicy.allowsAutomaticPaste(
                capturedProcessIdentifier: 42,
                currentProcessIdentifier: 42,
                secureFieldDetected: true,
                secureEventInputEnabled: false
            )
        )
        XCTAssertFalse(
            InsertionDestinationPolicy.allowsAutomaticPaste(
                capturedProcessIdentifier: 42,
                currentProcessIdentifier: 42,
                secureFieldDetected: false,
                secureEventInputEnabled: true
            )
        )
    }

    func testContextualSpacingInMiddleOfSentence() {
        XCTAssertEqual(
            InsertionTextPolicy.adjust(
                "beautiful world",
                beforeCursor: "Hello",
                afterCursor: "again."
            ),
            " beautiful world "
        )
    }

    func testContextualSpacingRespectsWhitespaceAndPunctuation() {
        XCTAssertEqual(
            InsertionTextPolicy.adjust(
                "world",
                beforeCursor: "Hello ",
                afterCursor: "."
            ),
            "world"
        )
        XCTAssertEqual(
            InsertionTextPolicy.adjust(
                ", thanks",
                beforeCursor: "Hello",
                afterCursor: ""
            ),
            ", thanks"
        )
    }
}
