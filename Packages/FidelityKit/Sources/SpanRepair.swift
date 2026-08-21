import Foundation
import TextProcessingKit

/// Salvages a rejected cleanup by reverting only the sentences that broke it.
///
/// The validator used to be all-or-nothing: a candidate that improved nine
/// sentences and damaged one was discarded whole, and the user got the raw
/// deterministic text — nine good edits paid for one bad span. Observed live:
/// the model's best rewrite of a long dictation died because a single clause
/// dropped a protected negation.
///
/// The repair aligns candidate sentences to source sentences, validates each
/// pair under the same per-word rules as the whole-text check, and rebuilds
/// the output keeping accepted sentences and restoring rejected ones from the
/// source. The rebuilt text then goes through the full validator again — the
/// repair proposes, the original rules still dispose.
public enum SpanRepair {
    /// Words whose loss or alteration flips meaning: quantifiers, modality,
    /// conditions, exceptions, comparatives — plus the negations the token
    /// layer already guards, doubled here as defence in depth.
    ///
    /// Membership does two things, both restrictive: a critical word can never
    /// satisfy the validator through a "minor correction" (it must survive
    /// exactly), and a sentence whose source contains one is only kept if the
    /// candidate preserves it verbatim. Common words like "tout" or "si"
    /// belong here precisely because they are common: their deletion was
    /// already forbidden, this closes the sideways paths.
    public static func criticalWords(for language: TextLanguage) -> Set<String> {
        switch language {
        case .french:
            [
                // Négations et exclusions.
                "non", "ne", "pas", "ni", "jamais", "aucun", "aucune", "sans",
                // Quantificateurs.
                "tous", "toutes", "tout", "toute", "chaque", "seulement",
                "uniquement", "moins", "plus",
                // Modalité et obligation.
                "doit", "doivent", "peut", "peuvent", "devrait", "devraient",
                "faut", "faudrait", "obligatoire", "interdit",
                // Conditions et exceptions.
                "si", "sinon", "sauf",
                // Relations temporelles et comparatives.
                "avant", "apres",
            ]
        case .english:
            [
                "no", "not", "never", "none", "neither", "nor", "without",
                "all", "every", "each", "only", "any",
                "must", "should", "may", "might", "can", "cannot", "shall",
                "if", "unless", "except", "otherwise",
                "before", "after", "more", "less", "least", "most",
            ]
        }
    }

    /// One aligned pair of sentence groups.
    struct AlignedPair {
        let source: String
        let candidate: String
    }

    /// Splits text into sentences, keeping terminal punctuation attached.
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?…".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            result.append(tail)
        }
        return result
    }

    /// Monotonic alignment allowing one-to-one, merge (two source sentences
    /// into one candidate) and split (one source into two candidates).
    ///
    /// Wider windows would align garbage confidently; a candidate that departs
    /// further than a merge or a split from the source's sentence structure is
    /// beyond sentence-level repair and falls back whole.
    static func align(source: [String], candidate: [String]) -> [AlignedPair]? {
        guard !source.isEmpty, !candidate.isEmpty else { return nil }
        let infinity = Double.greatestFiniteMagnitude
        var cost = [[Double]](
            repeating: [Double](repeating: infinity, count: candidate.count + 1),
            count: source.count + 1
        )
        var back = [[(Int, Int)]](
            repeating: [(Int, Int)](repeating: (0, 0), count: candidate.count + 1),
            count: source.count + 1
        )
        cost[0][0] = 0
        for i in 0...source.count {
            for j in 0...candidate.count where cost[i][j] < infinity {
                for (di, dj) in [(1, 1), (2, 1), (1, 2)] {
                    let ni = i + di
                    let nj = j + dj
                    guard ni <= source.count, nj <= candidate.count else { continue }
                    let sourceText = source[i..<ni].joined(separator: " ")
                    let candidateText = candidate[j..<nj].joined(separator: " ")
                    let pairCost = normalizedDistance(sourceText, candidateText)
                    if cost[i][j] + pairCost < cost[ni][nj] {
                        cost[ni][nj] = cost[i][j] + pairCost
                        back[ni][nj] = (di, dj)
                    }
                }
            }
        }
        guard cost[source.count][candidate.count] < infinity else { return nil }

        var pairs: [AlignedPair] = []
        var i = source.count
        var j = candidate.count
        while i > 0 || j > 0 {
            let (di, dj) = back[i][j]
            guard di > 0 || dj > 0 else { return nil }
            pairs.append(
                AlignedPair(
                    source: source[(i - di)..<i].joined(separator: " "),
                    candidate: candidate[(j - dj)..<j].joined(separator: " ")
                )
            )
            i -= di
            j -= dj
        }
        return pairs.reversed()
    }

    static func normalizedDistance(_ left: String, _ right: String) -> Double {
        let a = Array(left.lowercased())
        let b = Array(right.lowercased())
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var current = [i]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                current.append(
                    min(
                        previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
                        previous[j] + 1,
                        current[j - 1] + 1
                    )
                )
            }
            if b.isEmpty { current = [i] }
            previous = current
        }
        return Double(previous.last ?? max(a.count, b.count))
            / Double(max(a.count, b.count, 1))
    }
}
