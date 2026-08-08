import Foundation

/// Proposes dictionary repairs without applying any of them.
///
/// Measurement said an open-ended model cannot do this job: given the sentence
/// with uncertain words marked, a 0.8B and a 7B model both produced **zero**
/// repairs and broke words instead, because the flagged-and-genuinely-wrong
/// words were overwhelmingly proper nouns that no context can recover.
///
/// It also said the localiser is weaker than it first appeared. Per-word
/// confidence separates right from wrong — median margin 7.01 against 0.89 —
/// but at a useful recall the precision is only 23%. Three flagged words in four
/// are already correct, so anything that rewrites them automatically has three
/// chances to break for every one to fix.
///
/// Hence shadow mode. This records what a repair pass *would* do, next to what
/// the recogniser produced, and applies nothing. Real dictation accumulates the
/// evidence needed to decide whether the substitution rate is ever safe enough
/// to enable — evidence no public corpus can supply, because the vocabulary
/// that matters is the speaker's own.
///
/// Candidates come from the user's dictionary rather than from a model's
/// imagination. That bounds the damage a wrong answer can do, but it does not
/// eliminate it: picking a known term the speaker never said is still an error,
/// which is exactly what this is here to count.
public enum RepairShadow {
    /// One proposal, with everything needed to judge it after the fact.
    public struct Proposal: Codable, Equatable, Sendable {
        /// Word as the recogniser produced it.
        public let heard: String
        /// Dictionary term proposed in its place.
        public let candidate: String
        /// Position among the transcript's words, so the log can be replayed.
        public let index: Int
        /// The recogniser's confidence in the word it produced.
        public let margin: Float
        /// Edit distance between the two, normalised by the candidate's length.
        public let distance: Double

        public init(
            heard: String,
            candidate: String,
            index: Int,
            margin: Float,
            distance: Double
        ) {
            self.heard = heard
            self.candidate = candidate
            self.index = index
            self.margin = margin
            self.distance = distance
        }
    }

    /// Words above this margin are left alone: the recogniser was sure, and
    /// measurement puts its accuracy there above 94%.
    public static let defaultMarginThreshold: Float = 2.4

    /// A candidate further than this from what was heard is a different word,
    /// not a correction of it. Without the bound, every short dictionary term
    /// matches every short mistake.
    public static let defaultDistanceThreshold = 0.45

    /// Proposals a repair pass would make for this transcript.
    ///
    /// Nothing here mutates the transcript. The caller logs the result; the
    /// decision to ever act on it is a separate one, gated on the false
    /// substitution rate these logs are collected to measure.
    public static func proposals(
        words: [(word: String, margin: Float)],
        dictionary: [String],
        marginThreshold: Float = defaultMarginThreshold,
        distanceThreshold: Double = defaultDistanceThreshold
    ) -> [Proposal] {
        guard !dictionary.isEmpty else { return [] }
        var result = [Proposal]()
        for (index, entry) in words.enumerated() {
            guard entry.margin <= marginThreshold else { continue }
            let heard = folded(entry.word)
            guard !heard.isEmpty else { continue }

            // A word that already spells a dictionary term needs no repair —
            // except for its accents and casing, where the canonical form is
            // the one the owner wrote down.
            if let canonical = dictionary.first(where: { folded($0) == heard }) {
                if canonical != entry.word {
                    result.append(
                        Proposal(
                            heard: entry.word,
                            candidate: canonical,
                            index: index,
                            margin: entry.margin,
                            distance: 0
                        )
                    )
                }
                continue
            }

            var best: (term: String, distance: Double)?
            for term in dictionary {
                let candidate = folded(term)
                guard !candidate.isEmpty, candidate != heard else { continue }
                // Short words are the trap: two edits on three letters is
                // proportionally huge but textually cheap, so `le` would match
                // `de` and every function word would become a dictionary term.
                // Requiring a shared first letter costs the rescues that a
                // text-only distance was never able to make safely — `Ro` for
                // `raw` needs acoustic evidence, not spelling.
                guard candidate.first == heard.first else { continue }
                let distance = Double(editDistance(heard, candidate))
                    / Double(max(candidate.count, 1))
                guard distance <= distanceThreshold else { continue }
                if best == nil || distance < best!.distance {
                    best = (term, distance)
                }
            }
            guard let best else { continue }
            result.append(
                Proposal(
                    heard: entry.word,
                    candidate: best.term,
                    index: index,
                    margin: entry.margin,
                    distance: best.distance
                )
            )
        }
        return result
    }

    /// Lowercased and stripped of accents and punctuation, so `Élite` and
    /// `elite.` compare as the same string.
    static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func editDistance(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
                    previous[j] + 1,
                    current[j - 1] + 1
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
