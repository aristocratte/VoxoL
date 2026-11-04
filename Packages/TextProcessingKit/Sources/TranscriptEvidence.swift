// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation

import Foundation

/// Speech engine that supplied transcript evidence.
public enum TranscriptEvidenceSource: String, Codable, Equatable, Sendable {
    case parakeet
    case appleSpeech
    case unknown
}

/// Decoder evidence attached to one subword token.
public struct TranscriptTokenEvidence: Codable, Equatable, Sendable {
    public let tokenID: Int
    public let tokenIndex: Int
    public let frameIndex: Int?
    public let durationFrames: Int?
    public let logitMargin: Float?

    public init(
        tokenID: Int,
        tokenIndex: Int,
        frameIndex: Int? = nil,
        durationFrames: Int? = nil,
        logitMargin: Float? = nil
    ) {
        self.tokenID = tokenID
        self.tokenIndex = tokenIndex
        self.frameIndex = frameIndex
        self.durationFrames = durationFrames
        self.logitMargin = logitMargin
    }
}

/// Acoustic and decoder evidence for one lexical word in the current text representation.
public struct TranscriptWordEvidence: Codable, Equatable, Sendable {
    /// Exact surface found at ``sourceRange`` in the evidence's `sourceText`.
    public let surface: String
    /// UTF-16 range, matching Foundation and Accessibility offsets.
    public let sourceRange: Range<Int>
    public let tokens: [TranscriptTokenEvidence]
    public let frameRange: Range<Int>?
    public let minimumLogitMargin: Float?
    public let meanLogitMargin: Float?
    /// Nil until a calibration table built from reviewed real audio is available.
    public let calibratedErrorProbability: Double?
    /// Nil means the engine cannot expose this signal, as on Apple Speech.
    public let contextBiasActive: Bool?
    /// Nil means the engine cannot expose acoustic chunk boundaries.
    public let nearChunkBoundary: Bool?

    public init(
        surface: String,
        sourceRange: Range<Int>,
        tokens: [TranscriptTokenEvidence] = [],
        frameRange: Range<Int>? = nil,
        minimumLogitMargin: Float? = nil,
        meanLogitMargin: Float? = nil,
        calibratedErrorProbability: Double? = nil,
        contextBiasActive: Bool? = nil,
        nearChunkBoundary: Bool? = nil
    ) {
        self.surface = surface
        self.sourceRange = sourceRange
        self.tokens = tokens
        self.frameRange = frameRange
        self.minimumLogitMargin = minimumLogitMargin
        self.meanLogitMargin = meanLogitMargin
        self.calibratedErrorProbability = calibratedErrorProbability
        self.contextBiasActive = contextBiasActive
        self.nearChunkBoundary = nearChunkBoundary
    }
}

/// Word evidence kept aligned as deterministic processing changes the transcript surface.
public struct TranscriptEvidence: Codable, Equatable, Sendable {
    public let sourceText: String
    public let source: TranscriptEvidenceSource
    public let words: [TranscriptWordEvidence]

    public init(
        sourceText: String,
        source: TranscriptEvidenceSource,
        words: [TranscriptWordEvidence]
    ) {
        self.sourceText = sourceText
        self.source = source
        self.words = words
    }

    /// Evidence with valid word offsets but intentionally unknown confidence.
    public static func unknown(
        text: String,
        source: TranscriptEvidenceSource = .unknown
    ) -> TranscriptEvidence {
        TranscriptEvidence(
            sourceText: text,
            source: source,
            words: TranscriptEvidenceLexing.lexemes(in: text).map {
                TranscriptWordEvidence(surface: $0.surface, sourceRange: $0.range)
            }
        )
    }

    /// True only when every stored range still names its recorded surface.
    public var hasValidSourceRanges: Bool {
        let text = sourceText as NSString
        return words.allSatisfy { word in
            word.sourceRange.lowerBound >= 0
                && word.sourceRange.upperBound <= text.length
                && text.substring(
                    with: NSRange(
                        location: word.sourceRange.lowerBound,
                        length: word.sourceRange.count
                    )
                ) == word.surface
        }
    }

    /// Re-aligns evidence to a normalized, protected or otherwise deterministically edited text.
    /// Inserted words receive unknown evidence; diagonal substitutions retain the source proof.
    public func rebased(to text: String) -> TranscriptEvidence {
        rebased(to: text, using: words)
    }

    /// Re-aligns one consecutive word slice to an independently processed transcript chunk.
    public func slice(words range: Range<Int>, rebasedTo text: String) -> TranscriptEvidence {
        let lower = min(max(0, range.lowerBound), words.count)
        let upper = min(max(lower, range.upperBound), words.count)
        return rebased(to: text, using: Array(words[lower..<upper]))
    }

    /// Evidence overlapping a proposed UTF-16 source edit.
    public func words(overlapping range: Range<Int>) -> [TranscriptWordEvidence] {
        words.filter {
            $0.sourceRange.lowerBound < range.upperBound
                && range.lowerBound < $0.sourceRange.upperBound
        }
    }
}

private extension TranscriptEvidence {
    func rebased(
        to text: String,
        using sourceWords: [TranscriptWordEvidence]
    ) -> TranscriptEvidence {
        let targetLexemes = TranscriptEvidenceLexing.lexemes(in: text)
        guard !targetLexemes.isEmpty else {
            return TranscriptEvidence(sourceText: text, source: source, words: [])
        }
        let sourceSurfaces = sourceWords.map { TranscriptEvidenceLexing.fold($0.surface) }
        let targetSurfaces = targetLexemes.map(\.folded)
        let alignment = Self.alignment(from: sourceSurfaces, to: targetSurfaces)

        let alignedWords = targetLexemes.enumerated().map { index, lexeme in
            guard let sourceIndex = alignment[index], sourceWords.indices.contains(sourceIndex)
            else {
                return TranscriptWordEvidence(surface: lexeme.surface, sourceRange: lexeme.range)
            }
            let original = sourceWords[sourceIndex]
            return TranscriptWordEvidence(
                surface: lexeme.surface,
                sourceRange: lexeme.range,
                tokens: original.tokens,
                frameRange: original.frameRange,
                minimumLogitMargin: original.minimumLogitMargin,
                meanLogitMargin: original.meanLogitMargin,
                calibratedErrorProbability: original.calibratedErrorProbability,
                contextBiasActive: original.contextBiasActive,
                nearChunkBoundary: original.nearChunkBoundary
            )
        }
        return TranscriptEvidence(sourceText: text, source: source, words: alignedWords)
    }

    /// Maps target word indexes back to source word indexes using a monotonic edit alignment.
    static func alignment(from source: [String], to target: [String]) -> [Int: Int] {
        var costs = Array(
            repeating: Array(repeating: 0, count: target.count + 1),
            count: source.count + 1
        )
        for index in 0...source.count { costs[index][0] = index }
        for index in 0...target.count { costs[0][index] = index }
        if !source.isEmpty, !target.isEmpty {
            for sourceIndex in 1...source.count {
                for targetIndex in 1...target.count {
                    costs[sourceIndex][targetIndex] = min(
                        costs[sourceIndex - 1][targetIndex] + 1,
                        costs[sourceIndex][targetIndex - 1] + 1,
                        costs[sourceIndex - 1][targetIndex - 1]
                            + (source[sourceIndex - 1] == target[targetIndex - 1] ? 0 : 1)
                    )
                }
            }
        }

        var mapping: [Int: Int] = [:]
        var sourceIndex = source.count
        var targetIndex = target.count
        while sourceIndex > 0 || targetIndex > 0 {
            if sourceIndex > 0, targetIndex > 0 {
                let diagonal =
                    costs[sourceIndex - 1][targetIndex - 1]
                    + (source[sourceIndex - 1] == target[targetIndex - 1] ? 0 : 1)
                if costs[sourceIndex][targetIndex] == diagonal {
                    mapping[targetIndex - 1] = sourceIndex - 1
                    sourceIndex -= 1
                    targetIndex -= 1
                    continue
                }
            }
            if sourceIndex > 0,
                costs[sourceIndex][targetIndex] == costs[sourceIndex - 1][targetIndex] + 1
            {
                sourceIndex -= 1
            } else if targetIndex > 0 {
                targetIndex -= 1
            }
        }
        return mapping
    }
}

/// Runtime form of the monotonic word-risk table produced by the calibration script.
public struct ASRWordRiskCalibration: Codable, Equatable, Sendable {
    public struct Knot: Codable, Equatable, Sendable {
        public let margin: Float
        public let errorProbability: Double

        public init(margin: Float, errorProbability: Double) {
            self.margin = margin
            self.errorProbability = min(1, max(0, errorProbability))
        }
    }

    public let schemaVersion: Int
    public let method: String
    public let knots: [Knot]

    public init(
        schemaVersion: Int = 1,
        method: String = "isotonic-pav",
        knots: [Knot]
    ) {
        self.schemaVersion = schemaVersion
        self.method = method
        self.knots = knots.sorted { $0.margin < $1.margin }
    }

    public func errorProbability(for margin: Float) -> Double? {
        guard let first = knots.first, let last = knots.last else { return nil }
        if margin <= first.margin { return first.errorProbability }
        if margin >= last.margin { return last.errorProbability }
        for (left, right) in zip(knots, knots.dropFirst())
        where margin >= left.margin && margin <= right.margin {
            let width = Double(right.margin - left.margin)
            guard width > 0 else { return right.errorProbability }
            let fraction = Double(margin - left.margin) / width
            return left.errorProbability
                + fraction * (right.errorProbability - left.errorProbability)
        }
        return nil
    }

    public func applying(to evidence: TranscriptEvidence) -> TranscriptEvidence {
        TranscriptEvidence(
            sourceText: evidence.sourceText,
            source: evidence.source,
            words: evidence.words.map { word in
                TranscriptWordEvidence(
                    surface: word.surface,
                    sourceRange: word.sourceRange,
                    tokens: word.tokens,
                    frameRange: word.frameRange,
                    minimumLogitMargin: word.minimumLogitMargin,
                    meanLogitMargin: word.meanLogitMargin,
                    calibratedErrorProbability: word.minimumLogitMargin.flatMap(
                        errorProbability(for:)
                    ),
                    contextBiasActive: word.contextBiasActive,
                    nearChunkBoundary: word.nearChunkBoundary
                )
            }
        )
    }
}

struct TranscriptEvidenceLexeme: Equatable {
    let surface: String
    let folded: String
    let range: Range<Int>
}

enum TranscriptEvidenceLexing {
    static func lexemes(in text: String) -> [TranscriptEvidenceLexeme] {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#
            )
        else { return [] }
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        return regex.matches(in: text, range: range).map { match in
            let surface = source.substring(with: match.range)
            return TranscriptEvidenceLexeme(
                surface: surface,
                folded: fold(surface),
                range: match.range.location..<(match.range.location + match.range.length)
            )
        }
    }

    static func fold(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}
