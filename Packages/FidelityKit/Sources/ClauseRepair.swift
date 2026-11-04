// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation

import Foundation
import TextProcessingKit

public struct AlignedClausePair: Equatable, Sendable {
    public let source: String
    public let candidate: String

    public init(source: String, candidate: String) {
        self.source = source
        self.candidate = candidate
    }
}

public struct ClauseRepairResult: Equatable, Sendable {
    public let text: String
    public let retainedClauseCount: Int
    public let revertedClauseCount: Int

    public init(text: String, retainedClauseCount: Int, revertedClauseCount: Int) {
        self.text = text
        self.retainedClauseCount = retainedClauseCount
        self.revertedClauseCount = revertedClauseCount
    }
}

/// Monotonic clause alignment and local rollback for a partially unsafe generation.
public enum ClauseRepair {
    public static func align(
        source: String,
        candidate: String,
        language: TextLanguage
    ) -> [AlignedClausePair]? {
        let sourceClauses = ClauseAnalyzer.analyze(source, language: language).map(\.text)
        let candidateClauses = ClauseAnalyzer.analyze(candidate, language: language).map(\.text)
        guard let pairs = SpanRepair.align(source: sourceClauses, candidate: candidateClauses)
        else { return nil }
        return pairs.map { AlignedClausePair(source: $0.source, candidate: $0.candidate) }
    }

    public static func repair(
        source: String,
        candidate: String,
        language: TextLanguage,
        accepting predicate: (AlignedClausePair) -> Bool
    ) -> ClauseRepairResult? {
        guard let pairs = align(source: source, candidate: candidate, language: language),
            pairs.count > 1
        else { return nil }
        var pieces = [String]()
        var retained = 0
        var reverted = 0
        for pair in pairs {
            if predicate(pair) {
                pieces.append(pair.candidate)
                retained += 1
            } else {
                pieces.append(pair.source)
                reverted += 1
            }
        }
        guard retained > 0, reverted > 0 else { return nil }
        return ClauseRepairResult(
            text: pieces.joined(separator: " "),
            retainedClauseCount: retained,
            revertedClauseCount: reverted
        )
    }
}
