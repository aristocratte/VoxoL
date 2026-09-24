// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation

import Foundation
import TextProcessingKit

/// Meaning-bearing operators that cleanup must preserve within an aligned clause.
public enum PropositionInvariantKind: String, Codable, Equatable, Sendable {
    case negation
    case modality
    case quantifier
    case condition
}

/// Canonical proposition operator extracted from one clause.
public struct PropositionInvariant: Codable, Equatable, Hashable, Sendable {
    public let kind: PropositionInvariantKind
    public let value: String

    public init(kind: PropositionInvariantKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// One clause with stable UTF-16 offsets and its semantic operators.
public struct AnalyzedClause: Equatable, Sendable {
    public let text: String
    public let sourceRange: Range<Int>
    public let invariants: [PropositionInvariant]

    public init(
        text: String,
        sourceRange: Range<Int>,
        invariants: [PropositionInvariant]
    ) {
        self.text = text
        self.sourceRange = sourceRange
        self.invariants = invariants
    }
}

/// Lightweight, deterministic proposition analysis for French and English dictation.
public enum ClauseAnalyzer {
    public static func analyze(
        _ text: String,
        language: TextLanguage
    ) -> [AnalyzedClause] {
        clauseRanges(in: text).map { range in
            let source = text as NSString
            let clause = source.substring(
                with: NSRange(location: range.lowerBound, length: range.count)
            )
            return AnalyzedClause(
                text: clause,
                sourceRange: range,
                invariants: invariants(in: clause, language: language)
            )
        }
    }

    public static func invariants(
        in text: String,
        language: TextLanguage
    ) -> [PropositionInvariant] {
        let words = lexicalWords(in: text)
        guard !words.isEmpty else { return [] }
        var result = [PropositionInvariant]()

        let negations: Set<String>
        let modality: [String: String]
        let quantifiers: [String: String]
        let conditions: [String: String]
        switch language {
        case .french:
            negations = ["non", "ne", "n", "pas", "jamais", "aucun", "aucune", "ni", "sans"]
            modality = [
                "doit": "obligation", "doivent": "obligation", "devra": "obligation",
                "devront": "obligation", "faut": "necessity", "obligatoire": "obligation",
                "interdit": "prohibition", "interdite": "prohibition",
                "peut": "possibility", "peuvent": "possibility", "pourrait": "possibility",
                "pourraient": "possibility", "devrait": "recommendation",
                "devraient": "recommendation", "faudrait": "recommendation",
            ]
            quantifiers = [
                "tout": "all", "toute": "all", "tous": "all", "toutes": "all",
                "chaque": "every", "seulement": "only", "uniquement": "only",
                "aucun": "none", "aucune": "none", "moins": "less", "plus": "more",
            ]
            conditions = [
                "si": "if", "sauf": "unless", "sinon": "otherwise",
                "condition": "condition", "exception": "exception",
            ]
        case .english:
            negations = ["no", "not", "never", "none", "neither", "nor", "without", "cannot"]
            modality = [
                "must": "obligation", "shall": "obligation", "required": "obligation",
                "cannot": "prohibition", "forbidden": "prohibition",
                "can": "possibility", "may": "possibility", "might": "possibility",
                "could": "possibility", "should": "recommendation",
            ]
            quantifiers = [
                "all": "all", "every": "every", "each": "every", "only": "only",
                "none": "none", "any": "any", "less": "less", "more": "more",
                "least": "least", "most": "most",
            ]
            conditions = [
                "if": "if", "unless": "unless", "otherwise": "otherwise",
                "except": "exception", "condition": "condition",
            ]
        }

        if words.contains(where: negations.contains) {
            result.append(PropositionInvariant(kind: .negation, value: "negated"))
        }
        result.append(contentsOf: canonicalMatches(words, table: modality, kind: .modality))
        result.append(contentsOf: canonicalMatches(words, table: quantifiers, kind: .quantifier))
        result.append(contentsOf: canonicalMatches(words, table: conditions, kind: .condition))
        return result.sorted {
            if $0.kind.rawValue == $1.kind.rawValue { return $0.value < $1.value }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }
}

extension ClauseAnalyzer {
    static func lexicalWords(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#) else {
            return []
        }
        let source = text as NSString
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ).map {
            fold(source.substring(with: $0.range))
        }
    }

    static func fold(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func clauseRanges(in text: String) -> [Range<Int>] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        var result = [Range<Int>]()
        var start = 0
        var index = 0
        while index < source.length {
            let scalar = source.substring(with: NSRange(location: index, length: 1))
            if ".!?…;\n".contains(scalar) {
                appendTrimmedRange(start..<index + 1, source: source, to: &result)
                start = index + 1
            }
            index += 1
        }
        appendTrimmedRange(start..<source.length, source: source, to: &result)
        return result
    }

    private static func appendTrimmedRange(
        _ range: Range<Int>,
        source: NSString,
        to result: inout [Range<Int>]
    ) {
        var lower = range.lowerBound
        var upper = range.upperBound
        let whitespace = CharacterSet.whitespacesAndNewlines
        while lower < upper,
            let scalar = UnicodeScalar(source.character(at: lower)),
            whitespace.contains(scalar)
        {
            lower += 1
        }
        while upper > lower,
            let scalar = UnicodeScalar(source.character(at: upper - 1)),
            whitespace.contains(scalar)
        {
            upper -= 1
        }
        if lower < upper { result.append(lower..<upper) }
    }

    private static func canonicalMatches(
        _ words: [String],
        table: [String: String],
        kind: PropositionInvariantKind
    ) -> [PropositionInvariant] {
        Set(words.compactMap { table[$0] }).map {
            PropositionInvariant(kind: kind, value: $0)
        }
    }
}
