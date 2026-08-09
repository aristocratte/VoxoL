import Foundation

/// Recovers what the dictated text was changed into, inside the destination app.
///
/// Correcting a misheard word where you are already working — click it, retype
/// it — is the natural moment, and until now VoxoL never saw it: the only edit
/// it learned from was one made afterwards in its own history window, which
/// nobody opens. Reading the destination control again a little later closes
/// that gap.
///
/// The hard part is not reading the field, it is telling a *correction* from
/// simply carrying on typing. Both change the text. Getting that wrong feeds
/// invented pairs into the dictionary, so everything here is built to answer
/// "no" whenever the evidence is thin.
public enum InsertionCorrection {
    /// The most the text may change and still count as a repair rather than a
    /// rewrite, as a fraction of the dictated length.
    public static let maximumDrift = 0.35

    /// Returns the edited form of the dictated span, or nil when the change
    /// does not look like a correction of it.
    public static func correctedText(
        inserted: String,
        baseline: String,
        current: String
    ) -> String? {
        let inserted = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inserted.isEmpty, current != baseline else { return nil }

        // Searched from the end: dictating into a long document puts the new
        // text last, and an earlier coincidental match would anchor the whole
        // comparison to the wrong place.
        guard let span = baseline.range(of: inserted, options: .backwards) else { return nil }
        let prefix = String(baseline[baseline.startIndex..<span.lowerBound])
        let suffix = String(baseline[span.upperBound...])

        // Text before the dictation must still be intact. If it is not, the
        // user is editing somewhere else entirely and nothing here refers to
        // what VoxoL wrote.
        guard current.hasPrefix(prefix) else { return nil }
        var middle = String(current.dropFirst(prefix.count))
        if !suffix.isEmpty, middle.hasSuffix(suffix) {
            middle = String(middle.dropLast(suffix.count))
        }
        middle = middle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !middle.isEmpty, middle != inserted else { return nil }
        guard isPlausibleRepair(of: inserted, into: middle) else { return nil }
        return middle
    }

    /// Whether the change is small enough to be a repair of the same sentence.
    ///
    /// Someone who keeps dictating or types a new paragraph produces a much
    /// longer string that shares a prefix with the old one — indistinguishable
    /// from a correction by position alone, which is why size and distance are
    /// checked instead.
    static func isPlausibleRepair(of inserted: String, into candidate: String) -> Bool {
        let insertedWords = DictionaryLearning.words(inserted).count
        let candidateWords = DictionaryLearning.words(candidate).count
        guard insertedWords > 0, candidateWords > 0 else { return false }
        guard Double(candidateWords) <= Double(insertedWords) * 1.5 + 2 else { return false }

        let distance = DictionaryLearning.distance(
            DictionaryLearning.fold(inserted),
            DictionaryLearning.fold(candidate)
        )
        return Double(distance) / Double(max(inserted.count, 1)) <= maximumDrift
    }
}
