import FidelityKit
import Foundation
import QwenPolisher
import SpeakerKit
import TextProcessingKit

private struct SmokeOutput: Encodable {
    let schemaVersion = 1
    let text: String
    let usedModelOutput: Bool
    let rejectionReason: String?
    let modelDurationMilliseconds: Int
    let totalDurationMilliseconds: Int
    let promptTokens: Int
    let outputTokens: Int
}

@main
private enum PolisherSmokeCLI {
    static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.contains("--deterministic-daq") {
            guard let textIndex = arguments.firstIndex(of: "--text"),
                arguments.indices.contains(textIndex + 1)
            else {
                FileHandle.standardError.write(
                    Data("Usage: voxol-polisher-smoke --deterministic-daq --text <evidence>\n".utf8)
                )
                Foundation.exit(64)
            }
            let evidence = try daqEvidence(from: arguments[textIndex + 1])
            let candidateIDs = evidence.keys.sorted()
            let startedAt = ContinuousClock.now
            guard
                let output = MeetingReportExtraction.deterministicDAQOutput(
                    candidateIDs: candidateIDs, evidence: evidence)
            else {
                FileHandle.standardError.write(Data("deterministic_daq=fallback\n".utf8))
                Foundation.exit(2)
            }
            _ = try MeetingReportExtraction.parseDAQ(output, evidence: evidence)
            let elapsed = startedAt.duration(to: .now).timeInterval * 1_000
            FileHandle.standardOutput.write(Data(output.utf8))
            FileHandle.standardOutput.write(Data("\n".utf8))
            FileHandle.standardError.write(
                Data(String(format: "deterministic_daq_ms=%.6f\n", elapsed).utf8)
            )
            return
        }
        guard let modelIndex = arguments.firstIndex(of: "--model"),
            arguments.indices.contains(modelIndex + 1),
            let textIndex = arguments.firstIndex(of: "--text"),
            arguments.indices.contains(textIndex + 1)
        else {
            FileHandle.standardError.write(
                Data("Usage: voxol-polisher-smoke --model <directory> --text <transcript>\n".utf8)
            )
            Foundation.exit(64)
        }

        let modelURL = URL(fileURLWithPath: arguments[modelIndex + 1], isDirectory: true)
        let rawText = arguments[textIndex + 1]
        if arguments.contains("--structured") {
            let system =
                arguments.firstIndex(of: "--system").flatMap { index in
                    arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
                } ?? "Return only valid JSON."
            let maximumOutputTokens =
                arguments.firstIndex(of: "--max-output-tokens").flatMap { index in
                    guard arguments.indices.contains(index + 1) else { return nil }
                    return Int(arguments[index + 1])
                } ?? 700
            let runtime = QwenPolisherRuntime(modelRoot: modelURL, useInstalledAdapter: false)
            if arguments.contains("--prepare-structured-prefix") {
                let modelStartedAt = ContinuousClock.now
                try await runtime.prepare()
                let modelElapsed = modelStartedAt.duration(to: .now).timeInterval * 1_000
                FileHandle.standardError.write(
                    Data(String(format: "structured_model_prepare_ms=%.3f\n", modelElapsed).utf8)
                )
                let startedAt = ContinuousClock.now
                try await runtime.prepareStructuredPrefix(system: system)
                let elapsed = startedAt.duration(to: .now).timeInterval * 1_000
                FileHandle.standardError.write(
                    Data(String(format: "structured_prefix_prepare_ms=%.3f\n", elapsed).utf8)
                )
            }
            if arguments.contains("--structured-lines") {
                let startedAt = ContinuousClock.now
                var outputs = [String]()
                for line in rawText.split(separator: "\n", omittingEmptySubsequences: true) {
                    let result = try await runtime.generateStructured(
                        system: system,
                        user: String(line),
                        maximumOutputTokens: maximumOutputTokens,
                        timeout: .seconds(120)
                    )
                    outputs.append(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let elapsed = startedAt.duration(to: .now).timeInterval * 1_000
                FileHandle.standardError.write(
                    Data(String(format: "structured_lines_ms=%.3f\n", elapsed).utf8)
                )
                FileHandle.standardOutput.write(Data(outputs.joined(separator: "\n").utf8))
                FileHandle.standardOutput.write(Data("\n".utf8))
                await runtime.unload()
                return
            }
            let result = try await runtime.generateStructured(
                system: system, user: rawText,
                maximumOutputTokens: maximumOutputTokens, timeout: .seconds(120))
            if arguments.contains("--validate-compact-meeting") {
                let evidence = try compactMeetingEvidence(from: rawText)
                _ = try MeetingReportExtraction.parseCompact(result.text, evidence: evidence)
            }
            FileHandle.standardOutput.write(Data(result.text.utf8))
            FileHandle.standardOutput.write(Data("\n".utf8))
            await runtime.unload()
            return
        }
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: rawText,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )
        let runtime = QwenPolisherRuntime(modelRoot: modelURL)
        let startedAt = ContinuousClock.now
        let polished = try await runtime.polish(preparation, timeout: .seconds(8))
        let decision = FidelityValidator.validate(
            candidate: polished.text,
            against: preparation
        )
        let output = SmokeOutput(
            text: decision.text,
            usedModelOutput: decision.usedModelOutput,
            rejectionReason: decision.rejectionReason?.rawValue,
            modelDurationMilliseconds: Int(polished.durationSeconds * 1_000),
            totalDurationMilliseconds: Int(startedAt.duration(to: .now).timeInterval * 1_000),
            promptTokens: polished.promptTokenCount,
            outputTokens: polished.outputTokenCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(output))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func daqEvidence(from text: String) throws -> [Int: MeetingReportEvidence] {
        var evidence = [Int: MeetingReportEvidence]()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "<transcript>" || trimmed == "</transcript>" { continue }
            let fields = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0].first == "E",
                let evidenceID = Int(fields[0].dropFirst()), evidence[evidenceID] == nil
            else {
                throw MeetingReportGenerationError.invalidSource
            }
            evidence[evidenceID] = MeetingReportEvidence(
                id: evidenceID, turnID: evidenceID, text: String(fields[1]))
        }
        guard !evidence.isEmpty else { throw MeetingReportGenerationError.invalidSource }
        return evidence
    }

    private static func compactMeetingEvidence(
        from text: String
    ) throws -> [Int: MeetingReportEvidence] {
        var evidence = [Int: MeetingReportEvidence]()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "<transcript>" || trimmed == "</transcript>" { continue }
            let fields = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5,
                fields[0].first == "E", let evidenceID = Int(fields[0].dropFirst()),
                fields[1].first == "T", let turnID = Int(fields[1].dropFirst()),
                evidence[evidenceID] == nil
            else {
                throw MeetingReportGenerationError.invalidSource
            }
            evidence[evidenceID] = MeetingReportEvidence(
                id: evidenceID, turnID: turnID, text: String(fields[4]))
        }
        guard !evidence.isEmpty else { throw MeetingReportGenerationError.invalidSource }
        return evidence
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
