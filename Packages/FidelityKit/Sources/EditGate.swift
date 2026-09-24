// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation

import Foundation
import TextProcessingKit

public enum EditGateDisposition: String, Codable, Equatable, Sendable {
    case accepted
    case rewriteOnly
    case rejected
}

public enum EditGateReason: String, Codable, Equatable, Sendable {
    case mechanicalCleanup
    case grammarAgreement
    case fillerRemoval
    case repeatedWordRemoval
    case rewriteContract
    case acousticEvidence
    case missingAcousticEvidence
    case strongAcousticEvidence
    case unsupportedInsertion
    case unsupportedDeletion
    case unsupportedSubstitution
    case criticalOperator
}

public struct EditGateDecision: Codable, Equatable, Sendable {
    public let edit: ProposedEdit
    public let disposition: EditGateDisposition
    public let reason: EditGateReason

    public init(
        edit: ProposedEdit,
        disposition: EditGateDisposition,
        reason: EditGateReason
    ) {
        self.edit = edit
        self.disposition = disposition
        self.reason = reason
    }
}

/// Justifies every Qwen edit against deterministic policy and optional ASR proof.
public enum EditGate {
    public static func evaluate(
        _ script: EditScript,
        source: String,
        preparation: DeterministicPreparation,
        evidence: TranscriptEvidence?
    ) -> [EditGateDecision] {
        script.edits.map { edit in
            decide(
                edit,
                source: source,
                preparation: preparation,
                evidence: evidence
            )
        }
    }
}

private extension EditGate {
    static func decide(
        _ edit: ProposedEdit,
        source: String,
        preparation: DeterministicPreparation,
        evidence: TranscriptEvidence?
    ) -> EditGateDecision {
        switch edit.kind {
        case .punctuation, .spacing, .capitalization, .accent:
            return accept(edit, .mechanicalCleanup)
        case .agreement:
            if isCritical(edit.sourceText, language: preparation.language)
                || isCritical(edit.replacementText, language: preparation.language)
            {
                return reject(edit, .criticalOperator)
            }
            return accept(edit, .grammarAgreement)
        case .deletion:
            if isCritical(edit.sourceText, language: preparation.language) {
                return reject(edit, .criticalOperator)
            }
            if fillers(preparation.language).contains(ClauseAnalyzer.fold(edit.sourceText)) {
                return accept(edit, .fillerRemoval)
            }
            if isRepeatedDeletion(edit, in: source) {
                return accept(edit, .repeatedWordRemoval)
            }
            if preparation.cleanupMode == .rewrite {
                return accept(edit, .rewriteContract, disposition: .rewriteOnly)
            }
            return reject(edit, .unsupportedDeletion)
        case .movement:
            if preparation.cleanupMode == .rewrite {
                return accept(edit, .rewriteContract, disposition: .rewriteOnly)
            }
            return reject(edit, .unsupportedDeletion)
        case .insertion:
            let inserted = ClauseAnalyzer.fold(edit.replacementText)
            if functionWords(preparation.language).contains(inserted) {
                return accept(edit, .grammarAgreement)
            }
            return reject(edit, .unsupportedInsertion)
        case .substitution:
            if isCritical(edit.sourceText, language: preparation.language)
                || isCritical(edit.replacementText, language: preparation.language)
            {
                return reject(edit, .criticalOperator)
            }
            guard preparation.featureFlags.selectiveASRRescue,
                isDictionaryCorrection(edit, terms: preparation.dictionaryTerms)
            else {
                return reject(edit, .unsupportedSubstitution)
            }
            let proof = evidence?.words(overlapping: edit.sourceRange)
            guard let risk = proof?.compactMap(\.calibratedErrorProbability).max() else {
                return reject(edit, .missingAcousticEvidence)
            }
            if risk < 0.5 {
                return reject(edit, .strongAcousticEvidence)
            }
            return accept(edit, .acousticEvidence)
        }
    }

    static func accept(
        _ edit: ProposedEdit,
        _ reason: EditGateReason,
        disposition: EditGateDisposition = .accepted
    ) -> EditGateDecision {
        EditGateDecision(edit: edit, disposition: disposition, reason: reason)
    }

    static func reject(_ edit: ProposedEdit, _ reason: EditGateReason) -> EditGateDecision {
        EditGateDecision(edit: edit, disposition: .rejected, reason: reason)
    }

    static func isCritical(_ value: String, language: TextLanguage) -> Bool {
        SpanRepair.criticalWords(for: language).contains(ClauseAnalyzer.fold(value))
    }

    static func isDictionaryCorrection(_ edit: ProposedEdit, terms: [String]) -> Bool {
        let replacement = ClauseAnalyzer.fold(edit.replacementText)
        return terms.contains { ClauseAnalyzer.fold($0) == replacement }
    }

    static func isRepeatedDeletion(_ edit: ProposedEdit, in source: String) -> Bool {
        let words = ClauseAnalyzer.lexicalWords(in: source)
        let target = ClauseAnalyzer.fold(edit.sourceText)
        return zip(words, words.dropFirst()).contains { $0 == target && $1 == target }
    }

    static func fillers(_ language: TextLanguage) -> Set<String> {
        switch language {
        case .french:
            ["euh", "heu", "hum", "bah", "ben", "hein", "genre", "quoi"]
        case .english:
            ["uh", "um", "erm", "like", "basically"]
        }
    }

    static func functionWords(_ language: TextLanguage) -> Set<String> {
        switch language {
        case .french:
            ["a", "au", "aux", "de", "des", "du", "en", "le", "la", "les", "un", "une"]
        case .english:
            ["a", "an", "at", "by", "for", "in", "of", "on", "the", "to"]
        }
    }
}
