// Adapted for VoxoL from parakeet-coreml-swift commit 75aec2a1c991319657ff4dec5f602c12da6c5012.
// Changes are documented in Packages/ParakeetCore/NOTICE.md.
import CoreML
import Dispatch
import Foundation

/// Pipelined long-form transcription.
///
/// Three stages connected by bounded blocking queues:
///
/// 1. **mel extraction** (CPU, `vDSP`).
/// 2. **encoder** (ANE / GPU / CPU depending on ``computeUnits``).
/// 3. **greedy TDT decode** (CPU, LSTM + joint) -- runs in a worker pool
///    of N :class:`DecoderWorker`s so the encoder isn't the only thing
///    waiting on a single CPU decode loop.
///
/// With default settings (2 decode workers) the GPU build is
/// encoder-bound; the ANE build is also encoder-bound; the CPU build is
/// encoder-bound by a wide margin. In all three cases, wall clock
/// collapses to roughly ``max(stage_time) * num_chunks``.
enum Pipeline {

    struct Result {
        var tokens: [Int]
        var frames: [Int]
        var durations: [Int]
        /// Kept per token, not just aggregated: it is the only signal that says
        /// where the recogniser hesitated, which is where a repair pass may act.
        var tokenLogitMargins: [Float]
        var chunkBoundaryFrames: [Int]
        var melElapsed: Double
        var encoderElapsed: Double
        var decodeElapsed: Double
        var meanTokenLogitMargin: Double
        var lowerDecileTokenLogitMargin: Double
        var meanDurationLogitMargin: Double
        var lowerDecileDurationLogitMargin: Double
        var blankDecisionRatio: Double
        var maximumFramesWithoutEmission: Int
        var minimumOverlapTokenAgreement: Double?
        var meanOverlapTokenAgreement: Double?
        var reusedEncoderChunks: Int = 0
    }

    static func run(
        chunks: [AudioSegment],
        featureExtractor: MelFeatureExtractor,
        runner: ModelRunner,
        sourceCompatibleFeatures: Bool = false,
        logitBias: ParakeetDecodingBias? = nil,
        contextualBias: ParakeetContextualBias? = nil,
        cancellationCheck: @escaping @Sendable () throws -> Void = {},
        encoderCache: EncoderResultCache? = nil,
        sessionID: UUID? = nil
    ) throws -> Result {
        try cancellationCheck()
        if chunks.isEmpty {
            return Result(
                tokens: [], frames: [], durations: [],
                tokenLogitMargins: [],
                chunkBoundaryFrames: [],
                melElapsed: 0, encoderElapsed: 0, decodeElapsed: 0,
                meanTokenLogitMargin: 0,
                lowerDecileTokenLogitMargin: 0,
                meanDurationLogitMargin: 0,
                lowerDecileDurationLogitMargin: 0,
                blankDecisionRatio: 0,
                maximumFramesWithoutEmission: 0,
                minimumOverlapTokenAgreement: nil,
                meanOverlapTokenAgreement: nil
            )
        }

        let melQueue = BlockingQueue<MelItem>(capacity: 2)
        let encQueue = BlockingQueue<EncoderItem>(
            capacity: max(2, runner.decoderWorkers.count + 1)
        )

        let globalError = ErrorSlot()
        let stages = DispatchGroup()
        let fail: @Sendable (Error) -> Void = { error in
            globalError.set(error)
            // Release blocked producers and consumers even when one stage
            // failed before consuming the other stage's last queued item.
            melQueue.close()
            encQueue.close()
        }

        // --- Stage 1: CPU mel extraction ---
        let melQ = DispatchQueue(label: "parakeet.mel", qos: .userInitiated)
        let melTotal = AtomicDouble()
        stages.enter()
        melQ.async {
            defer {
                melQueue.close()
                stages.leave()
            }
            do {
                for (i, chunk) in chunks.enumerated() {
                    try cancellationCheck()
                    if globalError.hasError { break }
                    let features: MelFeatureExtractor.Features?
                    if runner.encoderInputKind == .waveform {
                        features = nil
                    } else {
                        let t0 = Date()
                        features = featureExtractor.extract(
                            from: chunk.samples,
                            sourceCompatibleNormalization: sourceCompatibleFeatures
                        )
                        melTotal.add(Date().timeIntervalSince(t0))
                    }
                    try cancellationCheck()
                    melQueue.put(
                        MelItem(
                            index: i,
                            features: features,
                            samples: chunk.samples,
                            sampleCount: chunk.samples.count,
                            discardPrefixSamples: chunk.discardPrefixSamples
                        )
                    )
                }
            } catch {
                fail(error)
            }
        }

        // --- Stage 2: ANE / GPU / CPU encoder ---
        let encQ = DispatchQueue(label: "parakeet.encoder", qos: .userInitiated)
        let encTotal = AtomicDouble()
        let encReused = AtomicDouble()
        stages.enter()
        encQ.async {
            defer {
                encQueue.close()
                stages.leave()
            }
            while let mel = melQueue.take() {
                if globalError.hasError { break }
                do {
                    try cancellationCheck()
                    let t0 = Date()
                    let (hidden, mask): (MLMultiArray, MLMultiArray)
                    let cacheKey = encoderCache?.key(
                        samples: mel.samples,
                        sourceCompatibleFeatures: sourceCompatibleFeatures,
                        session: sessionID
                    )
                    if let cacheKey,
                        let cached = encoderCache?.value(for: cacheKey, session: sessionID)
                    {
                        (hidden, mask) = (cached.hidden, cached.mask)
                        encReused.add(1)
                    } else if let features = mel.features {
                        (hidden, mask) = try runner.runEncoder(
                            features: features.mel,
                            mask: features.attentionMask
                        )
                    } else {
                        (hidden, mask) = try runner.runEncoder(samples: mel.samples)
                    }
                    encTotal.add(Date().timeIntervalSince(t0))
                    try cancellationCheck()
                    if let cacheKey {
                        encoderCache?.store(
                            hidden: hidden, mask: mask, for: cacheKey, session: sessionID)
                    }
                    encQueue.put(
                        EncoderItem(
                            index: mel.index,
                            hidden: hidden,
                            mask: mask,
                            sampleCount: mel.sampleCount,
                            discardPrefixSamples: mel.discardPrefixSamples
                        )
                    )
                } catch {
                    fail(error)
                    break
                }
            }
        }

        // --- Stage 3: CPU decode worker pool ---
        let decodeQ = DispatchQueue(
            label: "parakeet.decode",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let group = DispatchGroup()
        let decodeTotal = AtomicDouble()
        let results = ChunkResultAccumulator()

        while let item = encQueue.take() {
            if globalError.hasError { break }
            do {
                try cancellationCheck()
            } catch {
                fail(error)
                break
            }
            guard let worker = runner.acquireWorker() else { break }

            group.enter()
            decodeQ.async {
                defer {
                    runner.releaseWorker(worker)
                    group.leave()
                }
                do {
                    let decoded = try autoreleasepool {
                        try GreedyTDTDecoder.decode(
                            encoderHidden: item.hidden,
                            encoderMask: item.mask,
                            worker: worker,
                            blankTokenId: runner.blankTokenId,
                            durations: runner.durations,
                            maxSymbolsPerStep: runner.maxSymbolsPerStep,
                            logitBias: logitBias
                                ?? GreedyTDTDecoder.environmentParakeetDecodingBias,
                            contextualBias: contextualBias,
                            cancellationCheck: cancellationCheck
                        )
                    }
                    let discardFrames = AudioSegmenter.discardPrefixFrameCount(
                        sampleCount: item.sampleCount,
                        discardPrefixSamples: item.discardPrefixSamples,
                        validFrameCount: decoded.validFrames
                    )
                    let firstKeptToken =
                        decoded.frameIndices.firstIndex { $0 >= discardFrames }
                        ?? decoded.tokenIds.endIndex
                    decodeTotal.add(decoded.elapsedSeconds)
                    results.set(
                        index: item.index,
                        chunk: ChunkResult(
                            tokenIds: Array(decoded.tokenIds[firstKeptToken...]),
                            frameIndices: decoded.frameIndices[firstKeptToken...].map {
                                $0 - discardFrames
                            },
                            durations: Array(decoded.durations[firstKeptToken...]),
                            tokenLogitMargins: Array(
                                decoded.tokenLogitMargins[firstKeptToken...]
                            ),
                            durationLogitMargins: decoded.durationLogitMargins,
                            blankDecisionCount: decoded.blankDecisionCount,
                            totalDecisionCount: decoded.totalDecisionCount,
                            maximumFramesWithoutEmission:
                                decoded.maximumFramesWithoutEmission,
                            timelineFrames: decoded.validFrames - discardFrames,
                            originalTokenIds: decoded.tokenIds,
                            originalFrameIndices: decoded.frameIndices,
                            validFrames: decoded.validFrames,
                            discardFrames: discardFrames
                        )
                    )
                } catch {
                    fail(error)
                }
            }
        }

        group.wait()
        melQueue.close()
        encQueue.close()
        // The transcriber owns reusable Core ML buffers. No upstream producer
        // may still be touching them when a cancelled partial returns.
        stages.wait()
        try cancellationCheck()

        if let err = globalError.error {
            throw err
        }

        // Reassemble tokens in chunk order -- the worker pool completes
        // chunks out of order.
        var tokens = [Int]()
        var frames = [Int]()
        var durations = [Int]()
        var tokenLogitMargins = [Float]()
        var chunkBoundaryFrames = [Int]()
        var durationLogitMargins = [Float]()
        var blankDecisionCount = 0
        var totalDecisionCount = 0
        var maximumFramesWithoutEmission = 0
        var overlapAgreements = [Double]()
        var totalFrameOffset = 0
        var previousChunk: ChunkResult?
        let orderedChunks = results.ordered(count: chunks.count)
        for (chunkIndex, chunk) in orderedChunks.enumerated() {
            if let previousChunk, chunk.discardFrames > 0 {
                let previousTailStart = max(
                    0,
                    previousChunk.validFrames - chunk.discardFrames
                )
                let previousTail = zip(
                    previousChunk.originalTokenIds,
                    previousChunk.originalFrameIndices
                ).compactMap { token, frame in
                    frame >= previousTailStart ? token : nil
                }
                let currentPrefix = zip(
                    chunk.originalTokenIds,
                    chunk.originalFrameIndices
                ).compactMap { token, frame in
                    frame < chunk.discardFrames ? token : nil
                }
                if !previousTail.isEmpty || !currentPrefix.isEmpty {
                    overlapAgreements.append(
                        tokenAgreement(previousTail, currentPrefix)
                    )
                }
            }
            tokens.append(contentsOf: chunk.tokenIds)
            frames.append(
                contentsOf: chunk.frameIndices.map { $0 + totalFrameOffset }
            )
            durations.append(contentsOf: chunk.durations)
            tokenLogitMargins.append(contentsOf: chunk.tokenLogitMargins)
            durationLogitMargins.append(contentsOf: chunk.durationLogitMargins)
            blankDecisionCount += chunk.blankDecisionCount
            totalDecisionCount += chunk.totalDecisionCount
            maximumFramesWithoutEmission = max(
                maximumFramesWithoutEmission,
                chunk.maximumFramesWithoutEmission
            )
            totalFrameOffset += chunk.timelineFrames
            if chunkIndex < orderedChunks.count - 1 {
                chunkBoundaryFrames.append(totalFrameOffset)
            }
            previousChunk = chunk
        }

        let sortedMargins = tokenLogitMargins.sorted()
        let meanTokenLogitMargin =
            sortedMargins.isEmpty
            ? 0
            : sortedMargins.reduce(0) { $0 + Double($1) }
                / Double(sortedMargins.count)
        let lowerDecileTokenLogitMargin =
            sortedMargins.isEmpty
            ? 0
            : Double(
                sortedMargins[
                    Int(Double(sortedMargins.count - 1) * 0.10)
                ]
            )
        let sortedDurationMargins = durationLogitMargins.sorted()
        let meanDurationLogitMargin =
            sortedDurationMargins.isEmpty
            ? 0
            : sortedDurationMargins.reduce(0) { $0 + Double($1) }
                / Double(sortedDurationMargins.count)
        let lowerDecileDurationLogitMargin =
            sortedDurationMargins.isEmpty
            ? 0
            : Double(
                sortedDurationMargins[
                    Int(Double(sortedDurationMargins.count - 1) * 0.10)
                ]
            )
        let blankDecisionRatio =
            totalDecisionCount > 0
            ? Double(blankDecisionCount) / Double(totalDecisionCount)
            : 0

        return Result(
            tokens: tokens,
            frames: frames,
            durations: durations,
            tokenLogitMargins: tokenLogitMargins,
            chunkBoundaryFrames: chunkBoundaryFrames,
            melElapsed: melTotal.value,
            encoderElapsed: encTotal.value,
            decodeElapsed: decodeTotal.value,
            meanTokenLogitMargin: meanTokenLogitMargin,
            lowerDecileTokenLogitMargin: lowerDecileTokenLogitMargin,
            meanDurationLogitMargin: meanDurationLogitMargin,
            lowerDecileDurationLogitMargin: lowerDecileDurationLogitMargin,
            blankDecisionRatio: blankDecisionRatio,
            maximumFramesWithoutEmission: maximumFramesWithoutEmission,
            minimumOverlapTokenAgreement: overlapAgreements.min(),
            meanOverlapTokenAgreement: overlapAgreements.isEmpty
                ? nil
                : overlapAgreements.reduce(0, +)
                    / Double(overlapAgreements.count),
            reusedEncoderChunks: Int(encReused.value)
        )
    }

    static func tokenAgreement(_ lhs: [Int], _ rhs: [Int]) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else {
            return 1
        }
        var previous = Array(0...rhs.count)
        for (lhsIndex, lhsToken) in lhs.enumerated() {
            var current = [lhsIndex + 1]
            current.reserveCapacity(rhs.count + 1)
            for (rhsIndex, rhsToken) in rhs.enumerated() {
                current.append(
                    min(
                        current[rhsIndex] + 1,
                        previous[rhsIndex + 1] + 1,
                        previous[rhsIndex] + (lhsToken == rhsToken ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return 1
            - Double(previous[rhs.count])
            / Double(max(lhs.count, rhs.count))
    }
}

// MARK: - Helpers

/// Exact, bounded encoder outputs for one recording. The decoder is deliberately
/// not cached: dictionary/language biases and confidence are always evaluated anew.
/// The owning runtime has one immutable model/compute configuration. Entries hold
/// the actual sample bytes (not approximate audio hashes) and are cleared on end.
final class EncoderResultCache: @unchecked Sendable {
    struct Key: Hashable {
        let sampleBytes: Data
        let sourceCompatibleFeatures: Bool
    }

    struct Value {
        let hidden: MLMultiArray
        let mask: MLMultiArray
        let chargedBytes: Int
    }

    private let lock = NSLock()
    private var sessionID: UUID?
    private var entries = [Key: Value]()
    private var insertionOrder = [Key]()
    private var retainedBytes = 0
    private let maximumEntries: Int
    private let maximumBytes: Int

    init(maximumEntries: Int = 16, maximumBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
    }

    var byteCount: Int { lock.withLock { retainedBytes } }

    func begin(_ id: UUID) {
        lock.withLock {
            guard sessionID != id else { return }
            entries.removeAll()
            insertionOrder.removeAll()
            retainedBytes = 0
            sessionID = id
        }
    }

    func end(_ id: UUID) {
        lock.withLock {
            guard sessionID == id else { return }
            entries.removeAll()
            insertionOrder.removeAll()
            retainedBytes = 0
            sessionID = nil
        }
    }

    func key(samples: [Float], sourceCompatibleFeatures: Bool, session id: UUID?) -> Key? {
        guard let id, lock.withLock({ sessionID == id }) else { return nil }
        return Key(
            sampleBytes: samples.withUnsafeBytes { Data($0) },
            sourceCompatibleFeatures: sourceCompatibleFeatures
        )
    }

    func value(for key: Key, session id: UUID?) -> Value? {
        lock.withLock {
            guard let id, sessionID == id else { return nil }
            guard let value = entries[key] else { return nil }
            if let index = insertionOrder.firstIndex(of: key) {
                let retainedKey = insertionOrder.remove(at: index)
                insertionOrder.append(retainedKey)
            }
            return value
        }
    }

    func store(hidden: MLMultiArray, mask: MLMultiArray, for key: Key, session id: UUID?) {
        lock.withLock {
            guard let id, sessionID == id, entries[key] == nil, maximumEntries > 0 else { return }
            // Eight bytes per element conservatively covers all supported
            // scalar storage types. Include input bytes and bookkeeping too.
            let bytes = key.sampleBytes.count + (hidden.count + mask.count) * 8 + 256
            guard bytes <= maximumBytes else { return }
            while entries.count >= maximumEntries || retainedBytes + bytes > maximumBytes {
                let oldest = insertionOrder.removeFirst()
                if let removed = entries.removeValue(forKey: oldest) {
                    retainedBytes -= removed.chargedBytes
                }
            }
            entries[key] = Value(hidden: hidden, mask: mask, chargedBytes: bytes)
            insertionOrder.append(key)
            retainedBytes += bytes
        }
    }
}

private struct MelItem {
    let index: Int
    let features: MelFeatureExtractor.Features?
    let samples: [Float]
    let sampleCount: Int
    let discardPrefixSamples: Int
}

private struct EncoderItem: @unchecked Sendable {
    let index: Int
    let hidden: MLMultiArray
    let mask: MLMultiArray
    let sampleCount: Int
    let discardPrefixSamples: Int
}

private struct ChunkResult {
    let tokenIds: [Int]
    let frameIndices: [Int]
    let durations: [Int]
    let tokenLogitMargins: [Float]
    let durationLogitMargins: [Float]
    let blankDecisionCount: Int
    let totalDecisionCount: Int
    let maximumFramesWithoutEmission: Int
    let timelineFrames: Int
    let originalTokenIds: [Int]
    let originalFrameIndices: [Int]
    let validFrames: Int
    let discardFrames: Int
}

/// Capacity-bounded MPSC blocking queue.
final class BlockingQueue<T>: @unchecked Sendable {
    private var buffer: [T] = []
    private var closed = false
    private let lock = NSLock()
    private let freeSlots: DispatchSemaphore
    private let itemsAvailable = DispatchSemaphore(value: 0)

    init(capacity: Int) {
        freeSlots = DispatchSemaphore(value: capacity)
    }

    func put(_ value: T) {
        freeSlots.wait()
        lock.lock()
        if closed {
            lock.unlock()
            freeSlots.signal()
            return
        }
        buffer.append(value)
        lock.unlock()
        itemsAvailable.signal()
    }

    func take() -> T? {
        itemsAvailable.wait()
        lock.lock()
        if buffer.isEmpty {
            lock.unlock()
            itemsAvailable.signal()
            return nil
        }
        let value = buffer.removeFirst()
        lock.unlock()
        freeSlots.signal()
        return value
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed {
            itemsAvailable.signal()
            freeSlots.signal()
        }
    }
}

/// Chunk results land out of order because the decode worker pool runs
/// multiple chunks concurrently. This collects them into a dict keyed on
/// chunk index and hands back an ordered sequence at the end.
private final class ChunkResultAccumulator: @unchecked Sendable {
    private var map: [Int: ChunkResult] = [:]
    private let lock = NSLock()

    func set(index: Int, chunk: ChunkResult) {
        lock.lock()
        map[index] = chunk
        lock.unlock()
    }

    func ordered(count: Int) -> [ChunkResult] {
        lock.lock(); defer { lock.unlock() }
        var out = [ChunkResult]()
        out.reserveCapacity(count)
        for i in 0..<count {
            if let r = map[i] { out.append(r) }
        }
        return out
    }
}

private final class ErrorSlot: @unchecked Sendable {
    private var _error: Error?
    private let lock = NSLock()

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return _error
    }
    var hasError: Bool {
        lock.lock(); defer { lock.unlock() }
        return _error != nil
    }
    func set(_ err: Error) {
        lock.lock(); defer { lock.unlock() }
        if _error == nil { _error = err }
    }
}

private final class AtomicDouble: @unchecked Sendable {
    private var _value: Double = 0
    private let lock = NSLock()
    var value: Double {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func add(_ d: Double) {
        lock.lock(); defer { lock.unlock() }
        _value += d
    }
}
