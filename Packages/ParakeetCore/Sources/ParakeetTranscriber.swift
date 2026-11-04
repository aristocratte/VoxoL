// Adapted for VoxoL from parakeet-coreml-swift commit 75aec2a1c991319657ff4dec5f602c12da6c5012.
// Changes are documented in Packages/ParakeetCore/NOTICE.md.
import CoreML
import Foundation

/// End-to-end Parakeet TDT transcriber.
///
/// Expects a directory laid out like this (matching the HuggingFace repo):
///
/// ```
/// modelsRoot/
///   encoder.mlpackage/    (or encoder.mlmodelc, if already compiled)
///   decoder.mlpackage/
///   joint.mlpackage/
///   tokenizer.json
/// ```
///
/// The first call compiles each ``.mlpackage`` into a revision-local
/// ``.mlmodelc`` cache. VoxoL never downloads from this runtime.
public final class ParakeetTranscriber: @unchecked Sendable {
    let computeUnits: ParakeetComputeUnits
    let chunkMelFrames: Int  // must match the encoder's traced shape
    let sampleRate: Int

    let runner: ModelRunner
    let tokenizer: Tokenizer
    let featureExtractor: MelFeatureExtractor
    private let cacheURL: URL
    private let segmentation: ParakeetSegmentationConfiguration
    private let retryConfiguration: ParakeetRetryConfiguration?
    private let sourceCompatibleFeatures: Bool

    /// Per-token logit offsets applied to every subsequent transcription.
    ///
    /// Settable rather than fixed at init because both of its inputs change
    /// while the app runs: the user edits their dictionary, and switches
    /// dictation language, without the model being reloaded.
    public var logitBias: ParakeetDecodingBias?

    /// Vocabulary boost applied only where a term is already being spelled.
    ///
    /// Separate from ``logitBias`` because the two are different mechanisms:
    /// a flat offset suits a language penalty, where every listed token is
    /// unwanted everywhere, and ruins a vocabulary, where the same subword is
    /// wanted inside one word and harmful in every other.
    public var contextualBias: ParakeetContextualBias?

    /// Default encouragement for a term the user put in their own dictionary.
    ///
    /// Deliberately smaller than the 12-logit language penalty. Suppressing a
    /// word the model should not say is safe; forcing one it did not hear is
    /// not, and an over-eager boost would sprinkle a user's jargon through
    /// unrelated dictation. This nudges a close acoustic match over the line
    /// rather than overruling the audio.
    public static let defaultVocabularyBoost: Float = 4

    /// Builds a bias that makes the user's own vocabulary more likely.
    ///
    /// A generic model gets project names, client names and jargon wrong
    /// precisely because they are rare, and no amount of post-processing
    /// recovers them: once the decoder has emitted "cul bernetes", no string
    /// replacement turns it back into "Kubernetes". Biasing the decoder is the
    /// only place the correction can happen, and it is the one advantage a
    /// cloud service cannot match without holding the dictionary on its
    /// servers.
    ///
    /// Terms the vocabulary cannot express are skipped rather than partially
    /// boosted, so a misspelled entry never drags unrelated words with it.
    public func vocabularyBias(
        for terms: some Sequence<String>,
        boost: Float = defaultVocabularyBoost
    ) -> ParakeetDecodingBias {
        guard boost > 0 else { return ParakeetDecodingBias() }
        var ids = Set<Int>()
        for term in terms {
            guard let pieces = tokenizer.pieces(forWord: term) else { continue }
            ids.formUnion(pieces)
        }
        return .encouraging(ids, by: boost)
    }

    /// One entry per word, carrying the weakest logit margin among the tokens
    /// that spell it.
    ///
    /// A word is only as certain as its least certain piece: a confident `chip`
    /// followed by a hesitant `set` is a hesitant word. This is what confines a
    /// repair pass to the spans where the recogniser actually hesitated —
    /// without it, a model asked to fix words is free to rewrite a sentence it
    /// heard perfectly.
    public func wordConfidences(
        for transcription: Transcription
    ) -> [(word: String, margin: Float)] {
        wordEvidence(for: transcription).map { ($0.surface, $0.minimumLogitMargin) }
    }

    /// Full decoder proof for each lexical word in the detokenized transcript.
    public func wordEvidence(for transcription: Transcription) -> [ParakeetWordEvidence] {
        struct TokenGroup {
            var text: String
            var indices: [Int]
        }

        var groups = [TokenGroup]()
        var current = TokenGroup(text: "", indices: [])
        func flush() {
            if !current.text.isEmpty, !current.indices.isEmpty {
                groups.append(current)
            }
            current = TokenGroup(text: "", indices: [])
        }
        for (index, tokenID) in transcription.tokenIds.enumerated() {
            guard let piece = tokenizer.piece(for: tokenID), !piece.isEmpty else { continue }
            if piece.first == Tokenizer.metaSpace {
                flush()
                current.text = String(piece.dropFirst())
                current.indices = [index]
            } else {
                current.text += piece
                current.indices.append(index)
            }
        }
        flush()

        guard
            let lexical = try? NSRegularExpression(
                pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#
            )
        else { return [] }
        let source = transcription.text as NSString
        var searchLocation = 0
        var result = [ParakeetWordEvidence]()
        for group in groups {
            let remaining = NSRange(
                location: min(searchLocation, source.length),
                length: max(0, source.length - min(searchLocation, source.length))
            )
            let groupRange = source.range(of: group.text, options: [], range: remaining)
            guard groupRange.location != NSNotFound else { continue }
            searchLocation = groupRange.location + groupRange.length
            let localRange = NSRange(location: 0, length: (group.text as NSString).length)
            let tokenIDs = group.indices.compactMap { index in
                transcription.tokenIds.indices.contains(index)
                    ? transcription.tokenIds[index] : nil
            }
            let frames = group.indices.compactMap { index in
                transcription.frameIndices.indices.contains(index)
                    ? transcription.frameIndices[index] : nil
            }
            let durations = group.indices.compactMap { index in
                transcription.durations.indices.contains(index)
                    ? transcription.durations[index] : nil
            }
            let margins = group.indices.compactMap { index in
                transcription.tokenLogitMargins.indices.contains(index)
                    ? transcription.tokenLogitMargins[index] : nil
            }
            let minimumMargin = margins.min() ?? 0
            let meanMargin =
                margins.isEmpty
                ? 0 : margins.reduce(0, +) / Float(margins.count)
            let frameStart = frames.min()
            let frameEnd = zip(frames, durations).map { frame, duration in
                frame + max(1, duration)
            }.max()
            let frameRange = frameStart.flatMap { start in
                frameEnd.map { start..<max(start + 1, $0) }
            }
            let nearBoundary = frames.contains { frame in
                transcription.chunkBoundaryFrames.contains { boundary in
                    abs(frame - boundary) <= 5
                }
            }

            for match in lexical.matches(in: group.text, range: localRange) {
                let absolute = NSRange(
                    location: groupRange.location + match.range.location,
                    length: match.range.length
                )
                result.append(
                    ParakeetWordEvidence(
                        surface: source.substring(with: absolute),
                        sourceRange: absolute.location..<(absolute.location + absolute.length),
                        tokenIDs: tokenIDs,
                        tokenIndices: group.indices,
                        frameIndices: frames,
                        durations: durations,
                        logitMargins: margins,
                        minimumLogitMargin: minimumMargin,
                        meanLogitMargin: meanMargin,
                        frameRange: frameRange,
                        nearChunkBoundary: nearBoundary
                    )
                )
            }
        }
        return result
    }

    /// Builds the trie-scoped vocabulary boost for `terms`.
    ///
    /// Terms the tokenizer cannot segment are skipped rather than partially
    /// added, so a typo never boosts an unrelated prefix.
    public func contextualVocabularyBias(
        for terms: some Sequence<String>,
        entryBoost: Float = ParakeetContextualBias.defaultEntryBoost,
        continuationBoost: Float = ParakeetContextualBias.defaultContinuationBoost
    ) -> ParakeetContextualBias {
        let pieces = terms.compactMap { tokenizer.pieces(forWord: $0) }
        return ParakeetContextualBias(
            termPieces: pieces.map(Array.init),
            entryBoost: entryBoost,
            continuationBoost: continuationBoost
        )
    }

    /// Combines the user's vocabulary with the language penalty for `code`.
    ///
    /// Pass a nil language code from an automatic mode: guessing would apply
    /// English-suppressing offsets to English dictation.
    public func decodingBias(
        vocabulary terms: some Sequence<String>,
        languageCode code: String?,
        modelsRoot: URL,
        boost: Float = defaultVocabularyBoost
    ) -> ParakeetDecodingBias {
        var bias = vocabularyBias(for: terms, boost: boost)
        if let code,
            let penalty = ParakeetDecodingBias.languagePenalty(
                forLanguageCode: code,
                modelsRoot: modelsRoot
            )
        {
            bias = bias.merging(penalty)
        }
        return bias
    }

    /// Load the transcriber. Compiles any `.mlpackage`s that aren't already
    /// in the cache. Use `deleteSourceAfterCompile: true` to drop the raw
    /// `.mlpackage` from disk once compilation succeeds (halves peak disk
    /// usage on space-constrained devices).
    ///
    /// ``decoderWorkers`` controls how many parallel decode-loop threads
    /// the pipeline uses. ``nil`` (the default) picks 2 for ANE / GPU / all
    /// and 1 for CPU-only (because on CPU the encoder contends with the
    /// decode workers on the same cores). Higher values can help GPU
    /// further if decode is the bottleneck.
    public init(
        modelsRoot: URL,
        computeUnits: ParakeetComputeUnits = .ane,
        chunkMelFrames: Int = 3000,
        sampleRate: Int = 16_000,
        deleteSourceAfterCompile: Bool = false,
        cacheDirectory: URL? = nil,
        decoderWorkers: Int? = nil,
        segmentation: ParakeetSegmentationConfiguration = .production,
        retryConfiguration: ParakeetRetryConfiguration? = nil,
        sourceCompatibleFeatures: Bool = false,
        warmUpEncoder: Bool = false
    ) throws {
        self.computeUnits = computeUnits
        self.chunkMelFrames = chunkMelFrames
        self.sampleRate = sampleRate
        self.segmentation = segmentation
        self.retryConfiguration = retryConfiguration
        self.sourceCompatibleFeatures = sourceCompatibleFeatures

        let cache = ModelCache(
            cacheDirectory: cacheDirectory
                ?? modelsRoot.appendingPathComponent(".compiled", isDirectory: true),
            deleteSourceAfterCompile: deleteSourceAfterCompile
        )
        self.cacheURL = cache.cacheDirectory

        let encoderURL = try ParakeetTranscriber.resolveModel(
            under: modelsRoot, named: "encoder"
        )
        let decoderURL = try ParakeetTranscriber.resolveModel(
            under: modelsRoot, named: "decoder"
        )
        let jointURL = try ParakeetTranscriber.resolveModel(
            under: modelsRoot, named: "joint"
        )
        let tokenizerURL = modelsRoot.appendingPathComponent("tokenizer.json")

        let encCompiled = try cache.compiledURL(for: encoderURL)
        let decCompiled = try cache.compiledURL(for: decoderURL)
        let joiCompiled = try cache.compiledURL(for: jointURL)

        func makeEncoderConfiguration() -> MLModelConfiguration {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits.mlComputeUnits
            if computeUnits == .all {
                // Amortize additional Core ML specialization during model preparation
                // to reduce warm encoder latency on the validated all-devices path.
                var hints = configuration.optimizationHints
                hints.specializationStrategy = .fastPrediction
                configuration.optimizationHints = hints
            }
            return configuration
        }
        let decoderConfiguration = MLModelConfiguration()
        let decoderComputeUnits = ProcessInfo.processInfo.environment[
            "VOXOL_ASR_DECODER_COMPUTE_UNITS"
        ].flatMap(ParakeetComputeUnits.init(rawValue:))?.mlComputeUnits ?? .cpuOnly
        decoderConfiguration.computeUnits = decoderComputeUnits
        if ProcessInfo.processInfo.environment["VOXOL_ASR_DECODER_FAST_PREDICTION"] == "1" {
            var hints = decoderConfiguration.optimizationHints
            hints.specializationStrategy = .fastPrediction
            decoderConfiguration.optimizationHints = hints
        }

        let encoder = try MLModel(
            contentsOf: encCompiled,
            configuration: makeEncoderConfiguration()
        )
        let useStaticEncoderVariants =
            ProcessInfo.processInfo.environment["VOXOL_ASR_ENCODER_STATIC_VARIANTS"] == "1"
        let additionalWaveformEncoders: [MLModel]
        if useStaticEncoderVariants {
            let variantSources = ["encoder-20s", "encoder-25s"].compactMap { name in
                try? ParakeetTranscriber.resolveModel(under: modelsRoot, named: name)
            }
            guard !variantSources.isEmpty else {
                throw ParakeetError.runtimeUnavailable
            }
            additionalWaveformEncoders = try variantSources.map { source in
                let compiled = try cache.compiledURL(for: source)
                return try MLModel(
                    contentsOf: compiled,
                    configuration: makeEncoderConfiguration()
                )
            }
        } else {
            additionalWaveformEncoders = []
        }
        let decoder = try MLModel(contentsOf: decCompiled, configuration: decoderConfiguration)
        let joint = try MLModel(contentsOf: joiCompiled, configuration: decoderConfiguration)
        let fusedDecoderJoint: MLModel? = try {
            guard
                let rawPath = ProcessInfo.processInfo.environment[
                    "VOXOL_ASR_DECODER_JOINT_FUSED_MODEL"
                ],
                !rawPath.isEmpty
            else { return nil }

            let expandedPath = NSString(string: rawPath).expandingTildeInPath
            let sourceURL = URL(fileURLWithPath: expandedPath)
            let fusedCache = ModelCache(
                cacheDirectory: sourceURL.deletingLastPathComponent()
                    .appendingPathComponent(".compiled", isDirectory: true),
                deleteSourceAfterCompile: false
            )
            let compiledURL = try fusedCache.compiledURL(for: sourceURL)
            return try MLModel(
                contentsOf: compiledURL,
                configuration: decoderConfiguration
            )
        }()

        // Decoder stateful sizes are encoded in the spec's hidden / cell
        // input shapes: [num_layers, 1, hidden].
        let (decLayers, decHidden) = ParakeetTranscriber.readDecoderStateShape(
            from: decoder
        )

        // Per-target worker defaults tuned on M-class silicon. Measured
        // scaling on `test_audio.mp3` (see README):
        //   - CPU:  1 worker  (2+ contends with the on-CPU encoder)
        //   - ANE:  2 workers (encoder-bound; more doesn't help)
        //   - GPU:  4 workers (diminishing returns past 4)
        //   - all:  4 workers (assume GPU involved)
        let workerCount: Int = {
            if let override = decoderWorkers { return max(1, override) }
            switch computeUnits {
            case .cpu: return 1
            case .ane: return 2
            case .gpu, .all: return 4
            }
        }()

        self.runner = try ModelRunner(
            encoder: encoder,
            decoder: decoder,
            joint: joint,
            fusedDecoderJoint: fusedDecoderJoint,
            additionalWaveformEncoders: additionalWaveformEncoders,
            encoderShapes: ModelRunner.EncoderShapes(
                batch: 1, maxTime: chunkMelFrames, numMelBins: 128
            ),
            decoderHiddenLayers: decLayers,
            decoderHiddenSize: decHidden,
            blankTokenId: 8192,
            durations: [0, 1, 2, 3, 4],
            vocabSize: 8193,
            maxSymbolsPerStep: 10,
            numDecoderWorkers: workerCount
        )
        self.tokenizer = try Tokenizer(tokenizerJSONURL: tokenizerURL)
        self.featureExtractor = try MelFeatureExtractor(
            sampleRate: sampleRate,
            hopLength: 160,
            winLength: 400,
            nFFT: 512,
            numMelFilters: 128,
            preemphasis: 0.97
        )
        if warmUpEncoder {
            try runner.warmUpEncoder()
        }
    }

    // MARK: - High-level transcription

    /// Transcribe a full audio file. Audio that exceeds the model window is
    /// split into overlapping segments so each continuation retains enough
    /// acoustic context to keep the language stable. Repeated-prefix tokens
    /// are discarded before the streams are concatenated and detokenized.
    public func transcribe(
        audioURL: URL,
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) throws -> Transcription {
        try cancellationCheck()
        let audio = try AudioLoader.mapMono16k(
            at: audioURL,
            cancellationCheck: cancellationCheck
        )
        return try transcribe(
            storage: .mappedPCM(audio.data, sampleCount: audio.sampleCount),
            sampleCount: audio.sampleCount,
            cancellationCheck: cancellationCheck,
            encoderCache: nil,
            sessionID: nil
        )
    }

    /// Transcribe an already-loaded mono `Float` buffer at ``sampleRate``.
    ///
    /// Pipelined across chunks: mel extraction (CPU), encoder (ANE / GPU /
    /// CPU depending on ``computeUnits``), and the greedy decode loop (CPU)
    /// each run on their own pthread, connected by two semaphore-gated
    /// ring buffers. The pipeline stall is bounded by the slowest stage,
    /// not the sum of stages, so on ANE it cuts wall time by ~37% and on
    /// GPU by ~50%.
    ///
    /// Call sites don't have to care: it's still a plain synchronous
    /// throwing method.
    /// The optional cancellation check must be thread-safe: all pipeline stages call it.
    public func transcribe(
        samples: [Float],
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) throws -> Transcription {
        try transcribe(
            samples: samples, cancellationCheck: cancellationCheck,
            encoderCache: nil, sessionID: nil)
    }

    func transcribe(
        samples: [Float],
        cancellationCheck: @escaping @Sendable () throws -> Void,
        encoderCache: EncoderResultCache?,
        sessionID: UUID?,
        collectLogitMargins: Bool = true,
        retryLongForm: Bool = true
    ) throws -> Transcription {
        try transcribe(
            storage: .memory(samples),
            sampleCount: samples.count,
            cancellationCheck: cancellationCheck,
            encoderCache: encoderCache,
            sessionID: sessionID,
            collectLogitMargins: collectLogitMargins,
            retryLongForm: retryLongForm
        )
    }

    private func transcribe(
        storage: AudioSampleStorage,
        sampleCount: Int,
        cancellationCheck: @escaping @Sendable () throws -> Void,
        encoderCache: EncoderResultCache?,
        sessionID: UUID?,
        collectLogitMargins: Bool = true,
        retryLongForm: Bool = true
    ) throws -> Transcription {
        try cancellationCheck()
        let primary = try transcribeSinglePass(
            storage: storage,
            sampleCount: sampleCount,
            segmentation: segmentation,
            cancellationCheck: cancellationCheck,
            encoderCache: encoderCache,
            sessionID: sessionID,
            collectLogitMargins: collectLogitMargins
        )
        try cancellationCheck()
        guard
            retryLongForm,
            let retryConfiguration,
            LongFormRetryPolicy.shouldRetry(
                audioDurationSeconds: primary.audioDurationSeconds,
                confidence: primary.confidence,
                configuration: retryConfiguration
            )
        else {
            return primary
        }

        let fallback = try transcribeSinglePass(
            storage: storage,
            sampleCount: sampleCount,
            segmentation: retryConfiguration.fallbackSegmentation,
            cancellationCheck: cancellationCheck,
            encoderCache: encoderCache,
            sessionID: sessionID,
            collectLogitMargins: collectLogitMargins
        )
        let useFallback = LongFormRetryPolicy.shouldPreferFallback(
            audioDurationSeconds: primary.audioDurationSeconds,
            primary: primary.confidence,
            fallback: fallback.confidence,
            configuration: retryConfiguration
        )
        return combinedTranscription(
            selected: useFallback ? fallback : primary,
            primary: primary,
            fallback: fallback,
            usedFallbackSegmentation: useFallback
        )
    }

    private func transcribeSinglePass(
        storage: AudioSampleStorage,
        sampleCount: Int,
        segmentation: ParakeetSegmentationConfiguration,
        cancellationCheck: @escaping @Sendable () throws -> Void,
        encoderCache: EncoderResultCache?,
        sessionID: UUID?,
        collectLogitMargins: Bool
    ) throws -> Transcription {
        let audioDuration = Double(sampleCount) / Double(sampleRate)
        // The direct-waveform runtime declares its exact sample capacity.
        // Feature-input runtimes retain the centered-STFT frame calculation.
        let modelWindowSamples = AudioSegmenter.modelWindowSampleCount(
            maximumWaveformSampleCount: runner.maximumWaveformSampleCount,
            chunkMelFrames: chunkMelFrames,
            hopLength: featureExtractor.hopLength
        )
        // Some 30.000 s WAV files exceed the 3,000-frame waveform contract by
        // exactly one 10 ms hop. Trimming only that final hop avoids a costly
        // two-window decode and its overlap ambiguity.
        let singlePassSampleCount = AudioSegmenter.singlePassSampleCount(
            inputSampleCount: sampleCount,
            maximumSampleCount: modelWindowSamples,
            overflowToleranceSampleCount:
                runner.maximumWaveformSampleCount == nil
                ? 0 : featureExtractor.hopLength
        )
        let configuredMaximumSamples = Int(
            segmentation.maximumSegmentDurationSeconds * Double(sampleRate)
        )
        let maximumSegmentSamples = min(
            modelWindowSamples,
            max(1, configuredMaximumSamples)
        )
        let overlapSamples = min(
            maximumSegmentSamples - 1,
            Int(segmentation.overlapDurationSeconds * Double(sampleRate))
        )
        let segmentationThresholdSamples = min(
            modelWindowSamples,
            max(
                maximumSegmentSamples,
                Int(
                    segmentation.segmentationThresholdDurationSeconds
                        * Double(sampleRate)
                )
            )
        )
        let chunks = AudioSegmenter.makeSegmentPlan(
            storage: storage,
            sampleCount: singlePassSampleCount,
            maximumSamples: maximumSegmentSamples,
            overlapSamples: overlapSamples,
            segmentationThresholdSamples: segmentationThresholdSamples
        )

        let start = Date()
        let result = try Pipeline.run(
            chunks: chunks,
            featureExtractor: featureExtractor,
            runner: runner,
            sourceCompatibleFeatures: sourceCompatibleFeatures,
            logitBias: logitBias,
            contextualBias: contextualBias,
            collectLogitMargins: collectLogitMargins,
            cancellationCheck: cancellationCheck,
            encoderCache: encoderCache,
            sessionID: sessionID
        )
        let elapsed = Date().timeIntervalSince(start)

        let tDetok = Date()
        let text = tokenizer.decode(result.tokens, skipSpecial: true)
        let detokElapsed = Date().timeIntervalSince(tDetok)

        return Transcription(
            text: text,
            tokenIds: result.tokens,
            frameIndices: result.frames,
            durations: result.durations,
            tokenLogitMargins: result.tokenLogitMargins,
            chunkBoundaryFrames: result.chunkBoundaryFrames,
            audioDurationSeconds: audioDuration,
            inferenceDurationSeconds: elapsed,
            timing: TranscriptionTiming(
                melExtract: result.melElapsed,
                encoder: result.encoderElapsed,
                decoderLoop: result.decodeElapsed,
                detokenize: detokElapsed,
                reusedEncoderChunks: result.reusedEncoderChunks
            ),
            confidence: TranscriptionConfidence(
                emittedTokenCount: result.tokens.count,
                meanTokenLogitMargin: result.meanTokenLogitMargin,
                lowerDecileTokenLogitMargin: result.lowerDecileTokenLogitMargin,
                meanDurationLogitMargin: result.meanDurationLogitMargin,
                lowerDecileDurationLogitMargin:
                    result.lowerDecileDurationLogitMargin,
                blankDecisionRatio: result.blankDecisionRatio,
                maximumFramesWithoutEmission:
                    result.maximumFramesWithoutEmission,
                minimumOverlapTokenAgreement:
                    result.minimumOverlapTokenAgreement,
                meanOverlapTokenAgreement: result.meanOverlapTokenAgreement
            ),
            inferenceAttemptCount: 1,
            usedFallbackSegmentation: false
        )
    }

    private func combinedTranscription(
        selected: Transcription,
        primary: Transcription,
        fallback: Transcription,
        usedFallbackSegmentation: Bool
    ) -> Transcription {
        Transcription(
            text: selected.text,
            tokenIds: selected.tokenIds,
            frameIndices: selected.frameIndices,
            durations: selected.durations,
            tokenLogitMargins: selected.tokenLogitMargins,
            chunkBoundaryFrames: selected.chunkBoundaryFrames,
            audioDurationSeconds: selected.audioDurationSeconds,
            inferenceDurationSeconds:
                primary.inferenceDurationSeconds
                + fallback.inferenceDurationSeconds,
            timing: TranscriptionTiming(
                melExtract:
                    primary.timing.melExtract + fallback.timing.melExtract,
                encoder: primary.timing.encoder + fallback.timing.encoder,
                decoderLoop:
                    primary.timing.decoderLoop + fallback.timing.decoderLoop,
                detokenize:
                    primary.timing.detokenize + fallback.timing.detokenize,
                reusedEncoderChunks:
                    primary.timing.reusedEncoderChunks + fallback.timing.reusedEncoderChunks
            ),
            confidence: selected.confidence,
            inferenceAttemptCount: 2,
            usedFallbackSegmentation: usedFallbackSegmentation
        )
    }

    // MARK: - Helpers

    /// Look for ``<name>.mlmodelc`` (preferred; already compiled) then
    /// ``<name>.mlpackage`` inside ``modelsRoot``.
    private static func resolveModel(
        under root: URL, named: String
    ) throws -> URL {
        let candidates = [
            root.appendingPathComponent("\(named).mlmodelc"),
            root.appendingPathComponent("\(named).mlpackage"),
        ]
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        throw ParakeetError.modelNotFound(url: candidates[1])
    }

    /// Sniff the decoder's ``hidden`` input shape to figure out the LSTM's
    /// (num_layers, hidden_size). The spec records it as the symbolic
    /// shape ``[num_layers, 1, hidden]``.
    private static func readDecoderStateShape(
        from model: MLModel
    ) -> (layers: Int, hidden: Int) {
        if let desc = model.modelDescription.inputDescriptionsByName["hidden"],
            let con = desc.multiArrayConstraint
        {
            let shape = con.shape.map(\.intValue)
            if shape.count == 3 {
                return (shape[0], shape[2])
            }
        }
        return (2, 640)  // Parakeet TDT 0.6B defaults.
    }

    /// Cache directory where compiled `.mlmodelc`s live. Exposed so callers
    /// can clear it if they want to force a recompile or free disk.
    var compiledCacheDirectory: URL { cacheURL }

}
