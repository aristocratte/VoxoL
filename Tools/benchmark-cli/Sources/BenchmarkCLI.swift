import Darwin
import Foundation
import ModelManagerKit
import ObservabilityKit

@main
enum BenchmarkCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(Configuration.usage)
            return
        }

        do {
            let configuration = try Configuration.parse(arguments)
            let result = try benchmark(configuration)
            try emit(result, outputPath: configuration.outputPath)
        } catch {
            writeError("voxol-benchmark: \(error)\n")
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

private extension BenchmarkCLI {
    struct Configuration {
        static let usage = """
            Usage: voxol-benchmark [options]

              --manifest <path>    Runtime-model manifest to validate
                                   (default: Models/manifests/runtime-models.json)
              --iterations <count> Positive validation count (default: 100)
              --output <path>      Write JSON atomically instead of printing to stdout
              --help, -h           Show this help
            """

        let manifestPath: String
        let iterations: Int
        let outputPath: String?

        static func parse(_ arguments: [String]) throws -> Configuration {
            var manifestPath = "Models/manifests/runtime-models.json"
            var iterations = 100
            var outputPath: String?
            var index = 0

            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--manifest":
                    manifestPath = try value(after: argument, at: &index, in: arguments)
                case "--iterations":
                    let rawValue = try value(after: argument, at: &index, in: arguments)
                    guard let parsed = Int(rawValue), parsed > 0 else {
                        throw CommandError.invalidIterations(rawValue)
                    }
                    iterations = parsed
                case "--output":
                    outputPath = try value(after: argument, at: &index, in: arguments)
                default:
                    throw CommandError.unknownArgument(argument)
                }
                index += 1
            }

            return Configuration(
                manifestPath: manifestPath,
                iterations: iterations,
                outputPath: outputPath
            )
        }

        static func value(
            after option: String,
            at index: inout Int,
            in arguments: [String]
        ) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw CommandError.missingValue(option)
            }
            return arguments[index]
        }
    }

    enum CommandError: Error, CustomStringConvertible {
        case unknownArgument(String)
        case missingValue(String)
        case invalidIterations(String)

        var description: String {
            switch self {
            case .unknownArgument(let argument):
                "Unknown argument: \(argument)"
            case .missingValue(let option):
                "Missing value after \(option)"
            case .invalidIterations(let value):
                "Iterations must be a positive integer; received \(value)"
            }
        }
    }

    static func benchmark(_ configuration: Configuration) throws -> BenchmarkResult {
        let manifestURL = URL(fileURLWithPath: configuration.manifestPath)
        let manifestData = try Data(contentsOf: manifestURL)
        let clock = ContinuousClock()
        var samples = [Double]()
        samples.reserveCapacity(configuration.iterations)

        for _ in 0..<configuration.iterations {
            let start = clock.now
            _ = try RuntimeModelManifest.decodeAndValidate(manifestData)
            samples.append(milliseconds(start.duration(to: clock.now)))
        }

        let statistics = try LatencyStatistics(samples: samples)
        let environment = ProcessInfo.processInfo.environment
        return BenchmarkResult(
            benchmark: "runtime-manifest-validation",
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            sourceRevision: environment["VOXOL_SOURCE_REVISION"] ?? environment["GITHUB_SHA"],
            environment: currentEnvironment(),
            parameters: [
                "iterations": String(configuration.iterations),
                "manifest": configuration.manifestPath,
            ],
            measurements: [
                BenchmarkMeasurement(
                    name: "decode-and-validate",
                    unit: "milliseconds",
                    statistics: statistics
                )
            ]
        )
    }

    static func currentEnvironment() -> BenchmarkEnvironment {
        let processInfo = ProcessInfo.processInfo
        return BenchmarkEnvironment(
            hardwareModel: systemString("hw.model"),
            operatingSystem: processInfo.operatingSystemVersionString,
            architecture: architecture,
            processorCount: processInfo.processorCount,
            physicalMemoryBytes: processInfo.physicalMemory
        )
    }

    static var architecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    static func systemString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }

        var buffer = [CChar](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            sysctlbyname(name, pointer.baseAddress, &size, nil, 0)
        }
        guard status == 0 else {
            return "unknown"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func emit(_ result: BenchmarkResult, outputPath: String?) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)

        guard let outputPath else {
            print(String(decoding: data, as: UTF8.self))
            return
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
    }

    static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
