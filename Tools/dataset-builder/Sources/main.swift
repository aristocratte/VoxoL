import DatasetKit
import Darwin
import FidelityKit
import Foundation

private struct GeneratedPrediction: Decodable {
    let id: String
    let actualText: String

    enum CodingKeys: String, CodingKey {
        case id
        case actualText = "actual_text"
    }
}

private struct RuntimeValidationReport: Encodable {
    let fallbackCount: Int
    let fallbackReasonCounts: [String: Int]
    let fallbackMetrics: CleanupEvaluationResult
    let metrics: CleanupEvaluationResult
    let modelOutputCount: Int
    let routedBypassCount: Int
}

private struct RuntimeValidationDecision: Encodable {
    let id: String
    let rejectionReason: String?
    let usedModelOutput: Bool
}

private struct PreparedSourceRecord: Encodable {
    struct Token: Encodable {
        let placeholder: String
        let value: String
    }

    let id: String
    let normalizedText: String
    let promptText: String
    let protectedTokens: [Token]
    let shouldUsePolisher: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case normalizedText = "normalized_text"
        case promptText = "prompt_text"
        case protectedTokens = "protected_tokens"
        case shouldUsePolisher = "should_use_polisher"
    }
}

@main
enum DatasetBuilderCLI {
    static func main() throws {
        let arguments = ProcessInfo.processInfo.arguments
        if let source = value(after: "--prepare-source", in: arguments),
            let output = value(after: "--output", in: arguments)
        {
            try prepareSource(
                sourceURL: URL(fileURLWithPath: source),
                outputURL: URL(fileURLWithPath: output)
            )
            return
        }
        if let predictions = value(after: "--validate-predictions", in: arguments),
            let source = value(after: "--source", in: arguments),
            let report = value(after: "--report", in: arguments)
        {
            try validateRuntime(
                predictionsURL: URL(fileURLWithPath: predictions),
                sourceURL: URL(fileURLWithPath: source),
                reportURL: URL(fileURLWithPath: report),
                decisionsURL: value(after: "--decisions", in: arguments).map {
                    URL(fileURLWithPath: $0)
                },
                productionRouting: arguments.contains("--production-routing")
            )
            return
        }
        if let evaluation = value(after: "--evaluate", in: arguments),
            let report = value(after: "--report", in: arguments)
        {
            try evaluate(
                predictionsURL: URL(fileURLWithPath: evaluation),
                reportURL: URL(fileURLWithPath: report)
            )
            return
        }
        guard let input = value(after: "--input", in: arguments),
            let output = value(after: "--output", in: arguments)
        else {
            FileHandle.standardError.write(
                Data(
                    "Usage: voxol-dataset-builder --input source.jsonl --output directory\n"
                        .utf8
                )
            )
            Darwin.exit(2)
        }

        let examples = try readExamples(from: URL(fileURLWithPath: input))
        let result = DatasetBuilder.build(examples)
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        try write(result.train, to: outputURL.appendingPathComponent("train.jsonl"))
        try write(result.validation, to: outputURL.appendingPathComponent("valid.jsonl"))
        try write(result.test, to: outputURL.appendingPathComponent("test.jsonl"))

        let summary: [String: Any] = [
            "train": result.train.count,
            "validation": result.validation.count,
            "test": result.test.count,
            "rejected_ids": result.rejectedIDs,
        ]
        let summaryData = try JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys]
        )
        try summaryData.write(
            to: outputURL.appendingPathComponent("summary.json"), options: .atomic)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func readExamples(from url: URL) throws -> [CleanupDatasetExample] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map { try JSONDecoder().decode(CleanupDatasetExample.self, from: Data($0.utf8)) }
    }

    private static func prepareSource(sourceURL: URL, outputURL: URL) throws {
        let records = try readExamples(from: sourceURL)
            .sorted { $0.id < $1.id }
            .map { example in
                let preparation = DatasetBuilder.prepare(example)
                return PreparedSourceRecord(
                    id: example.id,
                    normalizedText: preparation.normalizedText,
                    promptText: preparation.promptText,
                    protectedTokens: preparation.protectedTokens.map {
                        PreparedSourceRecord.Token(
                            placeholder: $0.placeholder,
                            value: $0.value
                        )
                    },
                    shouldUsePolisher: preparation.shouldUsePolisher
                )
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try records.map {
            String(decoding: try encoder.encode($0), as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
            .write(to: outputURL, options: .atomic)
    }

    private static func evaluate(predictionsURL: URL, reportURL: URL) throws {
        let examples = try String(contentsOf: predictionsURL, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map {
                try JSONDecoder().decode(CleanupEvaluationExample.self, from: Data($0.utf8))
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(CleanupEvaluator.evaluate(examples))
            .write(to: reportURL, options: .atomic)
    }

    private static func validateRuntime(
        predictionsURL: URL,
        sourceURL: URL,
        reportURL: URL,
        decisionsURL: URL?,
        productionRouting: Bool
    ) throws {
        let examples = Dictionary(
            uniqueKeysWithValues: try readExamples(from: sourceURL).map { ($0.id, $0) }
        )
        let predictions = try String(contentsOf: predictionsURL, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map { try JSONDecoder().decode(GeneratedPrediction.self, from: Data($0.utf8)) }

        var evaluated = [CleanupEvaluationExample]()
        var fallbackEvaluated = [CleanupEvaluationExample]()
        var decisions = [RuntimeValidationDecision]()
        var fallbackReasons = [String: Int]()
        var modelOutputCount = 0
        var routedBypassCount = 0
        for prediction in predictions {
            guard let example = examples[prediction.id] else {
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Prediction \(prediction.id) has no matching source example"
                    ]
                )
            }
            let preparation = DatasetBuilder.prepare(
                example,
                fastPathEnabled: productionRouting
            )
            let decision: FidelityDecision
            if productionRouting, !preparation.shouldUsePolisher {
                routedBypassCount += 1
                decision = FidelityValidator.fallback(for: preparation)
            } else {
                decision = FidelityValidator.validate(
                    candidate: prediction.actualText,
                    against: preparation
                )
            }
            if decision.usedModelOutput {
                modelOutputCount += 1
            } else if let reason = decision.rejectionReason {
                fallbackReasons[reason.rawValue, default: 0] += 1
            }
            decisions.append(
                RuntimeValidationDecision(
                    id: prediction.id,
                    rejectionReason: decision.rejectionReason?.rawValue,
                    usedModelOutput: decision.usedModelOutput
                )
            )
            evaluated.append(
                CleanupEvaluationExample(
                    id: prediction.id,
                    expectedText: example.targetText,
                    actualText: decision.text,
                    protectedTokens: preparation.protectedTokens.map(\.value)
                )
            )
            fallbackEvaluated.append(
                CleanupEvaluationExample(
                    id: prediction.id,
                    expectedText: example.targetText,
                    actualText: preparation.normalizedText,
                    protectedTokens: preparation.protectedTokens.map(\.value)
                )
            )
        }

        let report = RuntimeValidationReport(
            fallbackCount: predictions.count - modelOutputCount,
            fallbackReasonCounts: fallbackReasons,
            fallbackMetrics: CleanupEvaluator.evaluate(fallbackEvaluated),
            metrics: CleanupEvaluator.evaluate(evaluated),
            modelOutputCount: modelOutputCount,
            routedBypassCount: routedBypassCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        if let decisionsURL {
            encoder.outputFormatting = [.sortedKeys]
            let lines = try decisions.map {
                String(decoding: try encoder.encode($0), as: UTF8.self)
            }
            try Data((lines.joined(separator: "\n") + "\n").utf8)
                .write(to: decisionsURL, options: .atomic)
        }
    }

    private static func write(_ records: [TrainingRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        let lines = try records.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
            .write(to: url, options: .atomic)
    }
}
