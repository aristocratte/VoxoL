import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// A transcript-only draft source. Matching never makes a token authoritative:
/// the target model must verify every draft token before it can be emitted.
struct PromptLookupIndex: Sendable {
    private let tokens: [Int]
    private let positions: [[Int]: [Int]]

    init(tokens: [Int]) {
        self.tokens = tokens
        var positions = [[Int]: [Int]]()
        for end in tokens.indices where end + 1 < tokens.count {
            for length in 1...min(3, end + 1) {
                let key = Array(tokens[(end + 1 - length)...end])
                positions[key, default: []].append(end + 1)
            }
        }
        self.positions = positions
    }

    func draft(after generated: [Int], maximumCount: Int) -> [Int] {
        guard maximumCount > 0, !generated.isEmpty else { return [] }
        for length in stride(from: min(3, generated.count), through: 1, by: -1) {
            let key = Array(generated.suffix(length))
            if let start = positions[key]?.last {
                return Array(tokens[start..<min(tokens.count, start + maximumCount)])
            }
        }
        return []
    }

    static func acceptedCount(
        draft: [Int], predictions: [Int], stopTokenIDs: Set<Int>
    ) -> Int {
        var count = 0
        for (proposed, predicted) in zip(draft, predictions) {
            guard proposed == predicted, !stopTokenIDs.contains(predicted) else { break }
            count += 1
        }
        return count
    }
}

/// Experimental greedy verification for Qwen3.5's hybrid attention/SSM cache.
///
/// Unlike ordinary speculative decoding, a rejected suffix cannot be removed
/// by trimming KV tensors: Mamba's convolution and recurrent state have also
/// advanced. Restore a complete checkpoint and replay only the accepted input.
/// Batched and single-token kernels may differ numerically, so actual output
/// parity must be measured; this path is not enabled by default.
enum QwenPromptLookupDecoder {
    static func supports(_ model: any LanguageModel) -> Bool {
        model is Qwen35Model || model is Qwen35TextModel
    }

    static func generate(
        input: LMInput,
        cache initialCache: [KVCache]?,
        context: ModelContext,
        parameters: GenerateParameters,
        transcript: String,
        maximumDraftTokens: Int,
        fullPromptTokenCount: Int,
        reusedPromptTokenCount: Int,
        startedAt: ContinuousClock.Instant
    ) throws -> QwenPolisherResult {
        // A synchronous body keeps the container's serial-access permit for
        // the entire request. Never leave unevaluated GPU work behind on error.
        defer { Stream().synchronize() }
        try Task.checkCancellation()
        let prefillStartedAt = ContinuousClock.now
        let maximumTokens = parameters.maxTokens ?? 384
        var cache = initialCache ?? context.model.newCache(parameters: parameters)
        let lookup = PromptLookupIndex(tokens: context.tokenizer.encode(text: transcript))
        var stopTokenIDs = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { stopTokenIDs.insert(eos) }
        if let unknown = context.tokenizer.unknownTokenId { stopTokenIDs.insert(unknown) }
        for text in context.configuration.extraEOSTokens {
            if let token = context.tokenizer.convertTokenToId(text) {
                stopTokenIDs.insert(token)
            }
        }

        let first: LMOutput
        switch try context.model.prepare(
            input, cache: cache, windowSize: parameters.prefillStepSize)
        {
        case .tokens(let remainder):
            first = context.model(remainder[text: .newAxis], cache: cache, state: nil)
        case .logits(let output):
            first = output
        }
        var next = argMax(first.logits[0, -1, 0...]).item(Int.self)
        eval(cache)
        let generationStartedAt = ContinuousClock.now
        var tokens = [Int]()
        tokens.reserveCapacity(maximumTokens)
        var proposedTokenCount = 0
        var acceptedTokenCount = 0
        var verificationCount = 0
        var replayedTokenCount = 0

        while !stopTokenIDs.contains(next) {
            try Task.checkCancellation()
            guard tokens.count < maximumTokens else {
                throw QwenPolisherError.tokenLimitReached
            }
            tokens.append(next)
            // Match the production token ceiling: an EOS beyond the ceiling
            // must not turn a truncated response into a successful response.
            guard tokens.count < maximumTokens else {
                throw QwenPolisherError.tokenLimitReached
            }
            let draft = lookup.draft(
                after: tokens,
                maximumCount: min(maximumDraftTokens, maximumTokens - tokens.count - 1)
            )
            let pending = [next] + draft
            let checkpoint = draft.isEmpty ? [] : cache.map { $0.copy() }
            let result = context.model(
                LMInput(tokens: MLXArray(pending)).text[text: .newAxis],
                cache: cache,
                state: nil
            )
            let predictions = argMax(result.logits[0, 0..., 0...], axis: -1).asArray(Int.self)
            eval(cache)
            try Task.checkCancellation()
            let accepted = PromptLookupIndex.acceptedCount(
                draft: draft, predictions: predictions, stopTokenIDs: stopTokenIDs
            )
            proposedTokenCount += draft.count
            acceptedTokenCount += accepted
            if !draft.isEmpty { verificationCount += 1 }
            tokens.append(contentsOf: draft.prefix(accepted))
            next = predictions[accepted]

            if accepted < draft.count {
                // Restore both KV attention state AND recurrent/conv state.
                cache = checkpoint
                let replay = Array(pending.prefix(accepted + 1))
                let replayResult = context.model(
                    LMInput(tokens: MLXArray(replay)).text[text: .newAxis],
                    cache: cache,
                    state: nil
                )
                next = argMax(replayResult.logits[0, -1, 0...]).item(Int.self)
                eval(cache)
                replayedTokenCount += replay.count
            }
        }

        try Task.checkCancellation()
        let text = context.tokenizer.decode(tokens: tokens)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw QwenPolisherError.emptyOutput }
        Stream().synchronize()
        let endedAt = ContinuousClock.now
        return QwenPolisherResult(
            text: text,
            durationSeconds: seconds(startedAt.duration(to: endedAt)),
            promptTokenCount: fullPromptTokenCount,
            outputTokenCount: tokens.count,
            promptDurationSeconds: seconds(prefillStartedAt.duration(to: generationStartedAt)),
            generationDurationSeconds: seconds(generationStartedAt.duration(to: endedAt)),
            reusedPromptTokenCount: reusedPromptTokenCount,
            proposedDraftTokenCount: proposedTokenCount,
            acceptedDraftTokenCount: acceptedTokenCount,
            draftVerificationCount: verificationCount,
            replayedTokenCount: replayedTokenCount
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
