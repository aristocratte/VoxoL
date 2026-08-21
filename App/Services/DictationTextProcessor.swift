import FidelityKit
import Foundation
import QwenPolisher
import TextProcessingKit

enum TextProcessingRoute: String, Equatable, Sendable {
    case raw
    case snippet
    case fastPath
    case qwen
    case deterministicFallback
}

enum TextProcessingFailure: String, Equatable, Sendable {
    case modelUnavailable
    case modelWarmingUp
    case generationTimedOut
    case generationFailed
}

struct DictationTextProcessingResult: Equatable, Sendable {
    let text: String
    let route: TextProcessingRoute
    let polishingDurationSeconds: TimeInterval
    let rejectionReason: FidelityRejectionReason?
    let failure: TextProcessingFailure?
}

/// Serializes the one local Qwen runtime and always returns a safe deterministic result.
actor DictationTextProcessor {
    private let runtime: QwenPolisherRuntime?

    init(modelRoot: URL?) {
        runtime = modelRoot.map { QwenPolisherRuntime(modelRoot: $0) }
    }

    var isPolisherReady: Bool {
        get async {
            guard let runtime else {
                return false
            }
            return await runtime.isReady
        }
    }

    func warmUp() async throws {
        try await runtime?.warmUp()
    }

    func process(
        _ preparation: DeterministicPreparation,
        timeout: Duration? = nil
    ) async -> DictationTextProcessingResult {
        guard preparation.shouldUsePolisher else {
            return DictationTextProcessingResult(
                text: preparation.normalizedText,
                route: deterministicRoute(for: preparation),
                polishingDurationSeconds: 0,
                rejectionReason: nil,
                failure: nil
            )
        }
        guard let runtime else {
            return fallback(preparation, failure: .modelUnavailable)
        }
        guard await runtime.isReady else {
            return fallback(preparation, failure: .modelWarmingUp)
        }

        let startedAt = ContinuousClock.now
        do {
            let generated = try await runtime.polish(
                preparation,
                timeout: timeout ?? generationTimeout(for: preparation)
            )
            let decision = FidelityValidator.validateWithRepair(
                candidate: generated.text,
                against: preparation
            )
            return DictationTextProcessingResult(
                text: decision.text,
                route: decision.usedModelOutput ? .qwen : .deterministicFallback,
                polishingDurationSeconds: startedAt.duration(to: .now).timeInterval,
                rejectionReason: decision.rejectionReason,
                failure: nil
            )
        } catch is CancellationError {
            return fallback(
                preparation,
                duration: startedAt.duration(to: .now).timeInterval,
                failure: .generationFailed
            )
        } catch QwenPolisherError.timedOut {
            return fallback(
                preparation,
                duration: startedAt.duration(to: .now).timeInterval,
                failure: .generationTimedOut
            )
        } catch {
            return fallback(
                preparation,
                duration: startedAt.duration(to: .now).timeInterval,
                failure: .generationFailed
            )
        }
    }
}

private extension DictationTextProcessor {
    func generationTimeout(for preparation: DeterministicPreparation) -> Duration {
        let wordCount = preparation.promptText.split { !$0.isLetter && !$0.isNumber }.count
        if wordCount <= 12 {
            return .milliseconds(2_500)
        }
        if wordCount <= 40 {
            return .milliseconds(4_500)
        }
        return .seconds(6)
    }

    func deterministicRoute(for preparation: DeterministicPreparation) -> TextProcessingRoute {
        if preparation.profile == .raw {
            return .raw
        }
        if preparation.usedSnippet {
            return .snippet
        }
        return .fastPath
    }

    func fallback(
        _ preparation: DeterministicPreparation,
        duration: TimeInterval = 0,
        failure: TextProcessingFailure
    ) -> DictationTextProcessingResult {
        DictationTextProcessingResult(
            text: preparation.normalizedText,
            route: .deterministicFallback,
            polishingDurationSeconds: duration,
            rejectionReason: nil,
            failure: failure
        )
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
