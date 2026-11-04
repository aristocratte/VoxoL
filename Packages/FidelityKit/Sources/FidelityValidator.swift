import Foundation
import TextProcessingKit

/// Stable reason why generated cleanup output was rejected.
public enum FidelityRejectionReason: String, Equatable, Sendable {
    case emptyOutput
    case missingProtectedToken
    case duplicatedProtectedToken
    case reorderedProtectedToken
    case numberAttachmentChanged
    case unknownPlaceholder
    case outputTooLong
    case modelPreamble
    case thinkingLeak
    case unexpectedMarkdown
    case languageChanged
    case questionIntentChanged
    case unexpectedContent
    case missingContent
    case editScopeTooLarge
    case functionWordChanged
}

/// Validated cleanup text and its selected route.
public struct FidelityDecision: Equatable, Sendable {
    /// Text safe to insert.
    public let text: String
    /// Whether the validated model output was retained.
    public let usedModelOutput: Bool
    /// Rejection reason when deterministic fallback was selected.
    public let rejectionReason: FidelityRejectionReason?
    /// Sentences restored from the source by span repair, zero when the
    /// candidate passed whole.
    public let repairedSentenceCount: Int

    /// Creates a fidelity decision.
    public init(
        text: String,
        usedModelOutput: Bool,
        rejectionReason: FidelityRejectionReason?,
        repairedSentenceCount: Int = 0
    ) {
        self.text = text
        self.usedModelOutput = usedModelOutput
        self.rejectionReason = rejectionReason
        self.repairedSentenceCount = repairedSentenceCount
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
        // Order is judged against where the placeholders sit in the prompt, not against their
        // numbering: the numbers follow the order the protections were found in, which is not
        // always the order of the words, and a candidate that kept the sentence intact was
        // being thrown away as "reordered" — one rejection in thirteen on the human corpus.
        if placeholders != matches(#"\bVOXOLP\d+\b"#, in: preparation.promptText) {
            return reject(.reorderedProtectedToken, preparation)
        }

        let restored = preparation.restorePlaceholders(in: candidate)
        let fallbackLength = max(1, preparation.normalizedText.count)
        let maximumLength = Int(ceil(Double(fallbackLength) * 1.35)) + 16
        guard restored.count <= maximumLength else {
            return reject(.outputTooLong, preparation)
        }

        let lower = candidate.lowercased()
        // Only phrasings a dictation itself would not open with. "Ok," "d'accord" or "voilà"
        // are how people start sentences, and rejecting them threw away good text.
        let preambles = [
            "sure,", "certainly,", "here is", "here's", "here you go", "final text:",
            "corrected text:", "cleaned text:", "output:",
            "bien sûr", "voici", "texte final :", "texte final:", "texte corrigé :",
            "texte corrigé:", "résultat :", "résultat:", "réponse :", "réponse:",
        ]
        if preambles.contains(where: lower.hasPrefix) {
            return reject(.modelPreamble, preparation)
        }
        if lower.contains("<think>") || lower.contains("</think>")
            || lower.contains("<|assistant|") || lower.contains("<|im_start|>")
            || lower.contains("<|im_end|>")
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
        if sourceWordCount >= 8 {
            let sourceIsCodeSwitched = LanguageDetector.containsCodeSwitching(
                in: preparation.normalizedText
            )
            if sourceIsCodeSwitched {
                guard LanguageDetector.containsCodeSwitching(in: restored) else {
                    return reject(.languageChanged, preparation)
                }
            } else if let candidateLanguage = LanguageDetector.dominantLanguage(
                in: restored,
                minimumEvidence: 2
            ), candidateLanguage != preparation.language {
                return reject(.languageChanged, preparation)
            }
        }
        guard
            questionMarkCount(in: candidate)
                >= questionMarkCount(in: preparation.promptText)
        else {
            return reject(.questionIntentChanged, preparation)
        }

        let originalSourceWords = words(in: preparation.promptText)
        let candidateWords = words(in: candidate)
        if numberAttachmentChanged(
            sourceWords: originalSourceWords,
            candidateWords: candidateWords,
            tokens: preparation.protectedTokens,
            language: preparation.language
        ) {
            return reject(.numberAttachmentChanged, preparation)
        }
        let sourceWords = acceptingContextualAgreement(
            source: originalSourceWords, candidate: candidateWords, language: preparation.language
        )
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
        // A list legitimately drops its framing ("the things to do are … and …").
        if !isStructuredList, preparation.cleanupMode != .rewrite,
            functionWordChanged(
                source: preparation.promptText, candidate: candidate,
                language: preparation.language)
        {
            return reject(.functionWordChanged, preparation)
        }

        return FidelityDecision(text: restored, usedModelOutput: true, rejectionReason: nil)
    }

    /// Validates a candidate, salvaging it sentence by sentence if the whole
    /// fails for a content reason.
    ///
    /// Whole-output problems — a preamble, leaked thinking, a language flip —
    /// are not repairable by splicing and fall straight back. Content
    /// violations are local, so the failing sentences are restored from the
    /// source and the splice is re-judged by the unmodified full validator:
    /// the repair proposes, the original rules dispose.
    public static func validateWithRepair(
        candidate: String,
        against preparation: DeterministicPreparation
    ) -> FidelityDecision {
        let whole = validate(candidate: candidate, against: preparation)
        guard let reason = whole.rejectionReason, isRepairable(reason) else {
            return whole
        }
        guard let repair = repairedCandidate(candidate, against: preparation) else {
            return whole
        }
        let spliced = validate(candidate: repair.text, against: preparation)
        guard spliced.usedModelOutput else {
            return whole
        }
        return FidelityDecision(
            text: spliced.text,
            usedModelOutput: true,
            rejectionReason: nil,
            repairedSentenceCount: repair.revertedCount
        )
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
    static func isRepairable(_ reason: FidelityRejectionReason) -> Bool {
        switch reason {
        case .missingContent, .unexpectedContent, .editScopeTooLarge, .functionWordChanged,
            .missingProtectedToken, .duplicatedProtectedToken,
            .reorderedProtectedToken, .numberAttachmentChanged, .questionIntentChanged:
            true
        case .emptyOutput, .outputTooLong, .modelPreamble, .thinkingLeak,
            .unexpectedMarkdown, .languageChanged, .unknownPlaceholder:
            false
        }
    }

    static func repairedCandidate(
        _ candidate: String,
        against preparation: DeterministicPreparation
    ) -> (text: String, revertedCount: Int)? {
        let sourceSentences = SpanRepair.sentences(in: preparation.promptText)
        let candidateSentences = SpanRepair.sentences(in: candidate)
        guard
            let pairs = SpanRepair.align(
                source: sourceSentences,
                candidate: candidateSentences
            )
        else {
            return nil
        }
        var pieces: [String] = []
        var revertedCount = 0
        for pair in pairs {
            if pairIsAcceptable(pair, preparation: preparation) {
                pieces.append(pair.candidate)
            } else {
                pieces.append(repairOrthography(in: pair, preparation: preparation))
                revertedCount += 1
            }
        }
        guard revertedCount > 0,
            pieces.joined(separator: " ") != sourceSentences.joined(separator: " ")
        else {
            return nil
        }
        return (pieces.joined(separator: " "), revertedCount)
    }

    /// Keep individually valid spelling/agreement replacements even when the same
    /// sentence loses a negation or hallucinates content. Structural edits are not
    /// transplanted: every trial still passes the original per-sentence rules,
    /// and the assembled result must pass the whole validator afterwards.
    static func repairOrthography(
        in pair: SpanRepair.AlignedPair,
        preparation: DeterministicPreparation
    ) -> String {
        guard words(in: pair.source).count <= 256, words(in: pair.candidate).count <= 256 else {
            return pair.source
        }
        let edits = EditScript.build(source: pair.source, candidate: pair.candidate).edits
        var result = pair.source
        for edit in edits.sorted(by: { $0.sourceRange.lowerBound > $1.sourceRange.lowerBound }) {
            switch edit.kind {
            case .accent, .agreement, .substitution:
                break
            default:
                continue
            }
            guard !edit.sourceText.isEmpty, !edit.replacementText.isEmpty,
                !addsElidedClitic(source: edit.sourceText, replacement: edit.replacementText),
                let range = Range(NSRange(edit.sourceRange), in: result)
            else { continue }
            var trial = result
            trial.replaceSubrange(range, with: edit.replacementText)
            if pairIsAcceptable(
                SpanRepair.AlignedPair(source: pair.source, candidate: trial),
                preparation: preparation
            ) {
                result = trial
            }
        }
        return result
    }

    /// The whole-text rules, applied to one aligned sentence pair.
    static func pairIsAcceptable(
        _ pair: SpanRepair.AlignedPair,
        preparation: DeterministicPreparation
    ) -> Bool {
        // Placeholders present in this source slice must survive exactly once,
        // and the candidate may not borrow placeholders from elsewhere.
        let sourcePlaceholders = matches(#"\bVOXOLP\d+\b"#, in: pair.source)
        let candidatePlaceholders = matches(#"\bVOXOLP\d+\b"#, in: pair.candidate)
        guard candidatePlaceholders == sourcePlaceholders else {
            return false
        }

        let originalSourceWords = words(in: pair.source)
        let candidateWords = words(in: pair.candidate)
        guard
            !numberAttachmentChanged(
                sourceWords: originalSourceWords,
                candidateWords: candidateWords,
                tokens: preparation.protectedTokens,
                language: preparation.language
            )
        else {
            return false
        }
        if preparation.cleanupMode != .rewrite,
            functionWordChanged(
                source: pair.source, candidate: pair.candidate, language: preparation.language)
        {
            return false
        }
        let sourceWords = acceptingContextualAgreement(
            source: originalSourceWords, candidate: candidateWords, language: preparation.language
        )
        guard questionMarkCount(in: pair.source) == questionMarkCount(in: pair.candidate) else {
            return false
        }
        if containsUnsupportedContent(
            candidateWords,
            sourceWords: sourceWords,
            language: preparation.language
        ) {
            return false
        }
        if containsMissingContent(
            sourceWords,
            candidateWords: candidateWords,
            language: preparation.language,
            mode: preparation.cleanupMode,
            allowListFraming: false
        ) {
            return false
        }
        // Critical words survive verbatim, per occurrence.
        let critical = SpanRepair.criticalWords(for: preparation.language)
        var remaining = candidateWords
        for word in sourceWords where critical.contains(word) {
            guard let index = remaining.firstIndex(of: word) else {
                return false
            }
            remaining.remove(at: index)
        }
        return true
    }

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
        var fragment = candidate
        if preparation.context.startsMidSentence,
            let sourceFirst = preparation.promptText.first, sourceFirst.isLowercase,
            let candidateFirst = fragment.first,
            String(candidateFirst).lowercased() == String(sourceFirst)
        {
            fragment.replaceSubrange(
                fragment.startIndex...fragment.startIndex, with: String(sourceFirst))
        }
        if preparation.context.endsMidSentence {
            while fragment.last.map({ ".?!…".contains($0) }) == true {
                fragment.removeLast()
            }
            fragment = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = preparation.promptText.last, ",;:".contains(last),
                fragment.last != last
            {
                fragment += String(last)
            }
            return fragment
        }
        let candidate = fragment
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

    static func questionMarkCount(in text: String) -> Int {
        text.reduce(0) { count, character in
            count + (character == "?" || character == "？" ? 1 : 0)
        }
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

    /// A model may fix a present-tense agreement without changing the modal verb.
    /// Only the same subject at the same position licenses the specific correction;
    /// critical words still cannot pass by fuzzy spelling similarity elsewhere.
    static func acceptingContextualAgreement(
        source: [String], candidate: [String], language: TextLanguage
    ) -> [String] {
        guard language == .french, source.count == candidate.count, source.count > 1 else {
            return source
        }
        let corrections: [String: [String: String]] = [
            "je": ["peut": "peux", "doit": "dois"],
            "tu": ["peut": "peux", "doit": "dois"],
            "il": ["peux": "peut", "dois": "doit"],
            "elle": ["peux": "peut", "dois": "doit"],
            "on": ["peux": "peut", "dois": "doit"],
        ]
        var result = source
        for index in 1..<source.count {
            let subject = source[index - 1]
            guard subject == candidate[index - 1],
                corrections[subject]?[source[index]] == candidate[index]
            else { continue }
            result[index] = candidate[index]
        }
        return result
    }

    /// Keeping the number itself is insufficient: "3 commits" must not become
    /// "commit 3". Detect a neighboring content word crossing a numeric placeholder
    /// in either direction, while permitting its ordinary spelling/plural correction.
    /// This is a local attachment check, not a complete semantic equivalence test.
    static func numberAttachmentChanged(
        sourceWords: [String], candidateWords: [String], tokens: [ProtectedToken],
        language: TextLanguage
    ) -> Bool {
        let functionWords = grammarInsertionWords(for: language)
        func equivalent(_ lhs: String, _ rhs: String) -> Bool {
            lhs == rhs || minorCorrectionDistance(from: lhs, to: rhs, language: language) != nil
        }
        for token in tokens where token.kind == .number {
            let placeholder = normalizeWord(token.placeholder)
            guard let sourceIndex = sourceWords.firstIndex(of: placeholder),
                let candidateIndex = candidateWords.firstIndex(of: placeholder)
            else { continue }
            for direction in [-1, 1] {
                let sourceNeighbor = sourceIndex + direction
                let crossedNeighbor = candidateIndex - direction
                let sameNeighbor = candidateIndex + direction
                guard sourceWords.indices.contains(sourceNeighbor),
                    candidateWords.indices.contains(crossedNeighbor)
                else { continue }
                let word = sourceWords[sourceNeighbor]
                guard !functionWords.contains(word), !word.hasPrefix("voxolp"),
                    equivalent(word, candidateWords[crossedNeighbor])
                else { continue }
                if !candidateWords.indices.contains(sameNeighbor)
                    || !equivalent(word, candidateWords[sameNeighbor])
                {
                    return true
                }
            }
        }
        return false
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
            .subtracting(subjectPronouns(for: language))
        let removableListWords = allowListFraming ? listFramingWords(for: language) : []

        for (sourceIndex, source) in sourceWords.enumerated() {
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
            if subjectPronouns(for: language).contains(source),
                redundantSubject(
                    at: sourceIndex, source: sourceWords, candidate: candidateWords,
                    language: language, mode: mode)
            {
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
            !negationWords(for: language).contains(candidate),
            // A critical word never satisfies the check by resembling another
            // word: "peut" mapped to "peu" is one letter and a different
            // sentence. Criticals survive exactly or the edit is refused.
            !SpanRepair.criticalWords(for: language).contains(source),
            !SpanRepair.criticalWords(for: language).contains(candidate),
            !subjectPronouns(for: language).contains(source),
            !subjectPronouns(for: language).contains(candidate)
        else {
            return nil
        }
        if knownGrammarAlternatives(for: language).contains(where: {
            $0.contains(source) && $0.contains(candidate)
        }) {
            return 1
        }
        if isDuplicatedFragment(source, of: candidate)
            || isDuplicatedFragment(candidate, of: source)
        {
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

    /// Recognizes one exact duplicated syllable sequence rather than increasing
    /// the edit-distance allowance for arbitrary names or content words.
    /// Entire repeated words ("bonbon", names) and short fragments are excluded.
    static func isDuplicatedFragment(_ longer: String, of shorter: String) -> Bool {
        guard shorter.count >= 7, longer.count <= 64,
            longer.allSatisfy(\.isLetter), shorter.allSatisfy(\.isLetter)
        else { return false }
        let source = Array(longer)
        let target = Array(shorter)
        let repeatedCount = source.count - target.count
        guard repeatedCount >= 3, source.count - 2 * repeatedCount >= 2 else { return false }
        for start in 0...(source.count - 2 * repeatedCount) {
            let middle = start + repeatedCount
            let end = middle + repeatedCount
            if source[start..<middle].elementsEqual(source[middle..<end]),
                (Array(source[..<middle]) + Array(source[end...])) == target
            {
                return true
            }
        }
        return false
    }

    /// An actor is not a disposable function word. In particular, dropping "il"
    /// from "il ne faut pas" or changing "nous" to "vous" is not spelling cleanup.
    static func subjectPronouns(for language: TextLanguage) -> Set<String> {
        switch language {
        case .french: ["je", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles"]
        case .english: ["i", "you", "he", "she", "it", "we", "they"]
        }
    }

    /// A trailing "you know" or an explicit repeated nominal subject is spoken
    /// scaffolding. These local patterns do not allow the only subject to vanish.
    static func redundantSubject(
        at index: Int, source: [String], candidate: [String],
        language: TextLanguage, mode: CleanupMode
    ) -> Bool {
        func occurrences(of pattern: [String], in words: [String]) -> Int {
            guard words.count >= pattern.count else { return 0 }
            return (0...(words.count - pattern.count)).filter { start in
                words[start..<(start + pattern.count)].elementsEqual(pattern)
            }.count
        }
        if language == .english {
            return mode == .rewrite && index + 2 == source.count
                && source[index] == "you" && source[index + 1] == "know"
        }
        guard language == .french,
            source[index] == "il" || source[index] == "elle"
                || source[index] == "ils" || source[index] == "elles"
        else { return false }
        if source[index] == "il", index + 2 < source.count,
            source[index + 1] == "y", source[index + 2] == "a",
            occurrences(of: ["il", "y", "a"], in: source) > 1,
            occurrences(of: ["il", "y", "a"], in: candidate) > 0
        {
            return true
        }
        guard mode == .rewrite, index >= 2, index + 1 < source.count,
            ["le", "la", "les", "un", "une", "ce", "cette", "ces"].contains(source[index - 2])
        else { return false }
        let retainedSubject = [source[index - 2], source[index - 1], source[index + 1]]
        return occurrences(of: retainedSubject, in: candidate) > 0
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

/// Function-word guard, internal so its edge cases can be tested without the deterministic layer.
extension FidelityValidator {
    /// A closed-class word carries the grammar of what was said: trading "du" for "que" or "mes"
    /// for "tes" rewrites the sentence while every content word survives, so the insertion and
    /// deletion allowances below would each wave half of it through. Faithful cleanup may still
    /// add a missing article, fix a known homophone or an auxiliary's agreement, and drop a
    /// stuttered duplicate; it may not swap one of these words for another or drop one outright.
    static func functionWordChanged(
        source: String, candidate: String, language: TextLanguage
    ) -> Bool {
        let protected = swapProtectedWords(for: language)
        let alternatives = knownGrammarAlternatives(for: language) + swapAlternatives(for: language)
        func related(_ lhs: String, _ rhs: String) -> Bool {
            lhs == rhs || alternatives.contains { $0.contains(lhs) && $0.contains(rhs) }
        }
        let sourceTokens = wordTokens(in: source)
        let candidateWords = Set(words(in: candidate))
        for edit in EditScript.build(source: source, candidate: candidate).edits {
            let removed = normalizeWord(edit.sourceText)
            let added = normalizeWord(edit.replacementText)
            guard protected.contains(removed),
                let index = sourceTokens.firstIndex(where: {
                    $0.range.lowerBound == edit.sourceRange.lowerBound
                })
            else { continue }
            let previous = index > 0 ? sourceTokens[index - 1].word : nil
            let next = index + 1 < sourceTokens.count ? sourceTokens[index + 1].word : nil
            switch edit.kind {
            case .substitution, .agreement:
                // "le fichiers → les fichiers", or "de le → du" with either word replaced.
                let contracted = [
                    previous.flatMap { contraction(of: $0, removed) },
                    next.flatMap { contraction(of: removed, $0) },
                ]
                if protected.contains(added), !related(removed, added),
                    !contracted.contains(added)
                {
                    return true
                }
            case .deletion:
                // A stutter ("le le"), a self-correction ("le la"), the other half of a
                // contraction ("de le → du"), or an elision ("le email → l'email").
                let neighborExplains = [previous, next].contains { neighbor in
                    guard let neighbor else { return false }
                    return related(neighbor, removed) || contraction(of: neighbor, removed) != nil
                        || contraction(of: removed, neighbor) != nil
                }
                let elided = next.map { elidedForm(of: removed, before: $0) }
                if !neighborExplains, !(elided.map { candidateWords.contains($0 ?? "") } ?? false) {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }

    /// Words with their UTF-16 ranges, matching `EditScript`'s offsets.
    static func wordTokens(in text: String) -> [(word: String, range: Range<Int>)] {
        guard
            let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
        else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map {
            (normalizeWord(nsText.substring(with: $0.range)),
             $0.range.location..<($0.range.location + $0.range.length))
        }
    }

    /// French article-preposition contractions, accent-folded ("à" is "a").
    static func contraction(of first: String, _ second: String) -> String? {
        ["de le": "du", "de les": "des", "a le": "au", "a les": "aux"]["\(first) \(second)"]
    }

    /// The elided spelling a clitic takes before `word`, as `normalizeWord` writes it.
    static func elidedForm(of clitic: String, before word: String) -> String? {
        let elisions = [
            "le": "l", "la": "l", "de": "d", "je": "j", "me": "m", "te": "t", "se": "s",
            "ne": "n", "que": "qu", "ce": "c",
        ]
        return elisions[clitic].map { "\($0)'\(word)" }
    }

    /// A replacement that only glues a clitic onto the source word ("email → l'email") is half
    /// of an elision; transplanted alone it stacks the article twice ("le l'email").
    static func addsElidedClitic(source: String, replacement: String) -> Bool {
        let original = normalizeWord(source)
        let replaced = normalizeWord(replacement)
        guard let apostrophe = replaced.firstIndex(of: "'") else { return false }
        let clitic = String(replaced[..<apostrophe])
        return ["l", "d", "j", "m", "t", "s", "n", "qu", "c"].contains(clitic)
            && String(replaced[replaced.index(after: apostrophe)...]) == original
    }

    /// Articles, determiners, prepositions, conjunctions and pronouns, accent-folded. Auxiliaries
    /// stay out: "est → sont" is an agreement fix, and "a" doubles as French "à" after folding.
    static func swapProtectedWords(for language: TextLanguage) -> Set<String> {
        switch language {
        case .english:
            grammarInsertionWords(for: language).subtracting([
                "is", "are", "was", "were", "be", "been", "have", "has", "had", "do", "does",
                "did",
            ]).union([
                "my", "your", "his", "her", "our", "their", "its", "this", "these", "those",
                "with", "from", "by", "as", "me", "him", "us", "them",
            ])
        case .french:
            grammarInsertionWords(for: language).subtracting(["a", "est", "sont", "etre", "ete"])
                .union([
                    "on", "me", "te", "se", "lui", "leur", "leurs", "mes", "tes",
                    "ses", "ces", "son", "sa", "ma", "ta", "mon", "ton", "nos", "vos", "notre",
                    "votre", "ce", "cette", "cet", "dans", "sur", "pour", "par", "avec", "sous",
                    "vers", "chez", "donc", "car", "ni",
                ])
        }
    }

    /// Forms of one word that a correction may trade: an article's gender or number is
    /// agreement with its noun, not a different word ("le fichiers → les fichiers").
    static func swapAlternatives(for language: TextLanguage) -> [Set<String>] {
        switch language {
        case .english: [["a", "an"]]
        case .french:
            [
                ["le", "la", "les"], ["un", "une"], ["du", "de", "des"], ["au", "aux"],
                ["ce", "cet", "cette", "ces"], ["mon", "ma", "mes"], ["ton", "ta", "tes"],
                ["son", "sa", "ses"], ["notre", "nos"], ["votre", "vos"], ["leur", "leurs"],
            ]
        }
    }
}
