import Foundation
import TextProcessingKit

/// Stable reason why generated cleanup output was rejected.
public enum FidelityRejectionReason: String, Equatable, Sendable {
    case emptyOutput
    case missingProtectedToken
    case duplicatedProtectedToken
    case reorderedProtectedToken
    case unknownPlaceholder
    case outputTooLong
    case modelPreamble
    case thinkingLeak
    case unexpectedMarkdown
    case languageChanged
    case unexpectedContent
    case missingContent
    case editScopeTooLarge
}

/// Validated cleanup text and its selected route.
public struct FidelityDecision: Equatable, Sendable {
    /// Text safe to insert.
    public let text: String
    /// Whether the validated model output was retained.
    public let usedModelOutput: Bool
    /// Rejection reason when deterministic fallback was selected.
    public let rejectionReason: FidelityRejectionReason?

    /// Creates a fidelity decision.
    public init(
        text: String,
        usedModelOutput: Bool,
        rejectionReason: FidelityRejectionReason?
    ) {
        self.text = text
        self.usedModelOutput = usedModelOutput
        self.rejectionReason = rejectionReason
    }
}

/// Enforces bounded, faithful Qwen output before insertion.
public enum FidelityValidator {
    /// Validates a candidate and falls back deterministically on any violation.
    public static func validate(
        candidate rawCandidate: String,
        against preparation: DeterministicPreparation
    ) -> FidelityDecision {
        let candidate = normalizeTerminalPunctuation(
            in: normalizeListStructure(
                rawCandidate,
                automaticLists: preparation.automaticLists
            ),
            against: preparation
        )
        guard !candidate.isEmpty else {
            return reject(.emptyOutput, preparation)
        }

        for token in preparation.protectedTokens {
            let count = candidate.components(separatedBy: token.placeholder).count - 1
            if count == 0 {
                return reject(.missingProtectedToken, preparation)
            }
            if count > 1 {
                return reject(.duplicatedProtectedToken, preparation)
            }
        }

        let known = Set(preparation.protectedTokens.map(\.placeholder))
        let placeholders = matches(#"\bVOXOLP\d+\b"#, in: candidate)
        if placeholders.contains(where: { !known.contains($0) }) {
            return reject(.unknownPlaceholder, preparation)
        }
        if placeholders != preparation.protectedTokens.map(\.placeholder) {
            return reject(.reorderedProtectedToken, preparation)
        }

        let restored = preparation.restorePlaceholders(in: candidate)
        let fallbackLength = max(1, preparation.normalizedText.count)
        let maximumLength = Int(ceil(Double(fallbackLength) * 1.35)) + 16
        guard restored.count <= maximumLength else {
            return reject(.outputTooLong, preparation)
        }

        let lower = candidate.lowercased()
        let preambles = [
            "sure,", "certainly,", "here is", "here's", "final text:",
            "bien sûr", "voici", "texte final :", "résultat :",
        ]
        if preambles.contains(where: lower.hasPrefix) {
            return reject(.modelPreamble, preparation)
        }
        if lower.contains("<think>") || lower.contains("</think>")
            || lower.contains("<|assistant|")
        {
            return reject(.thinkingLeak, preparation)
        }
        if preparation.profile != .developer, preparation.profile != .prompt,
            (candidate.contains("```") || !matches(#"(?m)^#{1,6} "#, in: candidate).isEmpty)
        {
            return reject(.unexpectedMarkdown, preparation)
        }

        let sourceWordCount = preparation.normalizedText.split(whereSeparator: { !$0.isLetter })
            .count
        if sourceWordCount >= 8,
            let candidateLanguage = LanguageDetector.dominantLanguage(
                in: restored,
                minimumEvidence: 2
            ),
            candidateLanguage != preparation.language
        {
            return reject(.languageChanged, preparation)
        }

        let sourceWords = words(in: preparation.promptText)
        let candidateWords = words(in: candidate)
        if containsUnsupportedContent(
            candidateWords,
            sourceWords: sourceWords,
            language: preparation.language
        ) {
            return reject(.unexpectedContent, preparation)
        }
        if containsMissingContent(
            sourceWords,
            candidateWords: candidateWords,
            language: preparation.language,
            mode: preparation.cleanupMode,
            allowListFraming: preparation.automaticLists && containsStructuredList(candidate)
        ) {
            return reject(.missingContent, preparation)
        }
        // The edit budget is the mode's promise in numbers. Faithful allows
        // touch-ups; rewrite allows restructuring a spoken sentence into a
        // written one, which routinely moves a fifth of the words.
        let maximumWordEdits =
            preparation.cleanupMode == .rewrite
            ? max(8, Int(ceil(Double(sourceWords.count) * 0.20)))
            : max(3, Int(ceil(Double(sourceWords.count) * 0.05)))
        let isStructuredList =
            preparation.automaticLists && containsStructuredList(candidate)
        if !isStructuredList,
            wordEditDistance(sourceWords, candidateWords) > maximumWordEdits
        {
            return reject(.editScopeTooLarge, preparation)
        }

        return FidelityDecision(text: restored, usedModelOutput: true, rejectionReason: nil)
    }

    /// Returns deterministic normalized text for a rejected or unavailable generation.
    public static func fallback(
        for preparation: DeterministicPreparation,
        reason: FidelityRejectionReason? = nil
    ) -> FidelityDecision {
        FidelityDecision(
            text: preparation.normalizedText,
            usedModelOutput: false,
            rejectionReason: reason
        )
    }
}

private extension FidelityValidator {
    static func reject(
        _ reason: FidelityRejectionReason,
        _ preparation: DeterministicPreparation
    ) -> FidelityDecision {
        fallback(for: preparation, reason: reason)
    }

    static func normalizeTerminalPunctuation(
        in candidate: String,
        against preparation: DeterministicPreparation
    ) -> String {
        let terminalPunctuation = ".?!…:;"
        guard candidate.last.map({ !terminalPunctuation.contains($0) }) == true,
            !containsStructuredList(candidate)
        else {
            return candidate
        }
        if let fallbackLast = preparation.promptText.last,
            ".?!…".contains(fallbackLast)
        {
            return candidate + String(fallbackLast)
        }
        if !preparation.protectedTokens.isEmpty {
            return candidate + "."
        }
        return candidate
    }

    static func matches(_ pattern: String, in input: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.matches(in: input, range: range).compactMap { match in
            Range(match.range, in: input).map { String(input[$0]) }
        }
    }

    static func words(in input: String) -> [String] {
        let comparisonText =
            input
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "‑", with: " ")
        return matches(#"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#, in: comparisonText)
            .map(normalizeWord)
    }

    static func containsUnsupportedContent(
        _ candidateWords: [String],
        sourceWords: [String],
        language: TextLanguage
    ) -> Bool {
        var remainingSource = sourceWords
        var grammarInsertions = 0
        let maximumGrammarInsertions = max(2, sourceWords.count / 6)

        for candidate in candidateWords {
            if let exactIndex = remainingSource.firstIndex(of: candidate) {
                remainingSource.remove(at: exactIndex)
                continue
            }
            if let correctedIndex = bestMinorCorrection(
                for: candidate,
                in: remainingSource,
                language: language
            ) {
                remainingSource.remove(at: correctedIndex)
                continue
            }
            if grammarInsertions < maximumGrammarInsertions,
                grammarInsertionWords(for: language).contains(candidate)
            {
                grammarInsertions += 1
                continue
            }
            return true
        }
        return false
    }

    static func containsMissingContent(
        _ sourceWords: [String],
        candidateWords: [String],
        language: TextLanguage,
        mode: CleanupMode = .faithful,
        allowListFraming: Bool
    ) -> Bool {
        var remainingCandidate = candidateWords
        let removableWords = grammarInsertionWords(for: language)
            .union(removableDiscourseWords(for: language, mode: mode))
        let removableListWords = allowListFraming ? listFramingWords(for: language) : []

        for source in sourceWords {
            if let exactIndex = remainingCandidate.firstIndex(of: source) {
                remainingCandidate.remove(at: exactIndex)
                continue
            }
            if let correctedIndex = bestMinorCorrection(
                for: source,
                in: remainingCandidate,
                language: language
            ) {
                remainingCandidate.remove(at: correctedIndex)
                continue
            }
            if removableWords.contains(source) || removableListWords.contains(source) {
                continue
            }
            return true
        }
        return false
    }

    static func bestMinorCorrection(
        for candidate: String,
        in sourceWords: [String],
        language: TextLanguage
    ) -> Int? {
        sourceWords.indices
            .compactMap { index -> (index: Int, distance: Int)? in
                guard
                    let distance = minorCorrectionDistance(
                        from: sourceWords[index],
                        to: candidate,
                        language: language
                    )
                else {
                    return nil
                }
                return (index, distance)
            }
            .min { lhs, rhs in lhs.distance < rhs.distance }?
            .index
    }

    static func minorCorrectionDistance(
        from source: String,
        to candidate: String,
        language: TextLanguage
    ) -> Int? {
        guard source != candidate,
            !source.contains(where: \.isNumber),
            !candidate.contains(where: \.isNumber),
            !negationWords(for: language).contains(source),
            !negationWords(for: language).contains(candidate)
        else {
            return nil
        }
        if knownGrammarAlternatives(for: language).contains(where: {
            $0.contains(source) && $0.contains(candidate)
        }) {
            return 1
        }

        let distance = editDistance(source, candidate)
        let maximumLength = max(source.count, candidate.count)
        let allowedDistance = maximumLength <= 5 ? 1 : 2
        guard distance <= allowedDistance,
            Double(distance) / Double(maximumLength) <= 0.34
        else {
            return nil
        }
        if distance == 1 {
            return distance
        }

        let prefixCount = zip(source, candidate).prefix { $0 == $1 }.count
        let suffixCount = zip(source.reversed(), candidate.reversed()).prefix { $0 == $1 }.count
        return max(prefixCount, suffixCount) >= 2 ? distance : nil
    }

    static func normalizeWord(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .folding(
                options: .diacriticInsensitive,
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    static func editDistance(_ source: String, _ candidate: String) -> Int {
        let lhs = Array(source)
        let rhs = Array(candidate)
        return editDistance(lhs, rhs)
    }

    static func wordEditDistance(_ source: [String], _ candidate: [String]) -> Int {
        editDistance(source, candidate)
    }

    static func editDistance<Element: Equatable>(_ source: [Element], _ candidate: [Element])
        -> Int
    {
        let lhs = source
        let rhs = candidate
        var previous = Array(0...rhs.count)
        for (lhsIndex, lhsCharacter) in lhs.enumerated() {
            var current = [lhsIndex + 1]
            current.reserveCapacity(rhs.count + 1)
            for (rhsIndex, rhsCharacter) in rhs.enumerated() {
                current.append(
                    min(
                        current[rhsIndex] + 1,
                        previous[rhsIndex + 1] + 1,
                        previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }

    static func grammarInsertionWords(for language: TextLanguage) -> Set<String> {
        switch language {
        case .english:
            [
                "a", "an", "the", "to", "of", "in", "on", "at", "for", "and", "or", "but",
                "is", "are", "was", "were", "be", "been", "have", "has", "had", "do", "does",
                "did", "that", "which", "who", "i", "you", "he", "she", "we", "they", "it",
            ]
        case .french:
            [
                "le", "la", "les", "un", "une", "des", "de", "du", "a", "au", "aux", "en",
                "y", "que", "qui", "dont", "et", "ou", "mais", "est", "sont", "etre", "ete",
                "je", "tu", "il", "elle", "nous", "vous", "ils", "elles",
            ]
        }
    }

    static func negationWords(for language: TextLanguage) -> Set<String> {
        switch language {
        case .english:
            ["no", "not", "never", "neither", "nor", "without"]
        case .french:
            ["ne", "n'", "non", "pas", "plus", "jamais", "aucun", "aucune", "sans"]
        }
    }

    static func listFramingWords(for language: TextLanguage) -> Set<String> {
        switch language {
        case .english:
            [
                "first", "second", "third", "fourth", "finally", "things", "tasks",
                "items", "following", "todo",
            ]
        case .french:
            [
                "premierement", "deuxiemement", "troisiemement", "quatriemement",
                "enfin", "choses", "taches", "elements", "suivants", "faire",
            ]
        }
    }

    static func removableDiscourseWords(
        for language: TextLanguage,
        mode: CleanupMode
    ) -> Set<String> {
        switch (language, mode) {
        case (.english, .faithful), (.english, .raw):
            ["so"]
        case (.french, .faithful), (.french, .raw):
            // Faithful promises nothing you said is missing. The empty set is
            // that promise, and it is also why faithful output reads like a
            // transcript: the model is forbidden to drop "genre" or "en fait"
            // even when they are plainly scaffolding.
            []
        case (.english, .rewrite):
            [
                "so", "um", "uh", "erm", "like", "basically", "actually",
                "well", "anyway", "okay", "right", "kind", "sort", "know",
                "mean", "just", "really",
            ]
        case (.french, .rewrite):
            // The spoken-French crutch inventory, accent-folded to match
            // `normalizeWord`. Being here does not delete a word — it only
            // stops the validator from vetoing a deletion the model already
            // judged safe in context. Real negations never appear: they are
            // placeholder-protected upstream and their removal fails the
            // token audit before this list is consulted.
            [
                "euh", "heu", "hum", "bah", "ben", "hein", "voila", "quoi",
                "genre", "enfin", "bref", "alors", "bon", "donc", "coup",
                "fait", "gros", "attends", "attendez", "carrement",
                "franchement", "ouais", "fin", "ecoute", "ecoutez", "tiens",
                "dis", "dites", "comment", "dire", "veux", "voulais",
            ]
        }
    }

    static func knownGrammarAlternatives(for language: TextLanguage) -> [Set<String>] {
        switch language {
        case .english:
            [
                ["their", "there", "they're"], ["your", "you're"], ["its", "it's"],
                ["then", "than"], ["to", "too"], ["this", "these"], ["that", "those"],
            ]
        case .french:
            [
                ["et", "est"], ["son", "sont"], ["ce", "se"], ["ces", "ses"],
                ["c'est", "s'est"],
            ]
        }
    }

    static func normalizeListStructure(_ input: String, automaticLists: Bool) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard automaticLists else {
            return trimmed
        }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(
            String.init)
        guard let firstItem = lines.firstIndex(where: isListItem), firstItem > 0 else {
            return trimmed
        }
        let heading = lines[..<firstItem]
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["voici", "here", "liste", "list"].contains(where: heading.hasPrefix) else {
            return trimmed
        }
        return lines[firstItem...]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(canonicalListItem)
            .joined(separator: "\n")
    }

    static func containsStructuredList(_ input: String) -> Bool {
        input.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .contains(where: isListItem)
    }

    static func isListItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else {
            return false
        }
        return "*•-".contains(first)
            || !matches(#"^\d+[.)]\s+"#, in: trimmed).isEmpty
    }

    static func canonicalListItem(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, "*-".contains(first) else {
            return trimmed
        }
        return "• " + trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
    }
}
