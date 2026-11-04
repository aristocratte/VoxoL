/// Align a chunk seam on a unique, temporally consistent exact token anchor.
/// No text heuristics, fuzzy matching, or vocabulary-specific replacements.
enum TokenSeamAlignment {
    struct Cut: Equatable {
        let previousEnd: Int
        let currentStart: Int
    }

    private struct Candidate {
        let cut: Cut
        let anchor: [Int]
        let distanceFromMidpoint: Int
        let timingError: Int
    }

    static func select(
        previousTokens: [Int], previousFrames: [Int], previousValidFrames: Int,
        minimumPreviousIndex: Int, currentTokens: [Int], currentFrames: [Int],
        overlapFrames: Int
    ) -> Cut? {
        let anchorLength = 4
        guard previousTokens.count == previousFrames.count,
            currentTokens.count == currentFrames.count,
            previousTokens.count >= anchorLength, currentTokens.count >= anchorLength,
            overlapFrames > 0, previousValidFrames >= overlapFrames,
            minimumPreviousIndex >= 0
        else { return nil }
        let origin = previousValidFrames - overlapFrames
        var candidates: [Candidate] = []
        for left in 0...(previousTokens.count - anchorLength) {
            guard left >= minimumPreviousIndex, previousFrames[left] >= origin else { continue }
            let anchor = Array(previousTokens[left..<(left + anchorLength)])
            for right in 0...(currentTokens.count - anchorLength) {
                guard currentFrames[right + anchorLength - 1] < overlapFrames,
                    anchor.elementsEqual(currentTokens[right..<(right + anchorLength)])
                else { continue }
                let timingErrors = (0..<anchorLength).map {
                    abs(previousFrames[left + $0] - (origin + currentFrames[right + $0]))
                }
                guard timingErrors.allSatisfy({ $0 <= 3 }),
                    left == 0 || previousFrames[left - 1] <= origin + currentFrames[right]
                else { continue }
                candidates.append(
                    Candidate(
                        cut: Cut(previousEnd: left, currentStart: right), anchor: anchor,
                        distanceFromMidpoint: abs(2 * currentFrames[right] - overlapFrames),
                        timingError: timingErrors.reduce(0, +)
                    ))
            }
        }
        // Repeated phrases must not be collapsed just because their tokens match.
        let unique = candidates.filter { candidate in
            candidates.filter { $0.anchor == candidate.anchor }.count == 1
        }
        return unique.min {
            if $0.distanceFromMidpoint != $1.distanceFromMidpoint {
                return $0.distanceFromMidpoint < $1.distanceFromMidpoint
            }
            return $0.timingError < $1.timingError
        }?.cut
    }
}
