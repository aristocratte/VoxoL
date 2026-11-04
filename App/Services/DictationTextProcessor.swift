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

enum PolisherOutcome: String, Equatable, Sendable {
    case notRequested
    case copiedInput
    case modelNotReady
    case timedOut
    case generationError
    case validatorRejected
    case partialRecovery
    case modelOutputUsed
}

struct DictationTextProcessingResult: Equatable, Sendable {
    let text: String
    let route: TextProcessingRoute
    let polishingDurationSeconds: TimeInterval
    let rejectionReason: FidelityRejectionReason?
    let failure: TextProcessingFailure?
    let polisherOutcome: PolisherOutcome
    let modelCandidate: String?
    let repairedSentenceCount: Int
    let v3ShadowDecision: FidelityV3Decision?
    var generatedOutputTokenCount = 0
    var reusedOutputTokenCount = 0
    var generatedCallCount = 0
    var reusedCallCount = 0
}

struct DictationPrefetchMetrics: Equatable, Sendable {
    var durationSeconds: TimeInterval = 0
    var generatedCallCount = 0
    var reusedCallCount = 0
    var generatedOutputTokenCount = 0
    var failedCallCount = 0
}

/// Serializes the one local Qwen runtime and always returns a safe deterministic result.
actor DictationTextProcessor {
    private let runtime: QwenPolisherRuntime?
    private var isWarmForPrefetch = false

    init(
        modelRoot: URL?,
        adapterRoot: URL? = nil,
        useInstalledAdapter: Bool = true,
        generationConfiguration: QwenPolisherGenerationConfiguration = .init()
    ) {
        runtime = modelRoot.map {
            QwenPolisherRuntime(
                modelRoot: $0, adapterRoot: adapterRoot,
                useInstalledAdapter: useInstalledAdapter,
                generationConfiguration: generationConfiguration
            )
        }
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
        isWarmForPrefetch = runtime != nil
    }

    func beginPrefetchSession(_ id: UUID) async {
        await runtime?.beginDictationSession(id)
    }

    func endPrefetchSession(_ id: UUID) async {
        await runtime?.endDictationSession(id)
    }

    /// Work on complete earlier runs while the user is still speaking. Keep the
    /// final, potentially changing run unprocessed. The final path repeats all
    /// preparation and validation, reusing only an exactly matching model prompt.
    func prefetch(
        _ request: TextProcessingRequest,
        sessionID: UUID,
        budget: Duration = .milliseconds(2_500)
    ) async -> DictationPrefetchMetrics {
        let start = ContinuousClock.now
        var metrics = DictationPrefetchMetrics()
        guard isWarmForPrefetch, let runtime, await runtime.isReady,
            await runtime.isDictationSessionActive(sessionID),
            wordCount(of: request.rawTranscript) > Self.runThresholdWords
        else { return metrics }
        let runs = TranscriptChunker.requests(for: request, maximumWords: Self.runWords)
        // The final run may still grow. Its two predecessors need that same
        // complete lookahead at finalization before their prompts are reusable.
        for item in runs.dropLast(TranscriptChunker.contextLookaheadCount + 1) {
            guard !Task.isCancelled, start.duration(to: .now) < budget,
                await runtime.isDictationSessionActive(sessionID)
            else { break }
            let prepared = DeterministicTextProcessor.prepare(item)
            guard prepared.shouldUsePolisher else {
                continue
            }
            let result = await polish(
                prepared, runtime: runtime,
                timeout: max(
                    .milliseconds(1),
                    min(
                        generationTimeout(for: prepared), budget - start.duration(to: .now)
                    )),
                sessionID: sessionID
            )
            guard !Task.isCancelled else { break }
            // A deterministic generation failure in an earlier run must not
            // starve every later run on every preview. Neighboring context is
            // always the source, independent of a run's outcome. A timeout
            // still ends this preview because it has spent the available budget.
            if result.failure != nil { metrics.failedCallCount += 1 }
            metrics.generatedCallCount += result.generatedCallCount
            metrics.reusedCallCount += result.reusedCallCount
            metrics.generatedOutputTokenCount += result.generatedOutputTokenCount
            if result.failure == .generationTimedOut { break }
        }
        metrics.durationSeconds = start.duration(to: .now).timeInterval
        return metrics
    }

    /// `request` is what `preparation` was prepared from; with it, a long transcript can be
    /// prepared again one run of sentences at a time under the same preferences.
    func process(
        _ preparation: DeterministicPreparation,
        request: TextProcessingRequest? = nil,
        timeout: Duration? = nil,
        sessionID: UUID? = nil
    ) async -> DictationTextProcessingResult {
        guard preparation.shouldUsePolisher else {
            return DictationTextProcessingResult(
                text: preparation.normalizedText,
                route: deterministicRoute(for: preparation),
                polishingDurationSeconds: 0,
                rejectionReason: nil,
                failure: nil,
                polisherOutcome: .notRequested,
                modelCandidate: nil,
                repairedSentenceCount: 0,
                v3ShadowDecision: nil
            )
        }
        guard let runtime else {
            return fallback(preparation, failure: .modelUnavailable)
        }
        guard await runtime.isReady else {
            return fallback(preparation, failure: .modelWarmingUp)
        }
        if timeout == nil, let request,
            wordCount(of: preparation.promptText) > Self.runThresholdWords
        {
            return await processInRuns(
                preparation, request: request, runtime: runtime, sessionID: sessionID)
        }
        return await polish(
            preparation,
            runtime: runtime,
            timeout: timeout ?? generationTimeout(for: preparation),
            sessionID: sessionID
        )
    }
}

private extension DictationTextProcessor {
    /// Past this many words one call no longer fits its budget: on the human corpus every
    /// dictation above about a hundred and twenty words timed out, after the longest wait.
    static let runThresholdWords = 70
    /// The size of one run of sentences — the length an ordinary dictation already has.
    static let runWords = 45
    /// The whole-transcript ceiling; runs that would start past it stay deterministic rather
    /// than keep the user waiting.
    static let runsBudget: Duration = .seconds(14)

    /// Polishes a long transcript one run of whole sentences at a time. Each run is prepared
    /// again with its own placeholders, validation and source context on both sides,
    /// so a run that fails costs only its sentences.
    func processInRuns(
        _ preparation: DeterministicPreparation,
        request: TextProcessingRequest,
        runtime: QwenPolisherRuntime,
        sessionID: UUID?
    ) async -> DictationTextProcessingResult {
        let runs = TranscriptChunker.requests(for: request, maximumWords: Self.runWords)
        guard runs.count > 1 else {
            return await polish(
                preparation, runtime: runtime, timeout: generationTimeout(for: preparation),
                sessionID: sessionID)
        }

        let startedAt = ContinuousClock.now
        var pieces = [String]()
        var usedModelOutput = false
        var rejection: FidelityRejectionReason?
        var failure: TextProcessingFailure?
        var outcomes = [PolisherOutcome]()
        var candidates = [String]()
        var repairedSentenceCount = 0
        var shadowDecisions = [FidelityV3Decision]()
        var generatedOutputTokenCount = 0
        var reusedOutputTokenCount = 0
        var generatedCallCount = 0
        var reusedCallCount = 0
        for runRequest in runs {
            let runPreparation = DeterministicTextProcessor.prepare(runRequest)

            guard runPreparation.shouldUsePolisher else {
                pieces.append(runPreparation.normalizedText)
                outcomes.append(.notRequested)
                continue
            }

            let elapsed = startedAt.duration(to: .now)
            guard elapsed < Self.runsBudget else {
                failure = failure ?? .generationTimedOut
                pieces.append(runPreparation.normalizedText)
                outcomes.append(.timedOut)
                continue
            }
            let result = await polish(
                runPreparation,
                runtime: runtime,
                timeout: min(generationTimeout(for: runPreparation), Self.runsBudget - elapsed),
                sessionID: sessionID
            )
            pieces.append(result.text)
            usedModelOutput = usedModelOutput || result.route == .qwen
            rejection = rejection ?? result.rejectionReason
            failure = failure ?? result.failure
            outcomes.append(result.polisherOutcome)
            candidates.append(result.modelCandidate ?? runPreparation.normalizedText)
            repairedSentenceCount += result.repairedSentenceCount
            generatedOutputTokenCount += result.generatedOutputTokenCount
            reusedOutputTokenCount += result.reusedOutputTokenCount
            generatedCallCount += result.generatedCallCount
            reusedCallCount += result.reusedCallCount
            if let shadow = result.v3ShadowDecision { shadowDecisions.append(shadow) }
        }
        return DictationTextProcessingResult(
            text: pieces.joined(separator: " "),
            route: usedModelOutput ? .qwen : .deterministicFallback,
            polishingDurationSeconds: startedAt.duration(to: .now).timeInterval,
            rejectionReason: rejection,
            failure: failure,
            polisherOutcome: aggregate(outcomes),
            modelCandidate: candidates.isEmpty ? nil : candidates.joined(separator: " "),
            repairedSentenceCount: repairedSentenceCount,
            v3ShadowDecision: aggregate(shadowDecisions),
            generatedOutputTokenCount: generatedOutputTokenCount,
            reusedOutputTokenCount: reusedOutputTokenCount,
            generatedCallCount: generatedCallCount,
            reusedCallCount: reusedCallCount
        )
    }

    func wordCount(of text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    /// One bounded call, validated.
    func polish(
        _ preparation: DeterministicPreparation,
        runtime: QwenPolisherRuntime,
        timeout: Duration,
        sessionID: UUID? = nil
    ) async -> DictationTextProcessingResult {
        let startedAt = ContinuousClock.now
        do {
            let generated = try await runtime.polish(
                preparation, timeout: timeout, sessionID: sessionID)
            let decision = FidelityValidator.validateWithRepair(
                candidate: generated.text,
                against: preparation
            )
            let shadow =
                preparation.featureFlags.textQualityV3Shadow
                    || preparation.featureFlags.editGateV3
                ? FidelityValidatorV3.validateWithRepair(
                    candidate: generated.text,
                    against: preparation
                ) : nil
            let restoredCandidate = preparation.restorePlaceholders(in: generated.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let outcome: PolisherOutcome
            if decision.repairedSentenceCount > 0 {
                outcome = .partialRecovery
            } else if !decision.usedModelOutput {
                outcome = .validatorRejected
            } else if restoredCandidate == preparation.normalizedText {
                outcome = .copiedInput
            } else {
                outcome = .modelOutputUsed
            }
            return DictationTextProcessingResult(
                text: decision.text,
                route: decision.usedModelOutput ? .qwen : .deterministicFallback,
                polishingDurationSeconds: startedAt.duration(to: .now).timeInterval,
                rejectionReason: decision.rejectionReason,
                failure: nil,
                polisherOutcome: outcome,
                modelCandidate: restoredCandidate,
                repairedSentenceCount: decision.repairedSentenceCount,
                v3ShadowDecision: shadow,
                generatedOutputTokenCount: generated.reusedOutputTokenCount > 0
                    ? 0 : generated.outputTokenCount,
                reusedOutputTokenCount: generated.reusedOutputTokenCount,
                generatedCallCount: generated.reusedOutputTokenCount > 0 ? 0 : 1,
                reusedCallCount: generated.reusedOutputTokenCount > 0 ? 1 : 0
            )
        } catch is CancellationError {
            return fallback(
                preparation,
                duration: startedAt.duration(to: .now).timeInterval,
                failure: .generationFailed,
                outcome: .generationError
            )
        } catch QwenPolisherError.timedOut {
            return fallback(
                preparation,
                duration: startedAt.duration(to: .now).timeInterval,
                failure: .generationTimedOut,
                outcome: .timedOut
            )
        } catch {
            return fallback(
                preparation,
                duration: startedAt.duration(to: .now).timeInterval,
                failure: .generationFailed,
                outcome: .generationError
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
        failure: TextProcessingFailure,
        outcome: PolisherOutcome = .modelNotReady
    ) -> DictationTextProcessingResult {
        DictationTextProcessingResult(
            text: preparation.normalizedText,
            route: .deterministicFallback,
            polishingDurationSeconds: duration,
            rejectionReason: nil,
            failure: failure,
            polisherOutcome: outcome,
            modelCandidate: nil,
            repairedSentenceCount: 0,
            v3ShadowDecision: nil
        )
    }

    func aggregate(_ outcomes: [PolisherOutcome]) -> PolisherOutcome {
        let priority: [PolisherOutcome] = [
            .partialRecovery, .modelOutputUsed, .validatorRejected, .timedOut,
            .generationError, .modelNotReady, .copiedInput, .notRequested,
        ]
        return priority.first(where: outcomes.contains) ?? .notRequested
    }

    func aggregate(_ decisions: [FidelityV3Decision]) -> FidelityV3Decision? {
        guard !decisions.isEmpty else { return nil }
        let status: FidelityV3Status
        if decisions.contains(where: { $0.status == .rejected }) {
            status = .rejected
        } else if decisions.contains(where: { $0.status == .repaired }) {
            status = .repaired
        } else {
            status = .accepted
        }
        return FidelityV3Decision(
            text: decisions.map(\.text).joined(separator: " "),
            status: status,
            rejectionReason: decisions.compactMap(\.rejectionReason).first,
            acceptedEditCount: decisions.reduce(0) { $0 + $1.acceptedEditCount },
            rejectedEditCount: decisions.reduce(0) { $0 + $1.rejectedEditCount },
            repairedClauseCount: decisions.reduce(0) { $0 + $1.repairedClauseCount }
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
