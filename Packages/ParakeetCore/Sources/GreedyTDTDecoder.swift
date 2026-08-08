// Adapted for VoxoL from parakeet-coreml-swift commit 75aec2a1c991319657ff4dec5f602c12da6c5012.
// Changes are documented in Packages/ParakeetCore/NOTICE.md.
import Accelerate
import CoreML
import Foundation

/// Greedy TDT (Token-and-Duration Transducer) decoder.
///
/// Mirrors NeMo's greedy TDT state semantics:
///   - Maintain committed LSTM state plus a candidate state for the current
///     prediction-network step.
///   - For each encoder frame ``t``:
///     - Call decoder once for the current last token, then reuse that output
///       across blank decisions without committing its candidate LSTM state.
///     - Call joint(encoder[t], decoder_state).
///     - Argmax over token logits; argmax over duration logits.
///     - If token is blank: advance ``t`` by ``max(duration, 1)``.
///     - Otherwise: emit token, advance ``t`` by ``duration`` if > 0, else
///       keep ``t`` and try again (capped by ``maxSymbolsPerStep``).
enum GreedyTDTDecoder {

    struct Output {
        let tokenIds: [Int]
        let frameIndices: [Int]
        let durations: [Int]
        let validFrames: Int
        let tokenLogitMargins: [Float]
        let durationLogitMargins: [Float]
        let blankDecisionCount: Int
        let totalDecisionCount: Int
        let maximumFramesWithoutEmission: Int
        let parityDecisions: [ParakeetParityDecision]
        /// Wall-clock time spent inside ``runner.runDecoderStep()`` +
        /// ``runner.runJoint()`` plus the argmax + state copies.
        let elapsedSeconds: Double
    }

    static func decode(
        encoderHidden: MLMultiArray,
        encoderMask: MLMultiArray,
        worker: DecoderWorker,
        blankTokenId: Int,
        durations: [Int],
        maxSymbolsPerStep: Int,
        captureParityTrace: Bool = false,
        primingTokenId: Int? = nil,
        logitBias: ParakeetDecodingBias? = nil,
        contextualBias: ParakeetContextualBias? = nil
    ) throws -> Output {
        guard encoderHidden.shape.count == 3 else {
            throw ParakeetError.unexpectedOutputShape(
                name: "encoder_hidden",
                got: encoderHidden.shape.map(\.intValue),
                expected: "[1, T, hidden]"
            )
        }
        let hiddenSize = encoderHidden.shape[2].intValue
        let tMax = encoderHidden.shape[1].intValue

        let maskPtr = encoderMask.dataPointer.bindMemory(
            to: Int32.self, capacity: encoderMask.count
        )
        guard let maskLength = encoderMask.shape.last?.intValue else {
            throw ParakeetError.unexpectedOutputShape(
                name: "encoder_mask",
                got: encoderMask.shape.map(\.intValue),
                expected: "[1, T]"
            )
        }
        var validFrames = 0
        for i in 0..<maskLength {
            validFrames += Int(maskPtr[i])
        }
        validFrames = min(validFrames, tMax)

        let blank = blankTokenId
        let maxSym = maxSymbolsPerStep

        // Persistent buffers owned by the worker. Zero hidden/cell for a
        // fresh utterance; input_ids starts at blank.
        let hidden = worker.hidden
        let cell = worker.cell
        let candidateHidden = worker.candidateHidden
        let candidateCell = worker.candidateCell
        let inputIds = worker.inputIds
        let jointEncFrame = worker.encoderFrame
        let jointDecState = worker.decoderState
        zero(hidden)
        zero(cell)
        zero(candidateHidden)
        zero(candidateCell)
        let idsPtr = inputIds.dataPointer
            .bindMemory(to: Int32.self, capacity: 1)
        // A fresh utterance starts from blank as its start-of-sequence.
        //
        // Seeding a language token instead looks tempting: the v3 vocabulary
        // carries the multilingual control tokens (``<|fr|>`` is 71, ``<|en|>``
        // is 64), they sit inside the joint's 8,193-wide output, and the app
        // already knows which language the user picked — so priming would seem
        // to fix the English words this model sometimes emits mid-French.
        // It does not. Measured on MediaSpeech FR (2,498 clips) on 2026-08-05,
        // priming ``<|fr|>`` moved word error from 20.16% to 24.14%. The TDT
        // predictor was never trained with those tokens as targets, so seeding
        // one starts the sequence off-distribution. Fixing the language drift
        // needs training signal, not a decoding trick.
        idsPtr[0] = Int32(primingTokenId ?? blank)

        let encFramePtr = jointEncFrame.dataPointer
            .bindMemory(to: Float32.self, capacity: hiddenSize)
        let decStatePtr = jointDecState.dataPointer
            .bindMemory(to: Float32.self, capacity: hiddenSize)
        let encHiddenPtr = encoderHidden.dataPointer
            .bindMemory(to: Float32.self, capacity: encoderHidden.count)

        var tokens = [Int]()
        var frameIdx = [Int]()
        var durationOut = [Int]()
        var tokenLogitMargins = [Float]()
        var durationLogitMargins = [Float]()
        var blankDecisionCount = 0
        var totalDecisionCount = 0
        var maximumFramesWithoutEmission = 0
        var lastEmissionFrame = 0
        var parityDecisions = [ParakeetParityDecision]()

        /// True once ``decoder_state`` and the candidate LSTM state represent
        /// the committed state plus ``input_ids``. A lexical emission commits
        /// the candidate and invalidates this prediction; a blank reuses it.
        var decoderStateValid = false
        // Tracks how far the decoder is into each vocabulary term, so a
        // subword is boosted only where it continues one.
        var contextState = contextualBias?.initialState()

        let start = Date()
        var t = 0
        while t < validFrames {
            // Copy encoder_hidden[0, t, :] into the joint's encoder_frame.
            memcpy(
                encFramePtr,
                encHiddenPtr.advanced(by: t * hiddenSize),
                hiddenSize * MemoryLayout<Float32>.size
            )

            var symbols = 0
            var advanced = false
            while symbols < maxSym {
                if !decoderStateValid {
                    // Scoped so the prediction output (IOSurface-backed on
                    // ANE / GPU) is released before the next iteration.
                    try autoreleasepool {
                        let out = try worker.runDecoderStep()
                        let decShape = out.decoderHidden.shape.map(\.intValue)
                        let decU =
                            decShape.count >= 3
                            ? decShape[decShape.count - 2] : 1
                        let lastT = decU - 1
                        let outPtr = out.decoderHidden.dataPointer.bindMemory(
                            to: Float32.self, capacity: out.decoderHidden.count
                        )
                        memcpy(
                            decStatePtr,
                            outPtr.advanced(by: lastT * hiddenSize),
                            hiddenSize * MemoryLayout<Float32>.size
                        )
                        copyMultiArray(from: out.nextHidden, to: candidateHidden)
                        copyMultiArray(from: out.nextCell, to: candidateCell)
                    }
                    decoderStateValid = true
                }

                // Joint: also autoreleasepool'd so the IOSurface output is
                // returned to the pool before we loop.
                let (
                    tokenId,
                    tokenMargin,
                    durIdx,
                    durationMargin,
                    tokenTopCandidates,
                    durationTopCandidates
                ):
                    (
                        Int,
                        Float?,
                        Int,
                        Float,
                        [ParakeetLogitCandidate],
                        [ParakeetLogitCandidate]
                    ) =
                        try autoreleasepool {
                            let jointOut = try worker.runJoint()
                            let tokenId = argmax(
                                jointOut.tokenLogits,
                                biasedBy: mergedBias(
                                    logitBias,
                                    contextualBias,
                                    contextState
                                )
                            )
                            let durationIndex = argmax(jointOut.durationLogits)
                            return (
                                tokenId,
                                tokenId == blank
                                    ? nil
                                    : logitMargin(
                                        jointOut.tokenLogits,
                                        winnerIndex: tokenId
                                    ),
                                durationIndex,
                                logitMargin(
                                    jointOut.durationLogits,
                                    winnerIndex: durationIndex
                                ),
                                captureParityTrace
                                    ? topCandidates(jointOut.tokenLogits, count: 3) : [],
                                captureParityTrace
                                    ? topCandidates(jointOut.durationLogits, count: 3) : []
                            )
                        }
                let duration = durations[durIdx]
                let transition = TDTDecodePolicy.transition(
                    tokenID: tokenId,
                    blankTokenID: blank,
                    duration: duration
                )
                let predictorUpdate = TDTDecodePolicy.predictorStateUpdate(
                    for: transition
                )
                totalDecisionCount += 1
                durationLogitMargins.append(durationMargin)
                if captureParityTrace {
                    parityDecisions.append(
                        ParakeetParityDecision(
                            frameIndex: t,
                            selectedTokenID: tokenId,
                            selectedDurationIndex: durIdx,
                            selectedDurationFrames: duration,
                            emittedToken: transition.emitsToken,
                            tokenTopCandidates: tokenTopCandidates,
                            durationTopCandidates: durationTopCandidates
                        )
                    )
                }

                if !transition.emitsToken {
                    blankDecisionCount += 1
                    t += transition.frameAdvance
                    advanced = true
                    break
                }

                maximumFramesWithoutEmission = max(
                    maximumFramesWithoutEmission,
                    t - lastEmissionFrame
                )
                lastEmissionFrame = t
                tokens.append(tokenId)
                if let contextualBias, let state = contextState {
                    contextState = contextualBias.advanced(state, emitting: tokenId)
                }
                frameIdx.append(t)
                durationOut.append(duration)
                tokenLogitMargins.append(tokenMargin ?? 0)
                if predictorUpdate.commitsCandidateState {
                    copyMultiArray(from: candidateHidden, to: hidden)
                    copyMultiArray(from: candidateCell, to: cell)
                }
                idsPtr[0] = Int32(tokenId)
                if predictorUpdate.invalidatesCachedPrediction {
                    decoderStateValid = false
                }
                symbols += 1
                if transition.frameAdvance > 0 {
                    t += transition.frameAdvance
                    advanced = true
                    break
                }
            }
            if !advanced { t += 1 }
        }
        maximumFramesWithoutEmission = max(
            maximumFramesWithoutEmission,
            validFrames - lastEmissionFrame
        )
        let elapsed = Date().timeIntervalSince(start)

        return Output(
            tokenIds: tokens,
            frameIndices: frameIdx,
            durations: durationOut,
            validFrames: validFrames,
            tokenLogitMargins: tokenLogitMargins,
            durationLogitMargins: durationLogitMargins,
            blankDecisionCount: blankDecisionCount,
            totalDecisionCount: totalDecisionCount,
            maximumFramesWithoutEmission: maximumFramesWithoutEmission,
            parityDecisions: parityDecisions,
            elapsedSeconds: elapsed
        )
    }

    // MARK: - helpers

    @inline(__always)
    static func zero(_ arr: MLMultiArray) {
        let count = arr.count
        memset(arr.dataPointer, 0, count * MemoryLayout<Float32>.size)
    }

    @inline(__always)
    static func copyMultiArray(from src: MLMultiArray, to dst: MLMultiArray) {
        let bytes = min(src.count, dst.count) * MemoryLayout<Float32>.size
        memcpy(dst.dataPointer, src.dataPointer, bytes)
    }

    @inline(__always)
    /// Argmax over token logits after discouraging out-of-language tokens.
    ///
    /// This model picks its language per utterance, and on French audio it
    /// sometimes emits English function words mid-sentence — 312 of 5,738
    /// French chunks in the 2026-08-03 corpus, 3,296 parasitic words. Those
    /// chunks already carry the correct French target in training, so the model
    /// has the answer and does not apply it; and seeding a `<|fr|>` control
    /// token makes it worse, because the predictor never saw those as targets.
    ///
    /// What does work is refusing the drift at selection time. The penalty is
    /// subtracted rather than the token masked: these words do occur in real
    /// French speech when someone quotes or code-switches, so a strong enough
    /// acoustic signal must still win.
    /// Combines the static bias with the vocabulary trie's current offsets.
    ///
    /// Returns the static bias untouched when no vocabulary is active, so the
    /// ordinary path allocates nothing.
    static func mergedBias(
        _ base: ParakeetDecodingBias?,
        _ contextual: ParakeetContextualBias?,
        _ state: ParakeetContextualBias.State?
    ) -> ParakeetDecodingBias? {
        guard
            let contextual,
            let state,
            let offsets = contextual.offsets(for: state)
        else { return base }
        let dynamic = ParakeetDecodingBias(offsets: offsets)
        guard let base, !base.isEmpty else { return dynamic }
        return base.merging(dynamic)
    }

    static func argmax(
        _ array: MLMultiArray,
        biasedBy bias: ParakeetDecodingBias?
    ) -> Int {
        guard let bias, !bias.isEmpty else {
            return argmax(array)
        }
        let pointer = array.dataPointer.bindMemory(
            to: Float32.self,
            capacity: array.count
        )
        // Scanning the whole row rather than adjusting only the biased ids
        // keeps the winner correct: a penalised token may still be the argmax,
        // and a boosted one only wins if it beats every untouched competitor.
        var best = 0
        var bestValue = -Float.infinity
        for index in 0..<array.count {
            let value = pointer[index] + (bias.offsets[index] ?? 0)
            if value > bestValue {
                bestValue = value
                best = index
            }
        }
        return best
    }

    /// Benchmark-only override, so the suite can sweep the magnitude without
    /// the product path depending on an environment variable.
    static let environmentParakeetDecodingBias: ParakeetDecodingBias? = {
        let environment = ProcessInfo.processInfo.environment
        guard
            let path = environment["VOXOL_LANGUAGE_PENALTY_JSON"],
            let amountText = environment["VOXOL_LANGUAGE_PENALTY_AMOUNT"],
            let amount = Float(amountText),
            amount > 0,
            let data = FileManager.default.contents(atPath: path),
            let payload = try? JSONSerialization.jsonObject(with: data),
            let object = payload as? [String: Any],
            let ids = object["french_suppressed_token_ids"] as? [Int],
            !ids.isEmpty
        else {
            return nil
        }
        return .discouraging(ids, by: amount)
    }()

    static func argmax(_ array: MLMultiArray) -> Int {
        let n = vDSP_Length(array.count)
        let ptr = UnsafePointer<Float32>(OpaquePointer(array.dataPointer))
        var maxVal: Float = 0
        var idx: vDSP_Length = 0
        vDSP_maxvi(ptr, 1, &maxVal, &idx, n)
        return Int(idx)
    }

    @inline(__always)
    static func logitMargin(
        _ array: MLMultiArray,
        winnerIndex: Int
    ) -> Float {
        let pointer = array.dataPointer.bindMemory(
            to: Float32.self,
            capacity: array.count
        )
        let winner = pointer[winnerIndex]
        var runnerUp = -Float.infinity
        for index in 0..<array.count where index != winnerIndex {
            runnerUp = max(runnerUp, pointer[index])
        }
        return max(0, winner - runnerUp)
    }

    static func topCandidates(
        _ array: MLMultiArray,
        count: Int
    ) -> [ParakeetLogitCandidate] {
        let pointer = array.dataPointer.bindMemory(
            to: Float32.self,
            capacity: array.count
        )
        var candidates = [ParakeetLogitCandidate]()
        candidates.reserveCapacity(min(count, array.count))
        for index in 0..<array.count {
            let candidate = ParakeetLogitCandidate(index: index, logit: pointer[index])
            let insertionIndex =
                candidates.firstIndex { candidate.logit > $0.logit }
                ?? candidates.endIndex
            if insertionIndex < count {
                candidates.insert(candidate, at: insertionIndex)
                if candidates.count > count {
                    candidates.removeLast()
                }
            }
        }
        return candidates
    }
}
