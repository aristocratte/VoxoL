import XCTest

@testable import AudioCaptureKit

final class VoiceProcessingModeTests: XCTestCase {
    func testAutomaticFollowsTheMicrophone() {
        XCTAssertTrue(VoiceProcessingMode.automatic.shouldEnable(forBuiltInMicrophone: true))
        XCTAssertFalse(VoiceProcessingMode.automatic.shouldEnable(forBuiltInMicrophone: false))
    }

    func testOverridesIgnoreTheMicrophone() {
        XCTAssertTrue(VoiceProcessingMode.enabled.shouldEnable(forBuiltInMicrophone: false))
        XCTAssertFalse(VoiceProcessingMode.disabled.shouldEnable(forBuiltInMicrophone: true))
    }
}

final class CaptureTakeQualityTests: XCTestCase {
    private func capture(
        seconds: Double,
        peak: Float,
        speech: Bool,
        clipped: Int = 0
    ) -> CapturedAudio {
        CapturedAudio(
            samples: [Float](repeating: 0, count: Int(seconds * 16_000)),
            speechDetected: speech,
            droppedSampleCount: 0,
            maximumRootMeanSquare: peak,
            clippedSampleCount: clipped
        )
    }

    func testAWellPlacedTakeIsGood() {
        XCTAssertEqual(
            CaptureTakeQuality.assess(capture(seconds: 4, peak: 0.2, speech: true)),
            .good
        )
    }

    func testDetectedSpeechIsNeverCalledQuiet() {
        // Pinned to a field report: a normal take was flagged "too quiet".
        // Measured afterwards, the owner's successful dictations peak
        // anywhere from 0.017 to 0.074 — an absolute level on a working take
        // cannot separate fine from far, so it must not try.
        XCTAssertEqual(
            CaptureTakeQuality.assess(capture(seconds: 4, peak: 0.018, speech: true)),
            .good
        )
        XCTAssertEqual(
            CaptureTakeQuality.assess(capture(seconds: 4, peak: 0.01, speech: true)),
            .good
        )
    }

    func testALongSilentTakeIsTheTooFarSignature() {
        // Held the key for four seconds, endpointer heard nothing, level below
        // anything that ever transcribed: the person almost certainly spoke,
        // from too far away.
        XCTAssertEqual(
            CaptureTakeQuality.assess(capture(seconds: 4, peak: 0.005, speech: false)),
            .tooQuiet
        )
    }

    func testAQuietRoomWithoutSpeechStaysUnjudged() {
        // Long take, no speech, but the level says a live room rather than a
        // distant voice — that is a stray key press, not a placement problem.
        XCTAssertEqual(
            CaptureTakeQuality.assess(capture(seconds: 4, peak: 0.02, speech: false)),
            .good
        )
    }

    func testABriefSilentTapIsNotSecondGuessed() {
        // A key tapped for half a second is a mistake, not a placement problem.
        XCTAssertEqual(
            CaptureTakeQuality.assess(capture(seconds: 0.5, peak: 0.001, speech: false)),
            .good
        )
    }

    func testClippingOutranksEverythingElse() {
        let clipped = capture(seconds: 4, peak: 0.9, speech: true, clipped: 3_200)
        XCTAssertEqual(CaptureTakeQuality.assess(clipped), .clipped)
    }

    func testAStrayPopInSilenceIsNotClipping() {
        // Electrical pops with no speech distort nothing anyone said.
        let pop = capture(seconds: 4, peak: 0.99, speech: false, clipped: 3_200)
        XCTAssertEqual(CaptureTakeQuality.assess(pop), .good)
    }

    func testAnEmptyCaptureIsLeftAlone() {
        let empty = CapturedAudio(
            samples: [],
            speechDetected: false,
            droppedSampleCount: 0
        )
        XCTAssertEqual(CaptureTakeQuality.assess(empty), .good)
    }
}
