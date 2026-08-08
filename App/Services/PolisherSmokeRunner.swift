import Darwin
import FidelityKit
import Foundation
import PersonalizationKit
import QwenPolisher
import TextProcessingKit

enum PolisherSmokeRunner {
    static let argument = "--polisher-smoke"

    static func runAndExit(arguments: [String]) async -> Never {
        let exitCode = await run(arguments: arguments)
        fflush(stdout)
        fflush(stderr)
        Darwin.exit(exitCode)
    }
}

private extension PolisherSmokeRunner {
    static func run(arguments: [String]) async -> Int32 {
        guard let modelPath = value(after: "--model", in: arguments) else {
            write("Missing --model path\n", to: .standardError)
            return 2
        }
        if let suitePath = value(after: "--suite", in: arguments) {
            do {
                return try await runSuite(
                    modelRoot: URL(fileURLWithPath: modelPath, isDirectory: true),
                    adapterRoot: value(after: "--adapter", in: arguments).map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    },
                    suiteURL: URL(fileURLWithPath: suitePath),
                    generationConfiguration: generationConfiguration(arguments: arguments)
                )
            } catch {
                write("Polisher suite failed: \(String(describing: error))\n", to: .standardError)
                return 1
            }
        }
        let transcript =
            value(after: "--text", in: arguments)
            ?? "euh envoie le rapport demain matin à VoxoL"
        let modelRoot = URL(fileURLWithPath: modelPath, isDirectory: true)
        do {
            if arguments.contains("--include-candidate") {
                return try await runCandidateSmoke(
                    modelRoot: modelRoot,
                    adapterRoot: value(after: "--adapter", in: arguments).map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    },
                    transcript: transcript,
                    generationConfiguration: generationConfiguration(arguments: arguments)
                )
            }
            let processor = DictationTextProcessor(modelRoot: modelRoot)
            try await processor.warmUp()
            let preparation = DeterministicTextProcessor.prepare(
                TextProcessingRequest(
                    rawTranscript: transcript,
                    preferences: TextProcessingPreferences(fastPathEnabled: false),
                    personalization: PersonalizationSnapshot()
                )
            )
            let result = await processor.process(preparation)
            let payload: [String: Any] = [
                "route": result.route.rawValue,
                "text": result.text,
                "duration_ms": Int(result.polishingDurationSeconds * 1_000),
                "failure": result.failure.map(\.rawValue) as Any? ?? NSNull(),
                "rejection": result.rejectionReason.map(\.rawValue) as Any? ?? NSNull(),
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return result.route == .qwen ? 0 : 1
        } catch {
            write("Polisher smoke failed: \(String(describing: error))\n", to: .standardError)
            return 1
        }
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }

    static func generationConfiguration(
        arguments: [String]
    ) -> QwenPolisherGenerationConfiguration {
        let maximumKVCacheSize: Int?
        if let value = value(after: "--max-kv-size", in: arguments) {
            maximumKVCacheSize = value == "none" ? nil : Int(value)
        } else {
            maximumKVCacheSize = nil
        }
        let prefillStepSize =
            value(after: "--prefill-step-size", in: arguments).flatMap(Int.init) ?? 512
        return QwenPolisherGenerationConfiguration(
            maximumKVCacheSize: maximumKVCacheSize,
            prefillStepSize: prefillStepSize,
            usesPromptPrefixCache: !arguments.contains("--no-prompt-prefix-cache"),
            fusesAdapter: !arguments.contains("--no-fuse-adapter")
        )
    }

    static func write(_ value: String, to handle: FileHandle) {
        handle.write(Data(value.utf8))
    }

    static func runCandidateSmoke(
        modelRoot: URL,
        adapterRoot: URL?,
        transcript: String,
        generationConfiguration: QwenPolisherGenerationConfiguration
    ) async throws -> Int32 {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: transcript,
                preferences: TextProcessingPreferences(fastPathEnabled: false),
                personalization: PersonalizationSnapshot()
            )
        )
        let runtime = QwenPolisherRuntime(
            modelRoot: modelRoot,
            adapterRoot: adapterRoot,
            generationConfiguration: generationConfiguration
        )
        try await runtime.warmUp()
        let generated = try await runtime.polish(preparation, timeout: .seconds(8))
        let decision = FidelityValidator.validate(candidate: generated.text, against: preparation)
        let payload: [String: Any] = [
            "candidate": generated.text,
            "accepted": decision.usedModelOutput,
            "rejection": decision.rejectionReason.map(\.rawValue) as Any? ?? NSNull(),
            "duration_ms": Int(generated.durationSeconds * 1_000),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return decision.usedModelOutput ? 0 : 1
    }

    static func runSuite(
        modelRoot: URL,
        adapterRoot: URL?,
        suiteURL: URL,
        generationConfiguration: QwenPolisherGenerationConfiguration
    ) async throws -> Int32 {
        let suite = try JSONDecoder().decode(
            PolisherEvaluationSuite.self,
            from: Data(contentsOf: suiteURL)
        )
        let runtime = QwenPolisherRuntime(
            modelRoot: modelRoot,
            adapterRoot: adapterRoot,
            generationConfiguration: generationConfiguration
        )
        let warmupStarted = ContinuousClock.now
        try await runtime.warmUp()
        let warmupDurationMilliseconds = warmupStarted.duration(to: .now).milliseconds
        var results = [PolisherEvaluationResult]()
        results.reserveCapacity(suite.cases.count)

        for (index, testCase) in suite.cases.enumerated() {
            let preparation = DeterministicTextProcessor.prepare(
                TextProcessingRequest(
                    rawTranscript: testCase.transcript,
                    preferredLanguage: testCase.language.textLanguage,
                    preferences: TextProcessingPreferences(
                        fastPathEnabled: false,
                        profile: testCase.profile ?? .automatic
                    ),
                    personalization: PersonalizationSnapshot()
                )
            )
            let generationStarted = ContinuousClock.now
            do {
                let timeout = testCase.timeoutMilliseconds.map(Duration.milliseconds) ?? .seconds(8)
                let generated = try await runtime.polish(preparation, timeout: timeout)
                let decision = FidelityValidator.validate(
                    candidate: generated.text,
                    against: preparation
                )
                results.append(
                    PolisherEvaluationResult(
                        id: testCase.id,
                        expected: testCase.expected,
                        candidate: generated.text,
                        normalized: preparation.normalizedText,
                        finalText: decision.text,
                        accepted: decision.usedModelOutput,
                        exactMatch: decision.usedModelOutput && decision.text == testCase.expected,
                        pipelineExactMatch: decision.text == testCase.expected,
                        rejection: decision.rejectionReason?.rawValue,
                        failure: nil,
                        durationMilliseconds: Int(generated.durationSeconds * 1_000),
                        promptDurationMilliseconds: Int(
                            generated.promptDurationSeconds * 1_000
                        ),
                        generationDurationMilliseconds: Int(
                            generated.generationDurationSeconds * 1_000
                        ),
                        reusedPromptTokens: generated.reusedPromptTokenCount,
                        promptTokens: generated.promptTokenCount,
                        outputTokens: generated.outputTokenCount,
                        processingLanguage: preparation.language.rawValue,
                        profile: preparation.profile.rawValue,
                        protectedTokenCount: preparation.protectedTokens.count
                    )
                )
            } catch {
                results.append(
                    PolisherEvaluationResult(
                        id: testCase.id,
                        expected: testCase.expected,
                        candidate: "",
                        normalized: preparation.normalizedText,
                        finalText: preparation.normalizedText,
                        accepted: false,
                        exactMatch: false,
                        pipelineExactMatch: preparation.normalizedText == testCase.expected,
                        rejection: "runtimeError.\(type(of: error))",
                        failure: String(describing: type(of: error)),
                        durationMilliseconds: generationStarted.duration(to: .now).milliseconds,
                        promptDurationMilliseconds: 0,
                        generationDurationMilliseconds: 0,
                        reusedPromptTokens: 0,
                        promptTokens: 0,
                        outputTokens: 0,
                        processingLanguage: preparation.language.rawValue,
                        profile: preparation.profile.rawValue,
                        protectedTokenCount: preparation.protectedTokens.count
                    )
                )
            }
            let latest = results[results.count - 1]
            write(
                "polisher_suite processed=\(index + 1)/\(suite.cases.count) "
                    + "accepted=\(latest.accepted) duration_ms=\(latest.durationMilliseconds)\n",
                to: .standardError
            )
        }

        let durations = results.map(\.durationMilliseconds).filter { $0 > 0 }.sorted()
        let payload = PolisherEvaluationOutput(
            schemaVersion: 1,
            promptVersion: PolishingPrompt.version,
            modelPath: modelRoot.lastPathComponent,
            caseCount: results.count,
            acceptedCount: results.count(where: \.accepted),
            exactMatchCount: results.count(where: \.exactMatch),
            pipelineExactMatchCount: results.count(where: \.pipelineExactMatch),
            warmupDurationMilliseconds: warmupDurationMilliseconds,
            meanDurationMilliseconds: durations.isEmpty
                ? 0 : durations.reduce(0, +) / durations.count,
            p50DurationMilliseconds: percentile(0.50, values: durations),
            p95DurationMilliseconds: percentile(0.95, values: durations),
            maximumKVCacheSize: generationConfiguration.maximumKVCacheSize,
            prefillStepSize: generationConfiguration.prefillStepSize,
            usesPromptPrefixCache: generationConfiguration.usesPromptPrefixCache,
            results: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(payload))
        FileHandle.standardOutput.write(Data("\n".utf8))
        return results.count == suite.cases.count ? 0 : 1
    }

    static func percentile(_ percentile: Double, values: [Int]) -> Int {
        guard !values.isEmpty else {
            return 0
        }
        let index = Int((Double(values.count - 1) * percentile).rounded())
        return values[index]
    }
}

private struct PolisherEvaluationSuite: Decodable {
    let cases: [PolisherEvaluationCase]
}

private struct PolisherEvaluationCase: Decodable {
    enum Language: String, Decodable {
        case french = "fr"
        case english = "en"
        case spanish = "es"

        var textLanguage: TextLanguage? {
            switch self {
            case .french:
                .french
            case .english:
                .english
            case .spanish:
                nil
            }
        }
    }

    let id: String
    let language: Language
    let transcript: String
    let expected: String
    let profile: WritingProfile?
    let timeoutMilliseconds: Int?
}

private struct PolisherEvaluationResult: Encodable {
    let id: String
    let expected: String
    let candidate: String
    let normalized: String
    let finalText: String
    let accepted: Bool
    let exactMatch: Bool
    let pipelineExactMatch: Bool
    let rejection: String?
    let failure: String?
    let durationMilliseconds: Int
    let promptDurationMilliseconds: Int
    let generationDurationMilliseconds: Int
    let reusedPromptTokens: Int
    let promptTokens: Int
    let outputTokens: Int
    let processingLanguage: String
    let profile: String
    let protectedTokenCount: Int
}

private struct PolisherEvaluationOutput: Encodable {
    let schemaVersion: Int
    let promptVersion: String
    let modelPath: String
    let caseCount: Int
    let acceptedCount: Int
    let exactMatchCount: Int
    let pipelineExactMatchCount: Int
    let warmupDurationMilliseconds: Int
    let meanDurationMilliseconds: Int
    let p50DurationMilliseconds: Int
    let p95DurationMilliseconds: Int
    let maximumKVCacheSize: Int?
    let prefillStepSize: Int
    let usesPromptPrefixCache: Bool
    let results: [PolisherEvaluationResult]
}

private extension Duration {
    var milliseconds: Int {
        let components = components
        let value =
            Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return Int(value)
    }
}
