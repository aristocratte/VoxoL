import Foundation

/// Serializes model preparation and inference away from the main actor.
public actor ParakeetRuntime {
    private let modelRoot: URL
    private let computeUnits: ParakeetComputeUnits
    private let decoderWorkers: Int?
    private let segmentation: ParakeetSegmentationConfiguration
    private let retryConfiguration: ParakeetRetryConfiguration?

    private var transcriber: ParakeetTranscriber?
    private var preparationTask: Task<ParakeetTranscriber, Error>?

    /// Creates a runtime for one verified, revision-scoped model directory.
    public init(
        modelRoot: URL,
        computeUnits: ParakeetComputeUnits = .all,
        decoderWorkers: Int? = nil,
        segmentation: ParakeetSegmentationConfiguration = .production,
        retryConfiguration: ParakeetRetryConfiguration? = .production
    ) {
        self.modelRoot = modelRoot
        self.computeUnits = computeUnits
        self.decoderWorkers = decoderWorkers
        self.segmentation = segmentation
        self.retryConfiguration = retryConfiguration
    }

    /// Whether the three Core ML submodels are loaded and ready.
    public var isReady: Bool {
        transcriber != nil
    }

    /// Decoding bias to apply, kept across model preparation.
    ///
    /// Stored here rather than passed per call because both of its inputs
    /// outlive a single utterance and neither justifies reloading the model:
    /// the user edits their dictionary, and switches dictation language,
    /// while the runtime stays warm.
    private var decodingBias: ParakeetDecodingBias?

    /// Applies the user's vocabulary and the selected language to decoding.
    ///
    /// Pass a nil `languageCode` from an automatic mode. The language penalty
    /// suppresses English function words, so guessing French on English speech
    /// would remove most of the transcript.
    public func applyDecodingBias(
        vocabulary terms: [String],
        languageCode: String?
    ) async {
        guard let transcriber else {
            // Prepared lazily; recompute once the tokenizer exists.
            pendingBiasRequest = (terms, languageCode)
            return
        }
        // The vocabulary goes through the trie, not the flat offsets. A flat
        // boost on a term's subwords fires everywhere those subwords occur:
        // `humpback` is `▁h`+`ump`+`b`+`ack`, and encouraging `ack` in every
        // word cost 0.67 points of word error on FLEURS English — a user who
        // filled their dictionary was making their own dictation worse.
        let bias = transcriber.decodingBias(
            vocabulary: [],
            languageCode: languageCode,
            modelsRoot: modelRoot
        )
        decodingBias = bias
        transcriber.logitBias = bias.isEmpty ? nil : bias
        let contextual = transcriber.contextualVocabularyBias(for: terms)
        transcriber.contextualBias = contextual.isEmpty ? nil : contextual
    }

    /// Per-word confidence for a transcription this runtime produced.
    ///
    /// Empty when the model is not loaded. The caller treats that as nothing
    /// to observe rather than an error: shadow diagnostics must never be able
    /// to fail a dictation.
    public func wordConfidences(
        for transcription: Transcription
    ) -> [(word: String, margin: Float)] {
        transcriber?.wordConfidences(for: transcription) ?? []
    }

    /// A bias requested before the model finished loading.
    private var pendingBiasRequest: (terms: [String], languageCode: String?)?

    /// Compiles missing model caches and loads Core ML without blocking UI work.
    public func prepare() async throws {
        if transcriber != nil {
            return
        }
        if let preparationTask {
            transcriber = try await preparationTask.value
            self.preparationTask = nil
            return
        }

        let modelRoot = modelRoot
        let computeUnits = computeUnits
        let decoderWorkers = decoderWorkers
        let segmentation = segmentation
        let retryConfiguration = retryConfiguration
        let task = Task.detached(priority: .utility) {
            try ParakeetTranscriber(
                modelsRoot: modelRoot,
                computeUnits: computeUnits,
                decoderWorkers: decoderWorkers,
                segmentation: segmentation,
                retryConfiguration: retryConfiguration
            )
        }
        preparationTask = task
        do {
            transcriber = try await task.value
            preparationTask = nil
            if let pending = pendingBiasRequest {
                pendingBiasRequest = nil
                await applyDecodingBias(
                    vocabulary: pending.terms,
                    languageCode: pending.languageCode
                )
            }
        } catch {
            preparationTask = nil
            throw error
        }
    }

    /// Runs one final transcription at user-initiated priority.
    public func transcribe(samples: [Float]) async throws -> Transcription {
        try Task.checkCancellation()
        try await prepare()
        guard let transcriber else {
            throw ParakeetError.runtimeUnavailable
        }

        // Keep the synchronous Core ML pipeline actor-isolated. Actor methods may re-enter at an
        // `await`; wrapping this call in a detached task allowed a final decode to overlap a
        // cancelled partial decode on the same transcriber.
        let result = try transcriber.transcribe(samples: samples)
        try Task.checkCancellation()
        return result
    }
}
