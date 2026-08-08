import Foundation

struct TDTDecision: Equatable {
    let tokenID: Int
    let duration: Int
}

struct TDTSyntheticDecodeResult: Equatable {
    let tokenIDs: [Int]
    let frameIndices: [Int]
    let durations: [Int]
    let consumedDecisionCount: Int
}

enum TDTDecodePolicy {
    struct Transition: Equatable {
        let emitsToken: Bool
        let frameAdvance: Int
    }

    struct PredictorStateUpdate: Equatable {
        let commitsCandidateState: Bool
        let invalidatesCachedPrediction: Bool
    }

    static func transition(
        tokenID: Int,
        blankTokenID: Int,
        duration: Int
    ) -> Transition {
        if tokenID == blankTokenID {
            return Transition(emitsToken: false, frameAdvance: max(duration, 1))
        }
        return Transition(emitsToken: true, frameAdvance: max(duration, 0))
    }

    /// NeMo commits the prediction-network state only after a lexical token.
    /// A blank advances acoustic time while reusing the same prediction output.
    static func predictorStateUpdate(
        for transition: Transition
    ) -> PredictorStateUpdate {
        PredictorStateUpdate(
            commitsCandidateState: transition.emitsToken,
            invalidatesCachedPrediction: transition.emitsToken
        )
    }

    /// Pure decode loop used to pin TDT cursor semantics without loading Core ML.
    static func decodeSynthetic(
        validFrameCount: Int,
        blankTokenID: Int,
        maxSymbolsPerStep: Int,
        decisions: [TDTDecision]
    ) -> TDTSyntheticDecodeResult {
        precondition(validFrameCount >= 0)
        precondition(maxSymbolsPerStep > 0)

        var tokenIDs = [Int]()
        var frameIndices = [Int]()
        var durations = [Int]()
        var decisionIndex = 0
        var frame = 0

        while frame < validFrameCount, decisionIndex < decisions.count {
            var symbols = 0
            var advanced = false
            while symbols < maxSymbolsPerStep, decisionIndex < decisions.count {
                let decision = decisions[decisionIndex]
                decisionIndex += 1
                let transition = transition(
                    tokenID: decision.tokenID,
                    blankTokenID: blankTokenID,
                    duration: decision.duration
                )

                if transition.emitsToken {
                    tokenIDs.append(decision.tokenID)
                    frameIndices.append(frame)
                    durations.append(decision.duration)
                    symbols += 1
                }
                if transition.frameAdvance > 0 {
                    frame += transition.frameAdvance
                    advanced = true
                    break
                }
            }
            if !advanced {
                frame += 1
            }
        }

        return TDTSyntheticDecodeResult(
            tokenIDs: tokenIDs,
            frameIndices: frameIndices,
            durations: durations,
            consumedDecisionCount: decisionIndex
        )
    }
}
