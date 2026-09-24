// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation

import Foundation
import TextProcessingKit

/// Canonical fact classes whose values and local roles must survive cleanup.
public enum FactKind: String, Codable, Equatable, Hashable, Sendable {
    case quantity
    case dateOrTime
    case identifier
    case entity
}

/// One fact plus its nearest lexical anchors, used to detect value swaps.
public struct FactAtom: Codable, Equatable, Hashable, Sendable {
    public let kind: FactKind
    public let canonicalValue: String
    public let sourceSurface: String
    public let sourceRange: Range<Int>
    public let leftAnchor: String?
    public let rightAnchor: String?

    public init(
        kind: FactKind,
        canonicalValue: String,
        sourceSurface: String,
        sourceRange: Range<Int>,
        leftAnchor: String?,
        rightAnchor: String?
    ) {
        self.kind = kind
        self.canonicalValue = canonicalValue
        self.sourceSurface = sourceSurface
        self.sourceRange = sourceRange
        self.leftAnchor = leftAnchor
        self.rightAnchor = rightAnchor
    }
}

/// Deterministic canonical facts extracted from a clause.
public struct FactLedger: Equatable, Sendable {
    public let facts: [FactAtom]

    public init(facts: [FactAtom]) {
        self.facts = facts
    }

    public static func extract(
        from text: String,
        language: TextLanguage
    ) -> FactLedger {
        let tokens = LedgerToken.tokens(in: text)
        var facts = [FactAtom]()
        for (index, token) in tokens.enumerated() {
            let previous = nearestAnchor(before: index, in: tokens, language: language)
            let next = nearestAnchor(after: index, in: tokens, language: language)
            let unit = index + 1 < tokens.count ? canonicalUnit(tokens[index + 1].folded) : nil

            if let number = canonicalNumber(token.folded, language: language) {
                facts.append(
                    FactAtom(
                        kind: token.looksLikeDateOrTime ? .dateOrTime : .quantity,
                        canonicalValue: unit.map { "\(number)|\($0)" } ?? number,
                        sourceSurface: token.surface,
                        sourceRange: token.range,
                        leftAnchor: previous,
                        rightAnchor: next
                    )
                )
                continue
            }
            if token.looksLikeDateOrTime {
                facts.append(
                    FactAtom(
                        kind: .dateOrTime,
                        canonicalValue: canonicalDateOrTime(token.folded),
                        sourceSurface: token.surface,
                        sourceRange: token.range,
                        leftAnchor: previous,
                        rightAnchor: next
                    )
                )
                continue
            }
            if token.isIdentifier {
                facts.append(
                    FactAtom(
                        kind: .identifier,
                        canonicalValue: token.folded,
                        sourceSurface: token.surface,
                        sourceRange: token.range,
                        leftAnchor: previous,
                        rightAnchor: next
                    )
                )
                continue
            }
            if token.isEntityCandidate, index > 0 {
                facts.append(
                    FactAtom(
                        kind: .entity,
                        canonicalValue: token.folded,
                        sourceSurface: token.surface,
                        sourceRange: token.range,
                        leftAnchor: previous,
                        rightAnchor: next
                    )
                )
            }
        }
        return FactLedger(facts: facts)
    }

    /// Values and their local roles must match. Keeping the same two values but swapping
    /// "port 80" and "delay 30" changes the anchor signatures and is rejected.
    public func isEquivalent(to other: FactLedger) -> Bool {
        Self.signatures(facts) == Self.signatures(other.facts)
    }
}

private extension FactLedger {
    struct Signature: Hashable {
        let kind: FactKind
        let value: String
        let left: String?
        let right: String?
    }

    static func signatures(_ facts: [FactAtom]) -> [Signature: Int] {
        facts.reduce(into: [:]) { counts, fact in
            let usesAnchors = fact.kind == .quantity || fact.kind == .dateOrTime
            let signature = Signature(
                kind: fact.kind,
                value: fact.canonicalValue,
                left: usesAnchors ? fact.leftAnchor : nil,
                right: usesAnchors ? fact.rightAnchor : nil
            )
            counts[signature, default: 0] += 1
        }
    }

    static func nearestAnchor(
        before index: Int,
        in tokens: [LedgerToken],
        language: TextLanguage
    ) -> String? {
        guard index > 0 else { return nil }
        for candidate in tokens[..<index].reversed()
        where !stopWords(language).contains(candidate.folded)
            && canonicalNumber(candidate.folded, language: language) == nil
        {
            return candidate.folded
        }
        return nil
    }

    static func nearestAnchor(
        after index: Int,
        in tokens: [LedgerToken],
        language: TextLanguage
    ) -> String? {
        guard index + 1 < tokens.count else { return nil }
        for candidate in tokens[(index + 1)...]
        where !stopWords(language).contains(candidate.folded)
            && canonicalNumber(candidate.folded, language: language) == nil
        {
            return candidate.folded
        }
        return nil
    }

    static func stopWords(_ language: TextLanguage) -> Set<String> {
        switch language {
        case .french:
            ["le", "la", "les", "un", "une", "des", "du", "de", "d", "a", "au", "aux", "et", "est"]
        case .english:
            ["the", "a", "an", "of", "to", "for", "and", "is", "at", "on", "in"]
        }
    }

    static func canonicalNumber(_ value: String, language: TextLanguage) -> String? {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        if normalized.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil {
            if let integer = Int(normalized) { return String(integer) }
            if let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
            {
                return NSDecimalNumber(decimal: decimal).stringValue
            }
        }
        return numberWords(language)[value].map(String.init)
    }

    static func numberWords(_ language: TextLanguage) -> [String: Int] {
        switch language {
        case .french:
            [
                "zero": 0, "deux": 2, "trois": 3, "quatre": 4,
                "cinq": 5, "six": 6, "sept": 7, "huit": 8, "neuf": 9, "dix": 10,
                "onze": 11, "douze": 12, "treize": 13, "quatorze": 14,
                "quinze": 15, "seize": 16, "vingt": 20, "trente": 30,
                "quarante": 40, "cinquante": 50, "soixante": 60, "cent": 100,
            ]
        case .english:
            [
                "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
                "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
                "fifteen": 15, "sixteen": 16, "twenty": 20, "thirty": 30,
                "forty": 40, "fifty": 50, "sixty": 60, "hundred": 100,
            ]
        }
    }

    static func canonicalUnit(_ value: String) -> String? {
        let units: [String: String] = [
            "ms": "millisecond", "milliseconde": "millisecond", "millisecondes": "millisecond",
            "millisecond": "millisecond", "milliseconds": "millisecond",
            "s": "second", "seconde": "second", "secondes": "second",
            "second": "second", "seconds": "second",
            "min": "minute", "minute": "minute", "minutes": "minute",
            "h": "hour", "heure": "hour", "heures": "hour", "hour": "hour", "hours": "hour",
            "jour": "day", "jours": "day", "day": "day", "days": "day",
            "kg": "kg", "g": "g", "km": "km", "m": "m", "cm": "cm",
            "pourcent": "percent", "percent": "percent",
        ]
        return units[value]
    }

    static func canonicalDateOrTime(_ value: String) -> String {
        value.replacingOccurrences(of: "h", with: ":")
            .replacingOccurrences(of: ".", with: "/")
            .replacingOccurrences(of: "-", with: "/")
    }
}

private struct LedgerToken {
    let surface: String
    let folded: String
    let range: Range<Int>

    var looksLikeDateOrTime: Bool {
        folded.range(of: #"^\d{1,2}(?::|h)\d{2}$"#, options: .regularExpression) != nil
            || folded.range(
                of: #"^\d{1,4}(?:[./-]\d{1,2}){1,2}$"#,
                options: .regularExpression
            ) != nil
    }

    var isIdentifier: Bool {
        let hasLetter = folded.contains(where: \.isLetter)
        let hasDigit = folded.contains(where: \.isNumber)
        let isAcronym =
            surface.count >= 2 && surface == surface.uppercased()
            && hasLetter
        return (hasLetter && hasDigit) || isAcronym
    }

    var isEntityCandidate: Bool {
        guard let first = surface.first, first.isUppercase else { return false }
        return surface.dropFirst().contains(where: \.isLowercase)
    }

    static func tokens(in text: String) -> [LedgerToken] {
        let pattern =
            #"\b\d{1,2}(?::|h)\d{2}\b|\b\d{1,4}(?:[./-]\d{1,2}){1,2}\b|\b[\p{L}_][\p{L}\p{N}_.-]*\d[\p{L}\p{N}_.-]*\b|[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ).map { match in
            let surface = source.substring(with: match.range)
            return LedgerToken(
                surface: surface,
                folded: ClauseAnalyzer.fold(surface),
                range: match.range.location..<(match.range.location + match.range.length)
            )
        }
    }
}
