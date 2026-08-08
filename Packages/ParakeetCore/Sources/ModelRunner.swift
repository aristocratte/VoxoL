// Adapted for VoxoL from parakeet-coreml-swift commit 75aec2a1c991319657ff4dec5f602c12da6c5012.
// Changes are documented in Packages/ParakeetCore/NOTICE.md.
import CoreML
import Foundation

/// Top-level container for the three Parakeet submodules plus a pool of
/// :class:`DecoderWorker` instances for parallel decoding.
///
/// The encoder has a single set of reusable input buffers (we only have
/// one encoder running at a time -- it's driven by the pipeline's
/// serial stage-2 queue). The decoder + joint each have N workers, one
/// per concurrent decode thread; the pipeline's stage-3 worker pool
/// borrows / returns workers from this pool via ``acquireWorker`` /
/// ``releaseWorker``.
final class ModelRunner: @unchecked Sendable {
    enum EncoderInputKind: Equatable {
        case features
        case waveform
    }

    private enum EncoderInputStorage {
        case features(
            features: MLMultiArray,
            mask: MLMultiArray,
            bag: FeatureBag
        )
        case waveform(
            audio: MLMultiArray,
            length: MLMultiArray,
            bag: FeatureBag,
            maximumSampleCount: Int
        )
    }

    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel

    struct EncoderShapes {
        let batch: Int  // 1
        let maxTime: Int  // 3000 mel frames (traced)
        let numMelBins: Int  // 128
    }

    let encoderShapes: EncoderShapes
    let decoderHiddenLayers: Int
    let decoderHiddenSize: Int
    let blankTokenId: Int
    let durations: [Int]
    let vocabSize: Int
    let maxSymbolsPerStep: Int

    // MARK: - Encoder inputs (single-instance)

    private let encoderInputs: EncoderInputStorage
    let predictionOptions = MLPredictionOptions()

    // MARK: - Decoder worker pool

    let decoderWorkers: [DecoderWorker]

    /// Underlying pool: consumers take a worker to run one chunk's decode
    /// loop, then return it.
    private let workerPool: BlockingWorkerPool

    init(
        encoder: MLModel,
        decoder: MLModel,
        joint: MLModel,
        encoderShapes: EncoderShapes,
        decoderHiddenLayers: Int,
        decoderHiddenSize: Int,
        blankTokenId: Int,
        durations: [Int],
        vocabSize: Int,
        maxSymbolsPerStep: Int,
        numDecoderWorkers: Int = 2
    ) throws {
        self.encoder = encoder
        self.decoder = decoder
        self.joint = joint
        self.encoderShapes = encoderShapes
        self.decoderHiddenLayers = decoderHiddenLayers
        self.decoderHiddenSize = decoderHiddenSize
        self.blankTokenId = blankTokenId
        self.durations = durations
        self.vocabSize = vocabSize
        self.maxSymbolsPerStep = maxSymbolsPerStep

        // --- Encoder inputs ---
        let inputDescriptions = encoder.modelDescription.inputDescriptionsByName
        switch try Self.encoderInputKind(inputNames: Set(inputDescriptions.keys)) {
        case .features:
            let features = try MLMultiArray(
                shape: [
                    NSNumber(value: 1),
                    NSNumber(value: encoderShapes.maxTime),
                    NSNumber(value: encoderShapes.numMelBins),
                ],
                dataType: .float32
            )
            let mask = try MLMultiArray(
                shape: [NSNumber(value: 1), NSNumber(value: encoderShapes.maxTime)],
                dataType: .int32
            )
            encoderInputs = .features(
                features: features,
                mask: mask,
                bag: FeatureBag([
                    "input_features": MLFeatureValue(multiArray: features),
                    "attention_mask": MLFeatureValue(multiArray: mask),
                ])
            )
        case .waveform:
            guard
                let audioDescription = inputDescriptions["audio_signal"],
                let audioConstraint = audioDescription.multiArrayConstraint,
                audioConstraint.shape.count == 2
            else {
                throw ParakeetError.runtimeUnavailable
            }
            let maximumSampleCount = audioConstraint.shape[1].intValue
            let audio = try MLMultiArray(
                shape: [NSNumber(value: 1), NSNumber(value: maximumSampleCount)],
                dataType: .float32
            )
            let length = try MLMultiArray(
                shape: [NSNumber(value: 1)],
                dataType: .int32
            )
            encoderInputs = .waveform(
                audio: audio,
                length: length,
                bag: FeatureBag([
                    "audio_signal": MLFeatureValue(multiArray: audio),
                    "audio_length": MLFeatureValue(multiArray: length),
                ]),
                maximumSampleCount: maximumSampleCount
            )
        }

        // --- Decoder worker pool ---
        let workerCount = max(1, numDecoderWorkers)
        var workers = [DecoderWorker]()
        workers.reserveCapacity(workerCount)
        for _ in 0..<workerCount {
            workers.append(
                try DecoderWorker(
                    decoder: decoder,
                    joint: joint,
                    decoderHiddenLayers: decoderHiddenLayers,
                    decoderHiddenSize: decoderHiddenSize
                )
            )
        }
        self.decoderWorkers = workers
        self.workerPool = BlockingWorkerPool(workers: workers)
    }

    // MARK: - Encoder

    var encoderInputKind: EncoderInputKind {
        switch encoderInputs {
        case .features: .features
        case .waveform: .waveform
        }
    }

    var maximumWaveformSampleCount: Int? {
        guard case .waveform(_, _, _, let maximumSampleCount) = encoderInputs else {
            return nil
        }
        return maximumSampleCount
    }

    static func encoderInputKind(inputNames: Set<String>) throws -> EncoderInputKind {
        if inputNames.isSuperset(of: ["input_features", "attention_mask"]) {
            return .features
        }
        if inputNames.isSuperset(of: ["audio_signal", "audio_length"]) {
            return .waveform
        }
        throw ParakeetError.runtimeUnavailable
    }

    /// Write mel features + mask into the reused input buffers, run the
    /// encoder, return the output `encoder_hidden` / `encoder_mask` arrays.
    func runEncoder(
        features: [[Float]],
        mask: [Int32]
    ) throws -> (hidden: MLMultiArray, mask: MLMultiArray) {
        guard
            case .features(let encoderFeatures, let encoderMask, let inputs) =
                encoderInputs
        else {
            throw ParakeetError.runtimeUnavailable
        }
        let t = encoderShapes.maxTime
        let m = encoderShapes.numMelBins

        let fPtr = encoderFeatures.dataPointer
            .bindMemory(to: Float32.self, capacity: t * m)
        memset(fPtr, 0, t * m * MemoryLayout<Float32>.size)
        let copyT = min(features.count, t)
        for ti in 0..<copyT {
            let row = features[ti]
            let copyM = min(row.count, m)
            row.withUnsafeBufferPointer { src in
                guard copyM > 0, let source = src.baseAddress else {
                    return
                }
                memcpy(
                    fPtr.advanced(by: ti * m),
                    source,
                    copyM * MemoryLayout<Float32>.size
                )
            }
        }

        let mPtr = encoderMask.dataPointer
            .bindMemory(to: Int32.self, capacity: t)
        memset(mPtr, 0, t * MemoryLayout<Int32>.size)
        for ti in 0..<min(mask.count, t) { mPtr[ti] = mask[ti] }

        let out = try encoder.prediction(
            from: inputs, options: predictionOptions
        )
        return try encoderOutputs(from: out)
    }

    func runEncoder(
        samples: [Float]
    ) throws -> (hidden: MLMultiArray, mask: MLMultiArray) {
        guard
            case .waveform(let audio, let length, let inputs, let maximumSampleCount) =
                encoderInputs,
            samples.count <= maximumSampleCount
        else {
            throw ParakeetError.runtimeUnavailable
        }
        let audioPointer = audio.dataPointer.bindMemory(
            to: Float32.self,
            capacity: maximumSampleCount
        )
        memset(
            audioPointer,
            0,
            maximumSampleCount * MemoryLayout<Float32>.size
        )
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            memcpy(
                audioPointer,
                baseAddress,
                samples.count * MemoryLayout<Float32>.size
            )
        }
        length.dataPointer.bindMemory(to: Int32.self, capacity: 1)[0] =
            Int32(samples.count)
        let out = try encoder.prediction(
            from: inputs,
            options: predictionOptions
        )
        return try encoderOutputs(from: out)
    }

    private func encoderOutputs(
        from out: MLFeatureProvider
    ) throws -> (hidden: MLMultiArray, mask: MLMultiArray) {
        guard let hidden = out.featureValue(for: "encoder_hidden")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "encoder_hidden") }
        guard let outMask = out.featureValue(for: "encoder_mask")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "encoder_mask") }
        return (hidden, outMask)
    }

    // MARK: - Decoder worker pool

    /// Acquire (blocking) a decoder worker. Returns nil if the pool has
    /// been shut down. Release with ``releaseWorker`` when the decode
    /// loop for a chunk finishes.
    func acquireWorker() -> DecoderWorker? {
        workerPool.acquire()
    }

    func releaseWorker(_ worker: DecoderWorker) {
        workerPool.release(worker)
    }
}

/// Fixed-size pool with blocking acquire semantics. Straight `NSLock` +
/// `DispatchSemaphore`, no `async` required.
final class BlockingWorkerPool: @unchecked Sendable {
    private var available: [DecoderWorker]
    private let lock = NSLock()
    private let semaphore: DispatchSemaphore
    private var closed = false

    init(workers: [DecoderWorker]) {
        available = workers
        semaphore = DispatchSemaphore(value: workers.count)
    }

    func acquire() -> DecoderWorker? {
        semaphore.wait()
        lock.lock()
        if closed || available.isEmpty {
            lock.unlock()
            semaphore.signal()
            return nil
        }
        let w = available.removeLast()
        lock.unlock()
        return w
    }

    func release(_ worker: DecoderWorker) {
        lock.lock()
        available.append(worker)
        lock.unlock()
        semaphore.signal()
    }
}
