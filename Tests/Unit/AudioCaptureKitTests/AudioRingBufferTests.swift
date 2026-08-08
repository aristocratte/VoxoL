import AudioCaptureKit
import XCTest

final class AudioRingBufferTests: XCTestCase {
    func testPreservesOrderAcrossWrapAround() {
        let ring = AudioRingBuffer(capacity: 5)
        XCTAssertEqual(write([1, 2, 3, 4], to: ring), 4)
        XCTAssertEqual(ring.read(maximumCount: 3), [1, 2, 3])
        XCTAssertEqual(write([5, 6, 7, 8], to: ring), 4)

        XCTAssertEqual(ring.readAll(), [4, 5, 6, 7, 8])
    }

    func testRejectsOverflowWithoutOverwritingUnreadSamples() {
        let ring = AudioRingBuffer(capacity: 3)

        XCTAssertEqual(write([1, 2, 3, 4], to: ring), 3)
        XCTAssertEqual(ring.readAll(), [1, 2, 3])
    }

    func testEmptyReadIsStable() {
        let ring = AudioRingBuffer(capacity: 2)

        XCTAssertEqual(ring.availableSampleCount, 0)
        XCTAssertEqual(ring.readAll(), [])
    }

    func testLatestSnapshotDoesNotConsumeSamples() {
        let ring = AudioRingBuffer(capacity: 6)
        XCTAssertEqual(write([1, 2, 3, 4, 5], to: ring), 5)

        XCTAssertEqual(ring.snapshotLatest(maximumCount: 3), [3, 4, 5])
        XCTAssertEqual(ring.readAll(), [1, 2, 3, 4, 5])
    }
}

private extension AudioRingBufferTests {
    func write(_ samples: [Float], to ring: AudioRingBuffer) -> Int {
        samples.withUnsafeBufferPointer { ring.write($0) }
    }
}
