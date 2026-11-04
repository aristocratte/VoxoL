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
        if let transcriptIndex = arguments.firstIndex(of: "--meeting-report-plan-file")
            ?? arguments.firstIndex(of: "--validate-meeting-narrative-file")
        {
            guard arguments.indices.contains(transcriptIndex + 1) else {
                throw MeetingReportGenerationError.invalidSource
            }
            let document = try JSONDecoder().decode(
                SpeakerTranscript.self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[transcriptIndex + 1])))
            let evidence = MeetingReportNarrative.boundedEvidence(from: document)
            let prompt = MeetingReportNarrative.prompt(
                evidence: evidence, transcript: document, french: !arguments.contains("--english"))
            let fragments = document.turns.flatMap { turn in
                MeetingReportEvidenceBuilder.fragments(in: turn.text).map { (turn.id, $0) }
            }
            let daqEvidence = Dictionary(
                uniqueKeysWithValues: fragments.enumerated().map { id, source in
                    (id, MeetingReportEvidence(id: id, turnID: source.0, text: source.1))
                })
            let candidates = daqEvidence.values.filter {
                MeetingReportExtraction.isLikelyDAQCandidate($0.text)
            }.map(\.id).sorted()
            guard
                let partition = MeetingReportExtraction.deterministicDAQPartition(
                    candidateIDs: candidates, evidence: daqEvidence)
            else { throw MeetingReportGenerationError.invalidSource }
            var output: [String: Any] = [
                "schemaVersion": 1,
                "sourceEvidenceCount": fragments.count,
                "candidateCount": candidates.count,
                "unresolvedCount": partition.unresolvedIDs.count,
                "resolvedDAQOutput": partition.resolvedOutput,
                "selectedEvidenceCount": evidence.count,
                "promptCharacters": prompt.count,
                "prompt": prompt,
            ]
            if arguments.contains("--validate-meeting-narrative-file") {
                guard partition.unresolvedIDs.isEmpty,
                    let textIndex = arguments.firstIndex(of: "--text"),
                    arguments.indices.contains(textIndex + 1)
                else { throw MeetingReportGenerationError.invalidSource }
                let extraction = try MeetingReportExtraction.parseDAQ(
                    partition.resolvedOutput, evidence: daqEvidence)
                let confirmedQuotes = extraction.confirmedDecisionQuotes
                let allowedDecisionIDs = Set(
                    evidence.compactMap {
                        confirmedQuotes.contains($0.value.text) ? $0.key : nil
                    })
                let narrative = try MeetingReportNarrative.parse(
                    arguments[textIndex + 1], evidence: evidence, transcript: document,
                    allowedDecisionEvidenceIDs: allowedDecisionIDs)
                output["narrativeValid"] = true
                output["paragraphCount"] = narrative.paragraphs.count
                output["paragraphCharacters"] = narrative.paragraphs.reduce(0) {
                    $0 + $1.text.count
                }
                output.removeValue(forKey: "prompt")
            }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }
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
            let configuration: QwenPolisherGenerationConfiguration =
                arguments.contains("--meeting-report-configuration") ? .meetingReport : .init()
            let prefillStepSize =
                arguments.firstIndex(of: "--prefill-step-size").flatMap { index in
                    guard arguments.indices.contains(index + 1) else { return nil }
                    return Int(arguments[index + 1])
                } ?? configuration.prefillStepSize
            let maximumKVCacheSize: Int? =
                arguments.firstIndex(of: "--max-kv-cache-size").flatMap { index in
                    guard arguments.indices.contains(index + 1) else { return nil }
                    return Int(arguments[index + 1])
                }
            let system =
                arguments.firstIndex(of: "--system").flatMap { index in
                    arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
                } ?? "Return only valid JSON."
            let maximumOutputTokens =
                arguments.firstIndex(of: "--max-output-tokens").flatMap { index in
                    guard arguments.indices.contains(index + 1) else { return nil }
                    return Int(arguments[index + 1])
                } ?? 700
            let runtime = QwenPolisherRuntime(
                modelRoot: modelURL,
                useInstalledAdapter: false,
                generationConfiguration: QwenPolisherGenerationConfiguration(
                    maximumKVCacheSize: maximumKVCacheSize,
                    prefillStepSize: prefillStepSize
                )
            )
            if let batchIndex = arguments.firstIndex(of: "--structured-batch-file"),
                arguments.indices.contains(batchIndex + 1)
            {
                let batchURL = URL(fileURLWithPath: arguments[batchIndex + 1])
                let prompts = try JSONDecoder().decode(
                    [String].self, from: Data(contentsOf: batchURL))
                guard !prompts.isEmpty else {
                    throw MeetingReportGenerationError.invalidSource
                }
                let batchStartedAt = ContinuousClock.now
                try await runtime.prepare()
                try await runtime.prepareStructuredPrefix(system: system)
                for (index, prompt) in prompts.enumerated() {
                    let result = try await runtime.generateStructured(
                        system: system,
                        user: prompt,
                        maximumOutputTokens: maximumOutputTokens,
                        timeout: .seconds(180)
                    )
                    FileHandle.standardError.write(
                        Data(
                            String(
                                format:
                                    "structured_batch_item=%d duration_ms=%.3f prompt_tokens=%d output_tokens=%d\n",
                                index,
                                result.durationSeconds * 1_000,
                                result.promptTokenCount,
                                result.outputTokenCount
                            ).utf8
                        )
                    )
                    FileHandle.standardOutput.write(Data(result.text.utf8))
                    FileHandle.standardOutput.write(Data("\n---\n".utf8))
                }
                let batchElapsed = batchStartedAt.duration(to: .now).timeInterval * 1_000
                FileHandle.standardError.write(
                    Data(String(format: "structured_batch_ms=%.3f\n", batchElapsed).utf8)
                )
                await runtime.unload()
                return
            }
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
            FileHandle.standardError.write(
                Data(
                    String(
                        format:
                            "structured_generation_ms=%.3f prompt_tokens=%d output_tokens=%d\n",
                        result.durationSeconds * 1_000,
                        result.promptTokenCount,
                        result.outputTokenCount
                    ).utf8
                )
            )
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
