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

    /// Creates a measured generation result.
    public init(
        text: String,
        durationSeconds: TimeInterval,
        promptTokenCount: Int,
        outputTokenCount: Int,
        promptDurationSeconds: TimeInterval,
        generationDurationSeconds: TimeInterval,
        reusedPromptTokenCount: Int
    ) {
        self.text = text
        self.durationSeconds = durationSeconds
        self.promptTokenCount = promptTokenCount
        self.outputTokenCount = outputTokenCount
        self.promptDurationSeconds = promptDurationSeconds
        self.generationDurationSeconds = generationDurationSeconds
        self.reusedPromptTokenCount = reusedPromptTokenCount
    }
}

/// Low-level MLX generation knobs kept explicit for repeatable performance testing.
public struct QwenPolisherGenerationConfiguration: Equatable, Sendable {
    /// Rotating cache capacity, or `nil` for the lower-overhead short-prompt cache.
    public let maximumKVCacheSize: Int?
    /// Number of prompt tokens evaluated in one prefill step.
    public let prefillStepSize: Int
    /// Whether invariant chat-template and system tokens are prefilled once per language.
    public let usesPromptPrefixCache: Bool
    /// Whether an installed LoRA adapter is fused into the quantized base model.
    public let fusesAdapter: Bool

    /// Creates a bounded generation configuration.
    public init(
        maximumKVCacheSize: Int? = nil,
        prefillStepSize: Int = 512,
        usesPromptPrefixCache: Bool = true,
        fusesAdapter: Bool = true
    ) {
        self.maximumKVCacheSize = maximumKVCacheSize
        self.prefillStepSize = max(1, prefillStepSize)
        self.usesPromptPrefixCache = usesPromptPrefixCache
        self.fusesAdapter = fusesAdapter
    }
}

/// Owns the one text-only Qwen container and serializes bounded local generations.
public actor QwenPolisherRuntime {
    private let modelRoot: URL
    private let adapterRoot: URL?
    private let generationConfiguration: QwenPolisherGenerationConfiguration
    private var container: ModelContainer?
    private var preparationTask: Task<ModelContainer, Error>?
    private var promptPrefixCaches = [String: PromptPrefixCache]()

    /// Creates a runtime for one verified local model directory.
    public init(
        modelRoot: URL,
        adapterRoot: URL? = nil,
        generationConfiguration: QwenPolisherGenerationConfiguration = .init()
    ) {
        self.modelRoot = modelRoot
        self.adapterRoot = adapterRoot ?? Self.installedAdapterRoot(in: modelRoot)
        self.generationConfiguration = generationConfiguration
    }

    /// Whether the model container is loaded.
    public var isReady: Bool {
        container != nil
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
        let task = Task.detached(priority: .utility) {
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

    /// Generates one bounded cleanup result.
    public func polish(
        _ preparation: DeterministicPreparation,
        timeout: Duration = .seconds(2)
    ) async throws -> QwenPolisherResult {
        try Task.checkCancellation()
        try await prepare()
        guard let container else {
            throw CancellationError()
        }
        let prompt = PolishingPromptBuilder.build(from: preparation)
        let generationConfiguration = generationConfiguration
        let promptPrefixCache = try await promptPrefixCache(
            for: prompt.system,
            container: container
        )
        return try await Self.withTimeout(timeout) {
            try await Self.generate(
                prompt: prompt,
                container: container,
                configuration: generationConfiguration,
                promptPrefixCache: promptPrefixCache
            )
        }
    }

    /// Runs a one-token generation to populate runtime caches.
    public func warmUp() async throws {
        try await prepare()
        guard let container else {
            return
        }
        if generationConfiguration.usesPromptPrefixCache {
            for language in [TextLanguage.french, .english] {
                _ = try await promptPrefixCache(
                    for: PolishingPromptBuilder.systemInstruction(for: language),
                    container: container
                )
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
        container = nil
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
        container: ModelContainer,
        configuration: QwenPolisherGenerationConfiguration,
        promptPrefixCache: PromptPrefixCache?
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
        let generation = try await generationStream(
            prepared: prepared,
            promptPrefixCache: promptPrefixCache,
            parameters: parameters,
            container: container
        )
        let stream = generation.stream
        var outputChunks = [String]()
        var promptTokenCount = 0
        var outputTokenCount = 0
        var promptDurationSeconds: TimeInterval = 0
        var generationDurationSeconds: TimeInterval = 0
        var reachedLimit = false
        for await generation in stream {
            try Task.checkCancellation()
            switch generation {
            case .chunk(let chunk):
                outputChunks.append(chunk)
            case .info(let info):
                promptTokenCount = fullPromptTokenCount
                outputTokenCount = info.generationTokenCount
                promptDurationSeconds = info.promptTime
                generationDurationSeconds = info.generateTime
                if case .length = info.stopReason {
                    reachedLimit = true
                }
            case .toolCall:
                continue
            }
        }

        if reachedLimit {
            throw QwenPolisherError.tokenLimitReached
        }
        let text = outputChunks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw QwenPolisherError.emptyOutput
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

    static func generationStream(
        prepared: consuming LMInput,
        promptPrefixCache: PromptPrefixCache?,
        parameters: GenerateParameters,
        container: ModelContainer
    ) async throws -> GenerationStream {
        guard let promptPrefixCache else {
            let stream = try await container.perform(nonSendable: prepared) {
                context, input in
                try MLXLMCommon.generate(
                    input: input,
                    parameters: parameters,
                    context: context
                )
            }
            return GenerationStream(stream: stream, reusedPromptTokenCount: 0)
        }

        let tokenIDs = prepared.text.tokens.asArray(Int.self)
        guard
            tokenIDs.count > promptPrefixCache.tokenIDs.count,
            tokenIDs.starts(with: promptPrefixCache.tokenIDs)
        else {
            let stream = try await container.perform(nonSendable: prepared) {
                context, input in
                try MLXLMCommon.generate(
                    input: input,
                    parameters: parameters,
                    context: context
                )
            }
            return GenerationStream(stream: stream, reusedPromptTokenCount: 0)
        }
        let prefixCount = promptPrefixCache.tokenIDs.count
        let cachedInput = CachedGenerationInput(
            input: LMInput(tokens: prepared.text.tokens[prefixCount...]),
            cache: promptPrefixCache.cache.map { $0.copy() }
        )
        let stream = try await container.perform(nonSendable: cachedInput) { context, value in
            try MLXLMCommon.generate(
                input: value.input,
                cache: value.cache,
                parameters: parameters,
                context: context
            )
        }
        return GenerationStream(
            stream: stream,
            reusedPromptTokenCount: prefixCount
        )
    }

    static func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: duration)
                throw QwenPolisherError.timedOut
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
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
    let reusedPromptTokenCount: Int
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
