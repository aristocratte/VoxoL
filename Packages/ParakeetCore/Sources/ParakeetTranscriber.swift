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
        var result = [(word: String, margin: Float)]()
        var current = ""
        var margin = Float.greatestFiniteMagnitude
        for (index, tokenID) in transcription.tokenIds.enumerated() {
            guard let piece = tokenizer.piece(for: tokenID) else { continue }
            let value =
                index < transcription.tokenLogitMargins.count
                ? transcription.tokenLogitMargins[index] : 0
            if piece.first == Tokenizer.metaSpace {
                if !current.isEmpty { result.append((current, margin)) }
                current = String(piece.dropFirst())
                margin = value
            } else {
                current += piece
                margin = min(margin, value)
            }
        }
        if !current.isEmpty { result.append((current, margin)) }
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
        sourceCompatibleFeatures: Bool = false
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

        let encoderConfiguration = MLModelConfiguration()
        encoderConfiguration.computeUnits = computeUnits.mlComputeUnits
        let cpuConfiguration = MLModelConfiguration()
        cpuConfiguration.computeUnits = .cpuOnly

        let encoder = try MLModel(
            contentsOf: encCompiled,
            configuration: encoderConfiguration
        )
        let decoder = try MLModel(contentsOf: decCompiled, configuration: cpuConfiguration)
        let joint = try MLModel(contentsOf: joiCompiled, configuration: cpuConfiguration)

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
    }

    // MARK: - High-level transcription

    /// Transcribe a full audio file. Audio that exceeds the model window is
    /// split into overlapping segments so each continuation retains enough
    /// acoustic context to keep the language stable. Repeated-prefix tokens
    /// are discarded before the streams are concatenated and detokenized.
    public func transcribe(audioURL: URL) throws -> Transcription {
        let audio = try AudioLoader.loadMono16k(at: audioURL)
        return try transcribe(samples: audio)
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
    public func transcribe(samples: [Float]) throws -> Transcription {
        let primary = try transcribeSinglePass(
            samples: samples,
            segmentation: segmentation
        )
        guard
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
            samples: samples,
            segmentation: retryConfiguration.fallbackSegmentation
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
        samples: [Float],
        segmentation: ParakeetSegmentationConfiguration
    ) throws -> Transcription {
        let audioDuration = Double(samples.count) / Double(sampleRate)
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
            inputSampleCount: samples.count,
            maximumSampleCount: modelWindowSamples,
            overflowToleranceSampleCount:
                runner.maximumWaveformSampleCount == nil
                ? 0 : featureExtractor.hopLength
        )
        let inferenceSamples =
            singlePassSampleCount == samples.count
            ? samples : Array(samples.prefix(singlePassSampleCount))
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
        let chunks = AudioSegmenter.makeSegments(
            samples: inferenceSamples,
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
            contextualBias: contextualBias
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
            audioDurationSeconds: audioDuration,
            inferenceDurationSeconds: elapsed,
            timing: TranscriptionTiming(
                melExtract: result.melElapsed,
                encoder: result.encoderElapsed,
                decoderLoop: result.decodeElapsed,
                detokenize: detokElapsed
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
                    primary.timing.detokenize + fallback.timing.detokenize
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
