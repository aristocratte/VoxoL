import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import TextProcessingKit

/// Bounded generation failures exposed by the local Qwen runtime.
public enum QwenPolisherError: Error, Equatable, LocalizedError, Sendable {
    case adapterLoadFailed(String)
    case timedOut
    case emptyOutput
    case tokenLimitReached

    /// User-facing description of the local generation failure.
    public var errorDescription: String? {
        switch self {
        case .adapterLoadFailed(let detail):
            "The local cleanup adapter could not be loaded: \(detail)"
        case .timedOut:
            "Local cleanup exceeded its time budget."
        case .emptyOutput:
            "The local cleanup model returned no text."
        case .tokenLimitReached:
            "The local cleanup model reached its output limit."
        }
    }
}

/// Generated text and content-free inference measurements.
public struct QwenPolisherResult: Equatable, Sendable {
    /// Raw generated cleanup text.
    public let text: String
    /// Wall-clock generation duration.
    public let durationSeconds: TimeInterval
    /// Number of input prompt tokens.
    public let promptTokenCount: Int
    /// Number of emitted tokens.
    public let outputTokenCount: Int
    /// Time spent evaluating the prompt, as reported by MLX.
    public let promptDurationSeconds: TimeInterval
    /// Time spent generating output tokens, as reported by MLX.
    public let generationDurationSeconds: TimeInterval
    /// Invariant prompt tokens served from the per-language cache.
    public let reusedPromptTokenCount: Int
    /// Draft tokens proposed by transcript lookup; zero on the standard path.
    public let proposedDraftTokenCount: Int
    /// Draft tokens accepted by target-model verification.
    public let acceptedDraftTokenCount: Int
    /// Number of speculative verification batches.
    public let draftVerificationCount: Int
    /// Accepted input tokens replayed after restoring a hybrid cache checkpoint.
    public let replayedTokenCount: Int
    /// Output tokens already generated during this same dictation and reused exactly.
    public let reusedOutputTokenCount: Int

    /// Creates a measured generation result.
    public init(
        text: String,
        durationSeconds: TimeInterval,
        promptTokenCount: Int,
        outputTokenCount: Int,
        promptDurationSeconds: TimeInterval,
        generationDurationSeconds: TimeInterval,
        reusedPromptTokenCount: Int,
        proposedDraftTokenCount: Int = 0,
        acceptedDraftTokenCount: Int = 0,
        draftVerificationCount: Int = 0,
        replayedTokenCount: Int = 0,
        reusedOutputTokenCount: Int = 0
    ) {
        self.text = text
        self.durationSeconds = durationSeconds
        self.promptTokenCount = promptTokenCount
        self.outputTokenCount = outputTokenCount
        self.promptDurationSeconds = promptDurationSeconds
        self.generationDurationSeconds = generationDurationSeconds
        self.reusedPromptTokenCount = reusedPromptTokenCount
        self.proposedDraftTokenCount = proposedDraftTokenCount
        self.acceptedDraftTokenCount = acceptedDraftTokenCount
        self.draftVerificationCount = draftVerificationCount
        self.replayedTokenCount = replayedTokenCount
        self.reusedOutputTokenCount = reusedOutputTokenCount
    }
}

/// Low-level MLX generation knobs kept explicit for repeatable performance testing.
public struct QwenPolisherGenerationConfiguration: Equatable, Sendable {
    /// Meeting-report prefill trades a small throughput cost for lower transient MLX memory.
    /// Retained after the September 25 report A/B/B/A. It keeps the streamed path, the only
    /// one that stops after the first JSON object a report asks for.
    public static let meetingReport = Self(prefillStepSize: 128)

    /// A cleaned dictation mostly repeats its transcript, so dictation verifies drafts copied
    /// from it. November 4 A/B/B/A on 106 real dictations: median polish 1.7 s → 0.52 s; 5
    /// finals moved by one token each, none toward more edits; 48/48 synthetic finals identical.
    public static let dictation = Self(promptLookupTokenCount: 16)

    /// Explicit text-quality experiment; production remains the default.
    public let promptStyle: PolishingPromptStyle
    /// Process-wide MLX reusable-buffer pool ceiling, not an active-model memory cap.
    /// Nil leaves MLX's device-derived default unchanged.
    public let maximumBufferCacheBytes: Int?
    /// Rotating cache capacity, or `nil` for the lower-overhead short-prompt cache.
    public let maximumKVCacheSize: Int?
    /// Number of prompt tokens evaluated in one prefill step.
    public let prefillStepSize: Int
    /// Whether invariant chat-template and system tokens are prefilled once per language.
    public let usesPromptPrefixCache: Bool
    /// Whether an installed LoRA adapter is fused into the quantized base model.
    public let fusesAdapter: Bool
    /// Experimental transcript-lookup decoding: nil keeps the production path,
    /// zero measures direct greedy decoding, and 1...16 verifies draft batches.
    public let promptLookupTokenCount: Int?

    /// Creates a bounded generation configuration.
    public init(
        maximumKVCacheSize: Int? = nil,
        prefillStepSize: Int = 512,
        usesPromptPrefixCache: Bool = true,
        fusesAdapter: Bool = true,
        promptLookupTokenCount: Int? = nil,
        maximumBufferCacheBytes: Int? = 64 * 1_024 * 1_024,
        promptStyle: PolishingPromptStyle = .production
    ) {
        self.maximumKVCacheSize = maximumKVCacheSize
        self.prefillStepSize = max(1, prefillStepSize)
        self.usesPromptPrefixCache = usesPromptPrefixCache
        self.fusesAdapter = fusesAdapter
        self.promptLookupTokenCount = promptLookupTokenCount.map { min(16, max(0, $0)) }
        self.maximumBufferCacheBytes = maximumBufferCacheBytes.map { max(0, $0) }
        self.promptStyle = promptStyle
    }
}

/// MLX allocation statistics, excluding Core ML and the rest of the application.
public struct QwenPolisherMemorySnapshot: Codable, Sendable {
    /// Bytes currently owned by live MLX arrays, including weights and model state.
    public let activeBytes: Int
    /// Recyclable intermediate-buffer bytes retained by the MLX allocator.
    public let reusableCacheBytes: Int
    /// Peak live-array allocation recorded by MLX in this process.
    public let peakActiveBytes: Int
    /// Process-wide reusable-buffer ceiling; not a ceiling on active model memory.
    public let cacheLimitBytes: Int
}

/// Owns the one text-only Qwen container and serializes bounded local generations.
public actor QwenPolisherRuntime {
    private static let tracesInference =
        ProcessInfo.processInfo.environment["VOXOL_QWEN_INFERENCE_TRACE"] == "1"
    private let modelRoot: URL
    private let adapterRoot: URL?
    private let generationConfiguration: QwenPolisherGenerationConfiguration
    private var container: ModelContainer?
    private var preparationTask: Task<ModelContainer, Error>?
    private var promptPrefixCaches = [String: PromptPrefixCache]()
    private var sessionCache = SessionPolishingCache()

    /// Creates a runtime for one verified local model directory.
    public init(
        modelRoot: URL,
        adapterRoot: URL? = nil,
        useInstalledAdapter: Bool = true,
        generationConfiguration: QwenPolisherGenerationConfiguration = .init()
    ) {
        self.modelRoot = modelRoot
        self.adapterRoot =
            adapterRoot
            ?? (useInstalledAdapter ? Self.installedAdapterRoot(in: modelRoot) : nil)
        self.generationConfiguration = generationConfiguration
    }

    /// Whether the model container is loaded.
    public var isReady: Bool {
        container != nil
    }

    /// Enables exact result reuse for this dictation, clearing any previous session.
    public func beginDictationSession(_ id: UUID) {
        sessionCache.begin(id)
    }

    /// Removes all text cached for this session. A stale completion cannot clear a new session.
    public func endDictationSession(_ id: UUID) {
        sessionCache.end(id)
    }

    /// Whether a speculative request still belongs to the active dictation.
    public func isDictationSessionActive(_ id: UUID) -> Bool {
        sessionCache.sessionID == id
    }

    /// Content-free diagnostics for local memory/latency A/B tests.
    public func memorySnapshot() -> QwenPolisherMemorySnapshot {
        let snapshot = Memory.snapshot()
        return QwenPolisherMemorySnapshot(
            activeBytes: snapshot.activeMemory,
            reusableCacheBytes: snapshot.cacheMemory,
            peakActiveBytes: snapshot.peakMemory,
            cacheLimitBytes: Memory.cacheLimit
        )
    }

    /// Loads the model container once and shares concurrent preparation calls.
    public func prepare() async throws {
        if container != nil {
            return
        }
        if let preparationTask {
            container = try await preparationTask.value
            self.preparationTask = nil
            return
        }

        let modelRoot = modelRoot
        let adapterRoot = adapterRoot
        let fusesAdapter = generationConfiguration.fusesAdapter
        let maximumBufferCacheBytes = generationConfiguration.maximumBufferCacheBytes
        let task = Task.detached(priority: .utility) {
            if let maximumBufferCacheBytes {
                // VoxoL has one MLX model. Bound only recyclable intermediates;
                // never evict active weights, recurrent state or prompt caches.
                Memory.cacheLimit = maximumBufferCacheBytes
            }
            let configuration = ModelConfiguration(
                directory: modelRoot,
                extraEOSTokens: ["<|im_end|>"]
            )
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            )
            if let adapterRoot {
                let adapter = try LoRAContainer.from(directory: adapterRoot)
                let state = AdapterApplicationState()
                await container.update { context in
                    do {
                        try Self.apply(
                            adapter,
                            to: context.model,
                            fuse: fusesAdapter
                        )
                    } catch {
                        state.error = error
                    }
                }
                if let error = state.error {
                    throw error
                }
            }
            return container
        }
        preparationTask = task
        do {
            container = try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }

    /// Generates one bounded cleanup result. Exact reuse requires the caller's
    /// explicit active dictation ID; a nil or stale ID never reads another session.
    public func polish(
        _ preparation: DeterministicPreparation,
        timeout: Duration = .seconds(2),
        sessionID: UUID? = nil
    ) async throws -> QwenPolisherResult {
        let requestedAt = ContinuousClock.now
        try Task.checkCancellation()
        try await prepare()
        try Task.checkCancellation()
        guard let container else {
            throw CancellationError()
        }
        let prompt = PolishingPromptBuilder.build(
            from: preparation, style: generationConfiguration.promptStyle)
        let requestKey = PolishingRequestKey(prompt)
        if let failure = sessionCache.terminalFailure(for: requestKey, session: sessionID) {
            try Task.checkCancellation()
            throw failure
        }
        if let cached = sessionCache.result(for: requestKey, session: sessionID) {
            try Task.checkCancellation()
            return QwenPolisherResult(
                text: cached.text,
                durationSeconds: requestedAt.duration(to: .now).timeInterval,
                promptTokenCount: cached.promptTokenCount,
                outputTokenCount: cached.outputTokenCount,
                promptDurationSeconds: 0,
                generationDurationSeconds: 0,
                reusedPromptTokenCount: 0,
                reusedOutputTokenCount: cached.outputTokenCount
            )
        }
        let generationConfiguration = generationConfiguration
        // The prefix cache is built inside the budget: a cold system prefix is a full prefill,
        // and a prefill that ran outside the timeout could take the whole wait and then some
        // before generation even started to count.
        let result: QwenPolisherResult
        do {
            result = try await Self.withTimeout(timeout) { [self] in
                let promptPrefixCache = try await self.promptPrefixCache(
                    for: prompt.system,
                    container: container
                )
                return try await Self.generate(
                    prompt: prompt,
                    transcript: preparation.promptText,
                    container: container,
                    configuration: generationConfiguration,
                    promptPrefixCache: promptPrefixCache
                )
            }
        } catch let error as QwenPolisherError {
            try Task.checkCancellation()
            sessionCache.storeTerminalFailure(error, for: requestKey, session: sessionID)
            throw error
        }
        try Task.checkCancellation()
        sessionCache.store(result, for: requestKey, session: sessionID)
        return result
    }

    /// Generates a bounded structured document with the same local MLX runtime.
    /// Meeting reports use their own prompt and validator, not the dictation cleanup contract.
    public func generateStructured(
        system: String,
        user: String,
        maximumOutputTokens: Int = 1_200,
        timeout: Duration = .seconds(180)
    ) async throws -> QwenPolisherResult {
        try Task.checkCancellation()
        try await prepare()
        try Task.checkCancellation()
        guard let container else { throw CancellationError() }
        let prompt = PolishingPrompt(
            system: system,
            user: user,
            maximumOutputTokens: min(2_048, max(4, maximumOutputTokens))
        )
        let configuration = generationConfiguration
        return try await Self.withTimeout(timeout) { [self] in
            let promptPrefixCache = try await self.promptPrefixCache(
                for: prompt.system,
                container: container
            )
            return try await Self.generate(
                prompt: prompt,
                transcript: "",
                container: container,
                configuration: configuration,
                promptPrefixCache: promptPrefixCache,
                stopAfterFirstJSONObject: true
            )
        }
    }

    /// Loads the model and materializes the reusable system-prefix cache for a
    /// later structured generation without producing any model output.
    public func prepareStructuredPrefix(system: String) async throws {
        try Task.checkCancellation()
        try await prepare()
        try Task.checkCancellation()
        guard let container else { throw CancellationError() }
        _ = try await promptPrefixCache(for: system, container: container)
        try Task.checkCancellation()
    }

    /// Runs a one-token generation to populate runtime caches.
    public func warmUp() async throws {
        try await prepare()
        guard let container else {
            return
        }
        if generationConfiguration.usesPromptPrefixCache {
            // Both contracts, both languages: the rewrite instruction is its own prefix, and
            // warming only the faithful one left the first rewrite dictation of every launch
            // paying a full prefill that the user experienced as the polisher being slow.
            for language in [TextLanguage.french, .english] {
                for mode in [CleanupMode.faithful, .rewrite] {
                    _ = try await promptPrefixCache(
                        for: PolishingPromptBuilder.systemInstruction(for: language, mode: mode),
                        container: container
                    )
                }
            }
        }
        let input = UserInput(
            chat: [
                .system("Return only OK."),
                .user("OK"),
            ],
            additionalContext: ["enable_thinking": false]
        )
        let prepared = try await container.prepare(input: input)
        let stream = try await container.generate(
            input: prepared,
            parameters: GenerateParameters(maxTokens: 1, temperature: 0)
        )
        for await _ in stream {}
    }

    /// Releases model state and cancels preparation.
    public func unload() {
        preparationTask?.cancel()
        preparationTask = nil
        promptPrefixCaches.removeAll()
        sessionCache.removeAll()
        container = nil
    }

    static func outputLimitReached(outputTokenCount: Int, maximumOutputTokens: Int) -> Bool {
        outputTokenCount >= maximumOutputTokens
    }

    static func installedAdapterRoot(in modelRoot: URL) -> URL? {
        let candidate = modelRoot.deletingLastPathComponent()
            .appendingPathComponent("voxol-adapter", isDirectory: true)
        let requiredFiles = ["adapter_config.json", "adapters.safetensors"]
        guard
            requiredFiles.allSatisfy({
                FileManager.default.fileExists(
                    atPath: candidate.appendingPathComponent($0).path
                )
            })
        else {
            return nil
        }
        return candidate
    }

    static func apply(
        _ adapter: LoRAContainer,
        to model: LanguageModel,
        fuse: Bool
    ) throws {
        guard let loraModel = model as? LoRAModel else {
            throw ModelAdapterError.incompatibleModelType
        }

        let configuration = adapter.configuration
        let parameters = configuration.loraParameters
        let targetKeys = Set(parameters.keys ?? loraModel.loraDefaultKeys)
        let layers = loraModel.loraLayers.suffix(configuration.numLayers)
        var replacementCount = 0
        for layer in layers {
            let replacements: [(String, Module)] = layer.namedModules().compactMap {
                key, module in
                guard targetKeys.contains(key), let linear = module as? Linear else {
                    return nil
                }
                replacementCount += 1
                return (
                    key,
                    LoRALinear.from(
                        linear: linear,
                        rank: parameters.rank,
                        scale: parameters.scale
                    ) as Module
                )
            }
            layer.update(modules: ModuleChildren.unflattened(replacements))
        }
        guard replacementCount > 0 else {
            throw QwenPolisherError.adapterLoadFailed("no compatible target layers")
        }
        rebuildModuleCaches(in: model)
        try model.update(parameters: adapter.parameters, verify: .noUnusedKeys)
        guard fuse else {
            return
        }
        for layer in layers {
            let replacements: [(String, Module)] = layer.namedModules().compactMap {
                key, module in
                guard targetKeys.contains(key), let lora = module as? LoRALayer else {
                    return nil
                }
                return (key, lora.fused())
            }
            layer.update(modules: ModuleChildren.unflattened(replacements))
        }
        rebuildModuleCaches(in: model)
    }

    static func rebuildModuleCaches(in model: Module) {
        for (_, module) in model.namedModules().reversed() {
            module.update(modules: ModuleChildren())
        }
    }
}

private extension QwenPolisherRuntime {
    func promptPrefixCache(
        for system: String,
        container: ModelContainer
    ) async throws -> PromptPrefixCache? {
        guard generationConfiguration.usesPromptPrefixCache else {
            return nil
        }
        if let cached = promptPrefixCaches[system] {
            return cached
        }
        let cache = try await Self.buildPromptPrefixCache(
            system: system,
            container: container,
            configuration: generationConfiguration
        )
        if let cache {
            promptPrefixCaches[system] = cache
        }
        return cache
    }

    static func buildPromptPrefixCache(
        system: String,
        container: ModelContainer,
        configuration: QwenPolisherGenerationConfiguration
    ) async throws -> PromptPrefixCache? {
        func preparedTokens(for marker: String) async throws -> LMInput {
            try await container.prepare(
                input: UserInput(
                    chat: [
                        .system(system),
                        .user(marker),
                    ],
                    additionalContext: ["enable_thinking": false]
                )
            )
        }

        let first = try await preparedTokens(for: "aardvark_prefix_boundary")
        let second = try await preparedTokens(for: "zebra_cache_boundary")
        let firstTokenIDs = first.text.tokens.asArray(Int.self)
        let secondTokenIDs = second.text.tokens.asArray(Int.self)
        let prefixCount = zip(firstTokenIDs, secondTokenIDs)
            .prefix { pair in pair.0 == pair.1 }
            .count
        guard prefixCount > 0 else {
            return nil
        }

        let prefixInput = LMInput(tokens: first.text.tokens[..<prefixCount])
        let parameters = GenerateParameters(
            maxKVSize: configuration.maximumKVCacheSize,
            temperature: 0,
            prefillStepSize: configuration.prefillStepSize
        )
        return await container.perform(nonSendable: prefixInput) { context, input in
            let cache = context.model.newCache(parameters: parameters)
            _ = context.model(input.text[text: .newAxis], cache: cache, state: nil)
            eval(cache)
            return PromptPrefixCache(
                tokenIDs: Array(firstTokenIDs.prefix(prefixCount)),
                cache: cache
            )
        }
    }

    static func generate(
        prompt: PolishingPrompt,
        transcript: String,
        container: ModelContainer,
        configuration: QwenPolisherGenerationConfiguration,
        promptPrefixCache: PromptPrefixCache?,
        stopAfterFirstJSONObject: Bool = false
    ) async throws -> QwenPolisherResult {
        let startedAt = ContinuousClock.now
        let userInput = UserInput(
            chat: [
                .system(prompt.system),
                .user(prompt.user),
            ],
            additionalContext: ["enable_thinking": false]
        )
        let prepared = try await container.prepare(input: userInput)
        let preparedAt = ContinuousClock.now
        let fullPromptTokenCount = prepared.text.tokens.size
        let parameters = GenerateParameters(
            maxTokens: prompt.maximumOutputTokens,
            maxKVSize: configuration.maximumKVCacheSize,
            temperature: 0,
            topP: 1,
            topK: 0,
            minP: 0,
            prefillStepSize: configuration.prefillStepSize
        )
        if let draftTokenCount = configuration.promptLookupTokenCount,
            let result = try await promptLookupGeneration(
                prepared: LMInput(tokens: prepared.text.tokens),
                promptPrefixCache: promptPrefixCache,
                parameters: parameters,
                container: container,
                transcript: transcript,
                maximumDraftTokens: draftTokenCount,
                startedAt: startedAt
            )
        {
            return result
        }
        let generation = try await generationStream(
            prepared: prepared,
            promptPrefixCache: promptPrefixCache,
            parameters: parameters,
            container: container
        )
        let streamCreatedAt = ContinuousClock.now
        let stream = generation.stream
        var outputChunks = [String]()
        var promptTokenCount = 0
        var outputTokenCount = 0
        var promptDurationSeconds: TimeInterval = 0
        var generationDurationSeconds: TimeInterval = 0
        var reachedLimit = false
        var completedJSONObject: String?
        do {
            for await event in stream {
                try Task.checkCancellation()
                switch event {
                case .chunk(let chunk):
                    if completedJSONObject == nil {
                        outputChunks.append(chunk)
                        if stopAfterFirstJSONObject,
                            let complete = Self.firstCompleteJSONObject(
                                in: outputChunks.joined())
                        {
                            completedJSONObject = complete
                            generation.task.cancel()
                        }
                    }
                case .info(let info):
                    promptTokenCount = fullPromptTokenCount
                    outputTokenCount = info.generationTokenCount
                    promptDurationSeconds = info.promptTime
                    generationDurationSeconds = info.generateTime
                    // MLX 2.31.3 can report .cancelled at maxTokens because
                    // its for-in loop advances a copy of TokenIterator. Do
                    // not accept a truncated response as a complete answer.
                    reachedLimit = Self.outputLimitReached(
                        outputTokenCount: info.generationTokenCount,
                        maximumOutputTokens: prompt.maximumOutputTokens
                    )
                    if case .length = info.stopReason {
                        reachedLimit = true
                    }
                    if completedJSONObject != nil {
                        reachedLimit = false
                    } else if case .cancelled = info.stopReason, !reachedLimit {
                        throw CancellationError()
                    }
                case .toolCall:
                    continue
                }
            }
            // AsyncStream termination is not proof that its MLX producer has
            // finished. Join it before returning or admitting another request.
            await generation.task.value
            try Task.checkCancellation()
        } catch {
            generation.task.cancel()
            await generation.task.value
            throw error
        }

        if reachedLimit {
            throw QwenPolisherError.tokenLimitReached
        }
        let text = (completedJSONObject ?? outputChunks.joined())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw QwenPolisherError.emptyOutput
        }
        if tracesInference {
            let memory = Memory.snapshot()
            let metrics: [String: Any] = [
                "event": "qwen_generation",
                "prepareMilliseconds": startedAt.duration(to: preparedAt).timeInterval * 1_000,
                "streamSetupMilliseconds":
                    preparedAt.duration(to: streamCreatedAt).timeInterval * 1_000,
                "wallMilliseconds": startedAt.duration(to: .now).timeInterval * 1_000,
                "promptTokens": fullPromptTokenCount,
                "reusedPromptTokens": generation.reusedPromptTokenCount,
                "outputTokens": outputTokenCount,
                "promptMilliseconds": promptDurationSeconds * 1_000,
                "generationMilliseconds": generationDurationSeconds * 1_000,
                "mlxActiveBytes": memory.activeMemory,
                "mlxCacheBytes": memory.cacheMemory,
                "mlxPeakBytes": memory.peakMemory,
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: metrics, options: [.sortedKeys])
            {
                FileHandle.standardError.write(data)
                FileHandle.standardError.write(Data([10]))
            }
        }
        return QwenPolisherResult(
            text: text,
            durationSeconds: startedAt.duration(to: .now).timeInterval,
            promptTokenCount: promptTokenCount,
            outputTokenCount: outputTokenCount,
            promptDurationSeconds: promptDurationSeconds,
            generationDurationSeconds: generationDurationSeconds,
            reusedPromptTokenCount: generation.reusedPromptTokenCount
        )
    }

    static func promptLookupGeneration(
        prepared: consuming LMInput,
        promptPrefixCache: PromptPrefixCache?,
        parameters: GenerateParameters,
        container: ModelContainer,
        transcript: String,
        maximumDraftTokens: Int,
        startedAt: ContinuousClock.Instant
    ) async throws -> QwenPolisherResult? {
        let tokenIDs = prepared.text.tokens.asArray(Int.self)
        let prefix = promptPrefixCache.flatMap { prefix in
            tokenIDs.count > prefix.tokenIDs.count && tokenIDs.starts(with: prefix.tokenIDs)
                ? prefix : nil
        }
        let reusedCount = prefix?.tokenIDs.count ?? 0
        let value = CachedGenerationInput(
            input: LMInput(tokens: prepared.text.tokens[reusedCount...]),
            cache: prefix?.cache.map { $0.copy() } ?? []
        )
        return try await container.perform(nonSendable: value) { context, value in
            guard QwenPromptLookupDecoder.supports(context.model) else { return nil }
            return try QwenPromptLookupDecoder.generate(
                input: value.input,
                cache: value.cache.isEmpty ? nil : value.cache,
                context: context,
                parameters: parameters,
                transcript: transcript,
                maximumDraftTokens: maximumDraftTokens,
                fullPromptTokenCount: tokenIDs.count,
                reusedPromptTokenCount: reusedCount,
                startedAt: startedAt
            )
        }
    }

    static func generationStream(
        prepared: consuming LMInput,
        promptPrefixCache: PromptPrefixCache?,
        parameters: GenerateParameters,
        container: ModelContainer
    ) async throws -> GenerationStream {
        guard let promptPrefixCache else {
            let (stream, task) = try await container.perform(nonSendable: prepared) {
                context, input in
                try generationTask(
                    input: input, cache: nil, parameters: parameters, context: context)
            }
            return GenerationStream(stream: stream, task: task, reusedPromptTokenCount: 0)
        }

        let tokenIDs = prepared.text.tokens.asArray(Int.self)
        guard
            tokenIDs.count > promptPrefixCache.tokenIDs.count,
            tokenIDs.starts(with: promptPrefixCache.tokenIDs)
        else {
            let (stream, task) = try await container.perform(nonSendable: prepared) {
                context, input in
                try generationTask(
                    input: input, cache: nil, parameters: parameters, context: context)
            }
            return GenerationStream(stream: stream, task: task, reusedPromptTokenCount: 0)
        }
        let prefixCount = promptPrefixCache.tokenIDs.count
        let cachedInput = CachedGenerationInput(
            input: LMInput(tokens: prepared.text.tokens[prefixCount...]),
            cache: promptPrefixCache.cache.map { $0.copy() }
        )
        let (stream, task) = try await container.perform(nonSendable: cachedInput) {
            context, value in
            try generationTask(
                input: value.input,
                cache: value.cache,
                parameters: parameters,
                context: context
            )
        }
        return GenerationStream(
            stream: stream,
            task: task,
            reusedPromptTokenCount: prefixCount
        )
    }

    static func generationTask(
        input: LMInput,
        cache: [KVCache]?,
        parameters: GenerateParameters,
        context: ModelContext
    ) throws -> (AsyncStream<Generation>, Task<Void, Never>) {
        let iterator = try TokenIterator(
            input: input, model: context.model, cache: cache, parameters: parameters
        )
        return MLXLMCommon.generateTask(
            promptTokenCount: input.text.tokens.size,
            modelConfiguration: context.configuration,
            tokenizer: context.tokenizer,
            iterator: iterator
        )
    }

    static func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: duration)
                throw QwenPolisherError.timedOut
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }
}

extension QwenPolisherRuntime {
    static func firstCompleteJSONObject(in text: String) -> String? {
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if start == nil {
                if character == "{" {
                    start = index
                    depth = 1
                }
                index = text.index(after: index)
                continue
            }

            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let start {
                    let end = text.index(after: index)
                    return String(text[start..<end])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

private final class PromptPrefixCache: @unchecked Sendable {
    let tokenIDs: [Int]
    let cache: [KVCache]

    init(tokenIDs: [Int], cache: [KVCache]) {
        self.tokenIDs = tokenIDs
        self.cache = cache
    }
}

private final class AdapterApplicationState: @unchecked Sendable {
    var error: Error?
}

private struct CachedGenerationInput {
    let input: LMInput
    let cache: [KVCache]
}

private struct GenerationStream: Sendable {
    let stream: AsyncStream<Generation>
    let task: Task<Void, Never>
    let reusedPromptTokenCount: Int
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
