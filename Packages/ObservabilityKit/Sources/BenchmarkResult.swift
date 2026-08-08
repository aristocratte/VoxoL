import Foundation

/// Stable, content-free machine metadata attached to a benchmark run.
public struct BenchmarkEnvironment: Codable, Equatable, Sendable {
    /// The non-unique Apple hardware model identifier, such as `Mac16,1`.
    public let hardwareModel: String

    /// The operating-system description reported by Foundation.
    public let operatingSystem: String

    /// The architecture for which the benchmark executable was compiled.
    public let architecture: String

    /// The logical processor count visible to the process.
    public let processorCount: Int

    /// Physical memory visible to the operating system, in bytes.
    public let physicalMemoryBytes: UInt64

    /// Creates content-free benchmark environment metadata.
    public init(
        hardwareModel: String,
        operatingSystem: String,
        architecture: String,
        processorCount: Int,
        physicalMemoryBytes: UInt64
    ) {
        self.hardwareModel = hardwareModel
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.processorCount = processorCount
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

/// Validation failures for a latency sample set.
public enum LatencyStatisticsError: Error, Equatable, Sendable {
    /// No sample was provided.
    case emptySamples

    /// A sample was negative or not finite.
    case invalidSample(Double)
}

/// Deterministic summary statistics for one latency measurement.
public struct LatencyStatistics: Codable, Equatable, Sendable {
    /// The number of measured samples.
    public let sampleCount: Int

    /// The minimum sample value.
    public let minimum: Double

    /// The interpolated 50th percentile.
    public let p50: Double

    /// The interpolated 95th percentile.
    public let p95: Double

    /// The interpolated 99th percentile.
    public let p99: Double

    /// The maximum sample value.
    public let maximum: Double

    /// Validates samples and computes a stable, linearly interpolated distribution.
    public init(samples: [Double]) throws {
        guard !samples.isEmpty else {
            throw LatencyStatisticsError.emptySamples
        }
        if let invalidSample = samples.first(where: { !$0.isFinite || $0 < 0 }) {
            throw LatencyStatisticsError.invalidSample(invalidSample)
        }

        let sortedSamples = samples.sorted()
        sampleCount = sortedSamples.count
        minimum = sortedSamples[0]
        p50 = Self.percentile(0.50, in: sortedSamples)
        p95 = Self.percentile(0.95, in: sortedSamples)
        p99 = Self.percentile(0.99, in: sortedSamples)
        maximum = sortedSamples[sortedSamples.count - 1]
    }
}

private extension LatencyStatistics {
    static func percentile(_ fraction: Double, in sortedSamples: [Double]) -> Double {
        let position = fraction * Double(sortedSamples.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else {
            return sortedSamples[lowerIndex]
        }

        let weight = position - Double(lowerIndex)
        return sortedSamples[lowerIndex] * (1 - weight) + sortedSamples[upperIndex] * weight
    }
}

/// One named benchmark measurement and its unit.
public struct BenchmarkMeasurement: Codable, Equatable, Sendable {
    /// The stable measurement identifier.
    public let name: String

    /// The unit shared by every summarized value.
    public let unit: String

    /// The measured distribution.
    public let statistics: LatencyStatistics

    /// Creates a named benchmark measurement.
    public init(name: String, unit: String, statistics: LatencyStatistics) {
        self.name = name
        self.unit = unit
        self.statistics = statistics
    }
}

/// A versioned, content-free benchmark result that can be committed as JSON.
public struct BenchmarkResult: Codable, Equatable, Sendable {
    /// The result schema understood by this build.
    public let schemaVersion: Int

    /// The stable benchmark identifier.
    public let benchmark: String

    /// The UTC ISO-8601 recording timestamp.
    public let recordedAt: String

    /// The source revision supplied by CI or the developer, when known.
    public let sourceRevision: String?

    /// Content-free machine metadata.
    public let environment: BenchmarkEnvironment

    /// Explicit run parameters that affect the result.
    public let parameters: [String: String]

    /// Measurements emitted by the run.
    public let measurements: [BenchmarkMeasurement]

    /// Creates a versioned benchmark result.
    public init(
        schemaVersion: Int = 1,
        benchmark: String,
        recordedAt: String,
        sourceRevision: String?,
        environment: BenchmarkEnvironment,
        parameters: [String: String],
        measurements: [BenchmarkMeasurement]
    ) {
        self.schemaVersion = schemaVersion
        self.benchmark = benchmark
        self.recordedAt = recordedAt
        self.sourceRevision = sourceRevision
        self.environment = environment
        self.parameters = parameters
        self.measurements = measurements
    }
}
