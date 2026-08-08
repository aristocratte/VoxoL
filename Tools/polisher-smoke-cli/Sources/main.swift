import FidelityKit
import Foundation
import QwenPolisher
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
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
