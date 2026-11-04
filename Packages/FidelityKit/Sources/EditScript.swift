// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation

import Foundation

/// Semantic class assigned to one proposed text edit.
public enum EditKind: String, Codable, Equatable, Sendable {
    case punctuation
    case spacing
    case capitalization
    case accent
    case agreement
    case insertion
    case deletion
    case substitution
    case movement
}

/// One source-to-candidate operation with UTF-16 offsets on both sides.
public struct ProposedEdit: Codable, Equatable, Sendable {
    public let kind: EditKind
    public let sourceRange: Range<Int>
    public let candidateRange: Range<Int>
    public let sourceText: String
    public let replacementText: String

    public init(
        kind: EditKind,
        sourceRange: Range<Int>,
        candidateRange: Range<Int>,
        sourceText: String,
        replacementText: String
    ) {
        self.kind = kind
        self.sourceRange = sourceRange
        self.candidateRange = candidateRange
        self.sourceText = sourceText
        self.replacementText = replacementText
    }
}

/// Token edit script used by the v3 gate instead of judging only whole strings.
public struct EditScript: Equatable, Sendable {
    public let edits: [ProposedEdit]

    public init(edits: [ProposedEdit]) {
        self.edits = edits
    }

    public static func build(source: String, candidate: String) -> EditScript {
        let sourceTokens = EditToken.tokens(in: source)
        let candidateTokens = EditToken.tokens(in: candidate)
        let operations = align(sourceTokens, candidateTokens)
        var edits = operations.compactMap { operation -> ProposedEdit? in
            switch operation {
            case .equal:
                return nil
            case .replace(let left, let right):
                return ProposedEdit(
                    kind: replacementKind(left, right),
                    sourceRange: left.range,
                    candidateRange: right.range,
                    sourceText: left.surface,
                    replacementText: right.surface
                )
            case .delete(let token, let candidateOffset):
                return ProposedEdit(
                    kind: token.isPunctuation ? .punctuation : .deletion,
                    sourceRange: token.range,
                    candidateRange: candidateOffset..<candidateOffset,
                    sourceText: token.surface,
                    replacementText: ""
                )
            case .insert(let token, let sourceOffset):
                return ProposedEdit(
                    kind: token.isPunctuation ? .punctuation : .insertion,
                    sourceRange: sourceOffset..<sourceOffset,
                    candidateRange: token.range,
                    sourceText: "",
                    replacementText: token.surface
                )
            }
        }

        markMovements(in: &edits)
        if edits.isEmpty, source != candidate,
            whitespaceInsensitive(source) == whitespaceInsensitive(candidate)
        {
            edits.append(
                ProposedEdit(
                    kind: .spacing,
                    sourceRange: 0..<(source as NSString).length,
                    candidateRange: 0..<(candidate as NSString).length,
                    sourceText: source,
                    replacementText: candidate
                )
            )
        }
        return EditScript(edits: edits)
    }
}

private extension EditScript {
    enum Operation {
        case equal(EditToken, EditToken)
        case replace(EditToken, EditToken)
        case delete(EditToken, candidateOffset: Int)
        case insert(EditToken, sourceOffset: Int)
    }

    static func align(_ source: [EditToken], _ candidate: [EditToken]) -> [Operation] {
        var costs = Array(
            repeating: Array(repeating: 0, count: candidate.count + 1),
            count: source.count + 1
        )
        for index in 0...source.count { costs[index][0] = index * 2 }
        for index in 0...candidate.count { costs[0][index] = index * 2 }
        if !source.isEmpty, !candidate.isEmpty {
            for i in 1...source.count {
                for j in 1...candidate.count {
                    let replacement = replacementCost(source[i - 1], candidate[j - 1])
                    costs[i][j] = min(
                        costs[i - 1][j] + 2,
                        costs[i][j - 1] + 2,
                        costs[i - 1][j - 1] + replacement
                    )
                }
            }
        }

        var operations = [Operation]()
        var i = source.count
        var j = candidate.count
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let substitution = replacementCost(source[i - 1], candidate[j - 1])
                if costs[i][j] == costs[i - 1][j - 1] + substitution {
                    operations.append(
                        substitution == 0
                            ? .equal(source[i - 1], candidate[j - 1])
                            : .replace(source[i - 1], candidate[j - 1])
                    )
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0, costs[i][j] == costs[i - 1][j] + 2 {
                let offset = j > 0 ? candidate[j - 1].range.upperBound : 0
                operations.append(.delete(source[i - 1], candidateOffset: offset))
                i -= 1
            } else if j > 0 {
                let offset = i > 0 ? source[i - 1].range.upperBound : 0
                operations.append(.insert(candidate[j - 1], sourceOffset: offset))
                j -= 1
            }
        }
        return operations.reversed()
    }

    static func replacementCost(_ source: EditToken, _ candidate: EditToken) -> Int {
        if source.surface == candidate.surface { return 0 }
        if source.folded == candidate.folded { return 1 }
        if source.isPunctuation != candidate.isPunctuation { return 5 }
        return 3
    }

    static func replacementKind(_ source: EditToken, _ candidate: EditToken) -> EditKind {
        if source.isPunctuation, candidate.isPunctuation { return .punctuation }
        if source.surface.lowercased() == candidate.surface.lowercased() {
            return .capitalization
        }
        if ClauseAnalyzer.fold(source.surface) == ClauseAnalyzer.fold(candidate.surface) {
            return .accent
        }
        let left = Array(source.folded)
        let right = Array(candidate.folded)
        let commonPrefix = zip(left, right).prefix { $0 == $1 }.count
        if commonPrefix >= 3, abs(left.count - right.count) <= 3 {
            return .agreement
        }
        return .substitution
    }

    static func markMovements(in edits: inout [ProposedEdit]) {
        var used = Set<Int>()
        for deletionIndex in edits.indices
        where edits[deletionIndex].kind == .deletion && !used.contains(deletionIndex) {
            let folded = ClauseAnalyzer.fold(edits[deletionIndex].sourceText)
            guard
                let insertionIndex = edits.indices.first(where: {
                    !used.contains($0) && edits[$0].kind == .insertion
                        && ClauseAnalyzer.fold(edits[$0].replacementText) == folded
                })
            else { continue }
            let deletion = edits[deletionIndex]
            let insertion = edits[insertionIndex]
            edits[deletionIndex] = ProposedEdit(
                kind: .movement,
                sourceRange: deletion.sourceRange,
                candidateRange: insertion.candidateRange,
                sourceText: deletion.sourceText,
                replacementText: insertion.replacementText
            )
            used.insert(deletionIndex)
            used.insert(insertionIndex)
        }
        edits = edits.enumerated().compactMap { index, edit in
            if used.contains(index), edit.kind == .insertion { return nil }
            return edit
        }
    }

    static func whitespaceInsensitive(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private struct EditToken {
    let surface: String
    let folded: String
    let range: Range<Int>
    let isPunctuation: Bool

    static func tokens(in text: String) -> [EditToken] {
        let pattern = #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*|[^\p{L}\p{N}\s]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ).map { match in
            let surface = source.substring(with: match.range)
            return EditToken(
                surface: surface,
                folded: ClauseAnalyzer.fold(surface),
                range: match.range.location..<(match.range.location + match.range.length),
                isPunctuation: surface.unicodeScalars.allSatisfy {
                    CharacterSet.punctuationCharacters.contains($0)
                        || CharacterSet.symbols.contains($0)
                }
            )
        }
    }
}
