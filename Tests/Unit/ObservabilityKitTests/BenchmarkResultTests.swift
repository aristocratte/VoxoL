import Foundation
import ObservabilityKit
import XCTest

final class BenchmarkResultTests: XCTestCase {
    func testCommittedBaselineDecodes() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot =
            sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let baselineURL = repositoryRoot.appendingPathComponent(
            "Tests/Performance/Baselines/manifest-validation-m4-phase-0.json"
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let result = try decoder.decode(
            BenchmarkResult.self,
            from: Data(contentsOf: baselineURL)
        )

        XCTAssertEqual(result.schemaVersion, 1)
        XCTAssertEqual(result.benchmark, "runtime-manifest-validation")
        XCTAssertEqual(result.environment.hardwareModel, "Mac16,1")
    }

    func testLatencyStatisticsUseLinearInterpolation() throws {
        let statistics = try LatencyStatistics(samples: [5, 1, 4, 2, 3])

        XCTAssertEqual(statistics.sampleCount, 5)
        XCTAssertEqual(statistics.minimum, 1)
        XCTAssertEqual(statistics.p50, 3)
        XCTAssertEqual(statistics.p95, 4.8, accuracy: 0.000_001)
        XCTAssertEqual(statistics.p99, 4.96, accuracy: 0.000_001)
        XCTAssertEqual(statistics.maximum, 5)
    }

    func testLatencyStatisticsRejectInvalidSamples() {
        XCTAssertThrowsError(try LatencyStatistics(samples: [])) { error in
            XCTAssertEqual(error as? LatencyStatisticsError, .emptySamples)
        }
        XCTAssertThrowsError(try LatencyStatistics(samples: [-1])) { error in
            XCTAssertEqual(error as? LatencyStatisticsError, .invalidSample(-1))
        }
    }

    func testBenchmarkResultRoundTripsThroughJSON() throws {
        let result = BenchmarkResult(
            benchmark: "runtime-manifest-validation",
            recordedAt: "2026-07-20T00:00:00Z",
            sourceRevision: "abc123",
            environment: BenchmarkEnvironment(
                hardwareModel: "Mac16,1",
                operatingSystem: "macOS",
                architecture: "arm64",
                processorCount: 10,
                physicalMemoryBytes: 16_000_000_000
            ),
            parameters: ["iterations": "5"],
            measurements: [
                BenchmarkMeasurement(
                    name: "decode-and-validate",
                    unit: "milliseconds",
                    statistics: try LatencyStatistics(samples: [0.1, 0.2, 0.3])
                )
            ]
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(
            try decoder.decode(BenchmarkResult.self, from: encoder.encode(result)), result)
    }
}
