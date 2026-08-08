import EndpointingKit
import XCTest

final class DeterministicEndpointDetectorTests: XCTestCase {
    func testSilenceDoesNotStartSpeech() {
        var detector = DeterministicEndpointDetector()
        let silence = [Float](repeating: 0, count: detector.configuration.frameSampleCount)

        let events = (0..<50).map { _ in process(silence, with: &detector) }

        XCTAssertEqual(Set(events), [.silence])
        XCTAssertLessThan(detector.lastFeatures.rootMeanSquare, 0.001)
    }

    func testSpeechStartsAfterConfiguredMinimumDuration() {
        var detector = DeterministicEndpointDetector()
        let speech = sineFrame(sampleCount: detector.configuration.frameSampleCount)

        let earlyEvents = (0..<4).map { _ in process(speech, with: &detector) }
        let confirmed = process(speech, with: &detector)

        XCTAssertEqual(Set(earlyEvents), [.silence])
        XCTAssertEqual(confirmed, .speechStarted)
    }

    func testShortImpulseDoesNotLeaveDetectorInSpeechState() {
        let configuration = EndpointConfiguration(
            minimumSpeechFrames: 5,
            speechStartFrames: 2,
            speechEndFrames: 3
        )
        var detector = DeterministicEndpointDetector(configuration: configuration)
        let speech = sineFrame(sampleCount: configuration.frameSampleCount)
        let silence = [Float](repeating: 0, count: configuration.frameSampleCount)

        for _ in 0..<3 {
            XCTAssertEqual(process(speech, with: &detector), .silence)
        }
        for _ in 0..<5 {
            XCTAssertEqual(process(silence, with: &detector), .silence)
        }
        for _ in 0..<4 {
            XCTAssertEqual(process(speech, with: &detector), .silence)
        }
        XCTAssertEqual(process(speech, with: &detector), .speechStarted)
    }

    func testSpeechEndsOnlyAfterSustainedSilence() {
        let configuration = EndpointConfiguration(
            minimumSpeechFrames: 3,
            speechStartFrames: 2,
            speechEndFrames: 4
        )
        var detector = DeterministicEndpointDetector(configuration: configuration)
        let speech = sineFrame(sampleCount: configuration.frameSampleCount)
        let silence = [Float](repeating: 0, count: configuration.frameSampleCount)

        for _ in 0..<6 {
            _ = process(speech, with: &detector)
        }
        XCTAssertEqual(process(silence, with: &detector), .speechContinued)
        XCTAssertEqual(process(silence, with: &detector), .speechContinued)
        XCTAssertEqual(process(silence, with: &detector), .speechContinued)
        XCTAssertEqual(process(silence, with: &detector), .speechEnded)
    }
}

private extension DeterministicEndpointDetectorTests {
    func process(
        _ frame: [Float],
        with detector: inout DeterministicEndpointDetector
    ) -> EndpointEvent {
        frame.withUnsafeBufferPointer { detector.process($0) }
    }

    func sineFrame(sampleCount: Int) -> [Float] {
        (0..<sampleCount).map { index in
            0.12 * sin(Float(index) * 2 * .pi * 220 / 16_000)
        }
    }
}
