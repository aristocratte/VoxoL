/// Tracks only words repeated by consecutive partial hypotheses.
public struct StableTranscriptTracker: Equatable, Sendable {
    private var previousWords: [Substring] = []
    private var stableWords: [Substring] = []

    /// Creates an empty stable-prefix tracker.
    public init() {}

    /// Observes one replaceable hypothesis and returns its monotonic stable prefix.
    public mutating func observe(_ hypothesis: String) -> String {
        let words = hypothesis.split(whereSeparator: \Character.isWhitespace)
        guard !words.isEmpty else {
            previousWords = []
            return stableWords.joined(separator: " ")
        }

        if !previousWords.isEmpty {
            let commonCount = zip(previousWords, words).prefix { lhs, rhs in
                lhs.caseInsensitiveCompare(rhs) == .orderedSame
            }.count
            if commonCount > stableWords.count,
                words.prefix(stableWords.count).elementsEqual(
                    stableWords,
                    by: { $0.caseInsensitiveCompare($1) == .orderedSame }
                )
            {
                stableWords = Array(words.prefix(commonCount))
            }
        }
        previousWords = words
        return stableWords.joined(separator: " ")
    }

    /// Clears both the previous hypothesis and committed prefix.
    public mutating func reset() {
        previousWords = []
        stableWords = []
    }
}
