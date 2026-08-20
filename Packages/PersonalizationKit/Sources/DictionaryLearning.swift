import Foundation

/// Turns the corrections someone actually made into dictionary entries.
///
/// The corrections were already being stored, and a script could read them, but
/// nothing in the app ever acted on them: a word the recogniser got wrong every
/// single time had to be typed into the dictionary by hand or it stayed wrong
/// forever. This closes that loop — correct a word twice and it stops coming
/// back — which is the behaviour people expect from dictation that "learns".
///
/// Two guards keep it from filling the dictionary with damage, because every
/// entry it creates rewrites all later dictations:
///
/// - a pair has to show up in at least two separate corrections, so a typo or a
///   changed mind never becomes a permanent rule;
/// - the two words have to be close enough to be a mishearing rather than an
///   edit. Rewriting `budget` to `planning` is someone changing their text, and
///   promoting that would corrupt every dictation that ever says "budget".
public enum DictionaryLearning {
    /// How many distinct corrections must agree before a pair is promoted.
    public static let requiredOccurrences = 2

    /// The largest normalised edit distance still treated as a mishearing.
    public static let maximumDistance = 0.5

    /// Derives entries that are not in `existing` yet.
    public static func suggestions(
        from corrections: [CorrectionPair],
        existing: [DictionaryEntry]
    ) -> [DictionaryEntry] {
        entries(from: corrections, existing: existing, occurrences: requiredOccurrences...)
    }

    /// Candidates seen exactly once — enough to propose, not enough to act.
    ///
    /// The two-occurrence rule protects the dictionary from typos and changed
    /// minds, but it also means the first correction does nothing visible,
    /// which reads as the app not learning. These are shown to the user with
    /// an add button: one click supplies the confidence a second occurrence
    /// would have.
    public static func pendingSuggestions(
        from corrections: [CorrectionPair],
        existing: [DictionaryEntry]
    ) -> [DictionaryEntry] {
        entries(from: corrections, existing: existing, occurrences: 1..<requiredOccurrences)
    }

    /// A stable identity for ignoring a suggestion without storing the entry.
    public static func suggestionKey(_ entry: DictionaryEntry) -> String {
        fold(entry.spokenForms.first ?? "") + "→" + fold(entry.canonical)
    }

    private static func entries(
        from corrections: [CorrectionPair],
        existing: [DictionaryEntry],
        occurrences occurrenceRange: some RangeExpression<Int>
    ) -> [DictionaryEntry] {
        var occurrences: [Pair: Int] = [:]
        var surfaces: [Pair: (heard: String, meant: String)] = [:]
        var languages: [Pair: PersonalizationLanguage] = [:]

        for correction in corrections {
            let heardWords = words(correction.rawTranscript)
            let meantWords = words(correction.correctedText)
            guard !heardWords.isEmpty, !meantWords.isEmpty else { continue }
            // A correction is counted once per distinct pair: repeating the same
            // word twice in one sentence is one piece of evidence, not two.
            var seen: Set<Pair> = []
            for (heard, meant) in substitutions(heardWords, meantWords)
                + splits(heardWords, meantWords)
            {
                let key = Pair(heard: fold(heard), meant: fold(meant))
                guard !key.heard.isEmpty, !key.meant.isEmpty, key.heard != key.meant else {
                    continue
                }
                guard seen.insert(key).inserted else { continue }
                occurrences[key, default: 0] += 1
                if surfaces[key] == nil {
                    surfaces[key] = (heard, meant)
                    languages[key] = correction.language
                }
            }
        }

        let known = Set(
            existing.flatMap { entry in
                entry.spokenForms.map { Pair(heard: fold($0), meant: fold(entry.canonical)) }
            }
        )

        return
            occurrences
            .filter { occurrenceRange.contains($0.value) && !known.contains($0.key) }
            .compactMap { key, _ -> DictionaryEntry? in
                guard let surface = surfaces[key] else { return nil }
                // Spaces are exactly what a split error adds, so they are
                // ignored when measuring: `chip set` against `chipset` is a
                // distance of zero, not of one.
                let heard = key.heard.replacingOccurrences(of: " ", with: "")
                let meant = key.meant.replacingOccurrences(of: " ", with: "")
                let normalised = Double(distance(heard, meant)) / Double(max(meant.count, 1))
                guard normalised <= maximumDistance else { return nil }
                return DictionaryEntry(
                    canonical: surface.meant,
                    spokenForms: [surface.heard],
                    language: languages[key] ?? .any,
                    origin: .learned
                )
            }
            .sorted { $0.canonical < $1.canonical }
    }
}

extension DictionaryLearning {
    struct Pair: Hashable {
        let heard: String
        let meant: String
    }

    static func words(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }
            .map(String.init)
    }

    /// Case- and accent-insensitive, so one mistake does not split into several
    /// near-identical candidates.
    static func fold(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    static func distance(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i]
            for j in 1...b.count {
                current.append(
                    min(
                        previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
                        previous[j] + 1,
                        current[j - 1] + 1
                    )
                )
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Word-for-word replacements only.
    ///
    /// Insertions and deletions are dropped on purpose: adding or removing a
    /// word is someone editing their text, and only a one-for-one swap is
    /// evidence that the recogniser heard the wrong thing.
    static func substitutions(_ source: [String], _ target: [String]) -> [(String, String)] {
        let rows = source.count + 1
        let columns = target.count + 1
        var cost = Array(repeating: Array(repeating: 0, count: columns), count: rows)
        for i in 0..<rows { cost[i][0] = i }
        for j in 0..<columns { cost[0][j] = j }
        for i in 1..<rows {
            for j in 1..<columns {
                let swap = fold(source[i - 1]) == fold(target[j - 1]) ? 0 : 1
                cost[i][j] = min(
                    cost[i - 1][j - 1] + swap,
                    cost[i - 1][j] + 1,
                    cost[i][j - 1] + 1
                )
            }
        }

        var pairs: [(String, String)] = []
        var i = source.count
        var j = target.count
        while i > 0, j > 0 {
            let swap = fold(source[i - 1]) == fold(target[j - 1]) ? 0 : 1
            if cost[i][j] == cost[i - 1][j - 1] + swap {
                if swap == 1 { pairs.append((source[i - 1], target[j - 1])) }
                i -= 1
                j -= 1
            } else if cost[i][j] == cost[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs
    }

    /// One word heard as two, or two heard as one.
    ///
    /// `chipset` coming back as `chip set` is the error that motivates the
    /// whole feature, and an alignment cannot see it: two words against one is
    /// a deletion plus a substitution, which the caller above discards.
    static func splits(_ source: [String], _ target: [String]) -> [(String, String)] {
        var pairs: [(String, String)] = []
        let foldedSource = source.map(fold)
        let foldedTarget = target.map(fold)

        for index in source.indices.dropLast() {
            let joined = foldedSource[index] + foldedSource[index + 1]
            if !joined.isEmpty, let match = foldedTarget.firstIndex(of: joined) {
                pairs.append(("\(source[index]) \(source[index + 1])", target[match]))
            }
        }
        for index in target.indices.dropLast() {
            let joined = foldedTarget[index] + foldedTarget[index + 1]
            if !joined.isEmpty, let match = foldedSource.firstIndex(of: joined) {
                pairs.append((source[match], "\(target[index]) \(target[index + 1])"))
            }
        }
        return pairs
    }
}
