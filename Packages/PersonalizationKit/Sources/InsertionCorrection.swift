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

    /// What happened to the dictated span since insertion.
    ///
    /// Only `corrected` carries learning signal, but the other outcomes carry
    /// measurement signal: the no-retouch rate is "how often the answer is
    /// `unchanged`", and counting a continuation as a correction would make
    /// every productive user look dissatisfied.
    public enum Outcome: Equatable, Sendable {
        /// The span is exactly as inserted.
        case unchanged
        /// The span was repaired; the payload is its new form.
        case corrected(String)
        /// The user kept writing after the span.
        case continued
        /// The text before the span changed: the user is editing elsewhere.
        case editedElsewhere
        /// The span was replaced beyond any plausible repair.
        case rewritten
    }

    /// Classifies the destination field's current text against the insertion.
    public static func classify(
        inserted: String,
        baseline: String,
        current: String
    ) -> Outcome {
        let trimmedInserted = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInserted.isEmpty, current != baseline else { return .unchanged }
        guard let span = baseline.range(of: trimmedInserted, options: .backwards) else {
            return .editedElsewhere
        }
        let prefix = String(baseline[baseline.startIndex..<span.lowerBound])
        let suffix = String(baseline[span.upperBound...])
        guard current.hasPrefix(prefix) else { return .editedElsewhere }
        var middle = String(current.dropFirst(prefix.count))
        if !suffix.isEmpty, middle.hasSuffix(suffix) {
            middle = String(middle.dropLast(suffix.count))
        }
        middle = middle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !middle.isEmpty else { return .rewritten }
        guard middle != trimmedInserted else { return .unchanged }
        // Growth beyond the repair envelope with the span intact at the front
        // is someone carrying on, not someone correcting.
        if middle.hasPrefix(trimmedInserted), middle.count > trimmedInserted.count {
            return .continued
        }
        guard isPlausibleRepair(of: trimmedInserted, into: middle) else {
            return .rewritten
        }
        return .corrected(middle)
    }

    /// Returns the edited form of the dictated span, or nil when the change
    /// does not look like a correction of it.
    public static func correctedText(
        inserted: String,
        baseline: String,
        current: String
    ) -> String? {
        if case .corrected(let text) = classify(
            inserted: inserted,
            baseline: baseline,
            current: current
        ) {
            return text
        }
        return nil
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
