import XCTest

@testable import AppCoreKit

final class HoldToTalkStateMachineTests: XCTestCase {
    func testEndpointEvidenceKeepsCapsuleListeningUntilPhysicalRelease() {
        var machine = HoldToTalkStateMachine()

        machine.handle(.shortcutPressed)
        machine.handle(.captureStarted)
        machine.handle(.endpointDetectedSpeech)

        XCTAssertTrue(machine.shortcutIsHeld)
        XCTAssertTrue(machine.speechWasDetected)
        XCTAssertEqual(machine.phase, .listening)

        machine.handle(.shortcutReleased)

        XCTAssertFalse(machine.shortcutIsHeld)
        XCTAssertEqual(machine.phase, .processing)
    }

    func testCancellationReturnsToReadyWithoutProcessing() {
        var machine = HoldToTalkStateMachine()
        machine.handle(.shortcutPressed)
        machine.handle(.captureStarted)

        machine.handle(.cancelled)

        XCTAssertFalse(machine.shortcutIsHeld)
        XCTAssertEqual(machine.phase, .ready)
    }
}
