import CoreML
import Foundation
import XCTest

@testable import ParakeetCore

final class EncoderResultCacheTests: XCTestCase {
    private func tensor(_ value: Float = 7) throws -> MLMultiArray {
        let tensor = try MLMultiArray(shape: [1, 1, 1], dataType: .float32)
        tensor[0] = NSNumber(value: value)
        return tensor
    }

    func testRequiresAnExplicitMatchingSessionForKeysAndResults() throws {
        let cache = EncoderResultCache()
        let id = UUID()
        XCTAssertNil(cache.key(samples: [1], sourceCompatibleFeatures: false, session: id))
        cache.begin(id)
        let key = try XCTUnwrap(
            cache.key(samples: [1], sourceCompatibleFeatures: false, session: id))
        cache.store(hidden: try tensor(), mask: try tensor(1), for: key, session: id)
        XCTAssertNotNil(cache.value(for: key, session: id))
        XCTAssertNil(cache.value(for: key, session: nil))
        XCTAssertNil(cache.value(for: key, session: UUID()))
        cache.end(id)
        XCTAssertNil(cache.value(for: key, session: id))
        XCTAssertEqual(cache.byteCount, 0)
    }

    func testSampleBytesAndNormalizationParticipateInTheKey() throws {
        let cache = EncoderResultCache()
        let id = UUID()
        cache.begin(id)
        let key = try XCTUnwrap(
            cache.key(samples: [0, 1], sourceCompatibleFeatures: false, session: id))
        XCTAssertNotEqual(
            key,
            cache.key(samples: [0, Float(1).nextUp], sourceCompatibleFeatures: false, session: id))
        XCTAssertNotEqual(
            key, cache.key(samples: [0, 1], sourceCompatibleFeatures: true, session: id))
        XCTAssertNotEqual(
            key, cache.key(samples: [0, 1, 0], sourceCompatibleFeatures: false, session: id))
        XCTAssertNotEqual(
            key, cache.key(samples: [-Float.zero, 1], sourceCompatibleFeatures: false, session: id))
    }

    func testLateOldSessionResultsCannotEnterOrClearTheCurrentRecording() throws {
        let cache = EncoderResultCache()
        let old = UUID(), current = UUID()
        cache.begin(old)
        let key = try XCTUnwrap(
            cache.key(samples: [1], sourceCompatibleFeatures: false, session: old))
        cache.begin(current)
        cache.store(hidden: try tensor(), mask: try tensor(1), for: key, session: old)
        XCTAssertNil(cache.value(for: key, session: current))
        cache.store(hidden: try tensor(), mask: try tensor(1), for: key, session: current)
        cache.end(old)
        XCTAssertNotNil(cache.value(for: key, session: current))
    }

    func testFrequentlyReadCompletedWindowsSurviveTailWindowEviction() throws {
        let cache = EncoderResultCache(maximumEntries: 2)
        let id = UUID()
        cache.begin(id)
        let keys = try [Float(1), 2, 3].map {
            try XCTUnwrap(cache.key(samples: [$0], sourceCompatibleFeatures: false, session: id))
        }
        for key in keys.prefix(2) {
            cache.store(hidden: try tensor(), mask: try tensor(1), for: key, session: id)
        }
        XCTAssertNotNil(cache.value(for: keys[0], session: id))
        cache.store(hidden: try tensor(), mask: try tensor(1), for: keys[2], session: id)
        XCTAssertNotNil(cache.value(for: keys[0], session: id))
        XCTAssertNil(cache.value(for: keys[1], session: id))
        XCTAssertNotNil(cache.value(for: keys[2], session: id))
    }

    func testPayloadBudgetRejectsOversizedEntriesAndClearsOnEnd() throws {
        let cache = EncoderResultCache(maximumBytes: 300)
        let id = UUID()
        cache.begin(id)
        let large = try XCTUnwrap(
            cache.key(
                samples: Array(repeating: 0, count: 100), sourceCompatibleFeatures: false,
                session: id))
        cache.store(hidden: try tensor(), mask: try tensor(1), for: large, session: id)
        XCTAssertEqual(cache.byteCount, 0)
        let small = try XCTUnwrap(
            cache.key(samples: [1], sourceCompatibleFeatures: false, session: id))
        cache.store(hidden: try tensor(), mask: try tensor(1), for: small, session: id)
        XCTAssertGreaterThan(cache.byteCount, 0)
        XCTAssertLessThanOrEqual(cache.byteCount, 300)
        cache.begin(UUID())
        XCTAssertEqual(cache.byteCount, 0)
    }

    func testDefaultBudgetRetainsThreeMinuteWorkingSetAcrossRepeatedScans() throws {
        let cache = EncoderResultCache()
        let id = UUID()
        cache.begin(id)
        // Ten complete 20-second windows and a five-second tail, with overlap.
        // Fixed encoder outputs include padding even for the short final window.
        let hidden = try MLMultiArray(shape: [1, 1_024, 250], dataType: .float32)
        let mask = try MLMultiArray(shape: [1, 250], dataType: .float32)
        let keys = try (0..<11).map { index in
            try XCTUnwrap(
                cache.key(
                    samples: Array(repeating: Float(index), count: index == 10 ? 80_000 : 320_000),
                    sourceCompatibleFeatures: false, session: id))
        }
        for key in keys {
            cache.store(hidden: hidden, mask: mask, for: key, session: id)
        }
        for _ in 0..<3 {
            for key in keys {
                XCTAssertNotNil(cache.value(for: key, session: id))
            }
        }
        XCTAssertGreaterThan(cache.byteCount, 32 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(cache.byteCount, 64 * 1_024 * 1_024)
        cache.end(id)
        XCTAssertEqual(cache.byteCount, 0)
    }
}
