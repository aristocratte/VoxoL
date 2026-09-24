// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation

import Foundation
import TextProcessingKit

public enum FidelityV3Status: String, Codable, Equatable, Sendable {
    case accepted
    case repaired
    case rejected
}

public enum FidelityV3RejectionReason: String, Codable, Equatable, Sendable {
    case emptyOutput
    case outputTooLong
    case modelPreamble
    case thinkingLeak
    case unexpectedPlaceholder
    case exactArtifactChanged
    case clauseAlignmentFailed
    case factChanged
    case propositionChanged
    case unsupportedEdit
    case missingContent
}

/// Independent shadow verdict. Its text is diagnostic until a later promotion gate.
public struct FidelityV3Decision: Codable, Equatable, Sendable {
    public let text: String
    public let status: FidelityV3Status
    public let rejectionReason: FidelityV3RejectionReason?
    public let acceptedEditCount: Int
    public let rejectedEditCount: Int
    public let repairedClauseCount: Int

    public init(
        text: String,
        status: FidelityV3Status,
        rejectionReason: FidelityV3RejectionReason?,
        acceptedEditCount: Int,
        rejectedEditCount: Int,
        repairedClauseCount: Int = 0
    ) {
        self.text = text
        self.status = status
        self.rejectionReason = rejectionReason
        self.acceptedEditCount = acceptedEditCount
        self.rejectedEditCount = rejectedEditCount
        self.repairedClauseCount = repairedClauseCount
    }
}

/// Proposition-aware edit validator. It runs beside v2 and has no insertion authority.
public enum FidelityValidatorV3 {
    public static func validateWithRepair(
        candidate rawCandidate: String,
        against preparation: DeterministicPreparation
    ) -> FidelityV3Decision {
        let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let restored = hygieneAndArtifacts(candidate, preparation: preparation) else {
            return rejectionForHygiene(candidate, preparation: preparation)
        }
        let source = preparation.normalizedText
        let whole = evaluatePair(source: source, candidate: restored, preparation: preparation)
        if whole.reason == nil {
            return FidelityV3Decision(
                text: restored,
                status: .accepted,
                rejectionReason: nil,
                acceptedEditCount: whole.acceptedEdits,
                rejectedEditCount: 0
            )
        }

        guard
            let repair = ClauseRepair.repair(
                source: source,
                candidate: restored,
                language: preparation.language,
                accepting: { pair in
                    evaluatePair(
                        source: pair.source,
                        candidate: pair.candidate,
                        preparation: preparation
                    ).reason == nil
                }
            )
        else {
            return reject(
                whole.reason ?? .unsupportedEdit,
                preparation: preparation,
                acceptedEdits: whole.acceptedEdits,
                rejectedEdits: whole.rejectedEdits
            )
        }

        let repairedVerdict = evaluatePair(
            source: source,
            candidate: repair.text,
            preparation: preparation
        )
        guard repairedVerdict.reason == nil else {
            return reject(
                whole.reason ?? .unsupportedEdit,
                preparation: preparation,
                acceptedEdits: whole.acceptedEdits,
                rejectedEdits: whole.rejectedEdits
            )
        }
        return FidelityV3Decision(
            text: repair.text,
            status: .repaired,
            rejectionReason: whole.reason,
            acceptedEditCount: repairedVerdict.acceptedEdits,
            rejectedEditCount: whole.rejectedEdits,
            repairedClauseCount: repair.revertedClauseCount
        )
    }
}

private extension FidelityValidatorV3 {
    struct PairVerdict {
        let reason: FidelityV3RejectionReason?
        let acceptedEdits: Int
        let rejectedEdits: Int
    }

    static func hygieneAndArtifacts(
        _ candidate: String,
        preparation: DeterministicPreparation
    ) -> String? {
        guard !candidate.isEmpty else { return nil }
        let lower = candidate.lowercased()
        let preambles = [
            "sure,", "certainly,", "here is", "here's", "final text:",
            "corrected text:", "output:", "bien sûr", "voici", "texte final :",
            "texte final:", "texte corrigé :", "résultat :", "réponse :",
        ]
        guard !preambles.contains(where: lower.hasPrefix),
            !lower.contains("<think>"), !lower.contains("</think>"),
            !lower.contains("<|assistant|"), !lower.contains("<|im_start|>"),
            !lower.contains("<|im_end|>")
        else { return nil }

        let maximumLength = Int(ceil(Double(max(1, preparation.normalizedText.count)) * 1.35)) + 16
        guard candidate.count <= maximumLength else { return nil }

        let known = Set(preparation.protectedTokens.map(\.placeholder))
        let found = placeholders(in: candidate)
        guard found.allSatisfy(known.contains) else { return nil }
        for token in preparation.protectedTokens {
            let count = candidate.components(separatedBy: token.placeholder).count - 1
            guard count <= 1 else { return nil }
        }

        let exactKinds: Set<ProtectedTokenKind> = [
            .code, .url, .email, .path, .commandFlag, .dictionaryTerm,
        ]
        let exactTokens = preparation.protectedTokens.filter { exactKinds.contains($0.kind) }
        let exactPlaceholders = Set(exactTokens.map(\.placeholder))
        let required = placeholders(in: preparation.promptText).filter(exactPlaceholders.contains)
        let present = found.filter { required.contains($0) }
        guard present == required else { return nil }
        return preparation.restorePlaceholders(in: candidate)
    }

    static func rejectionForHygiene(
        _ candidate: String,
        preparation: DeterministicPreparation
    ) -> FidelityV3Decision {
        let lower = candidate.lowercased()
        let reason: FidelityV3RejectionReason
        if candidate.isEmpty {
            reason = .emptyOutput
        } else if candidate.count
            > Int(ceil(Double(max(1, preparation.normalizedText.count)) * 1.35)) + 16
        {
            reason = .outputTooLong
        } else if lower.contains("<think>") || lower.contains("<|assistant|") {
            reason = .thinkingLeak
        } else if lower.hasPrefix("voici") || lower.hasPrefix("here is")
            || lower.hasPrefix("sure,") || lower.hasPrefix("texte final")
        {
            reason = .modelPreamble
        } else if placeholders(in: candidate).contains(where: {
            !Set(preparation.protectedTokens.map(\.placeholder)).contains($0)
        }) {
            reason = .unexpectedPlaceholder
        } else {
            reason = .exactArtifactChanged
        }
        return reject(reason, preparation: preparation)
    }

    static func evaluatePair(
        source: String,
        candidate: String,
        preparation: DeterministicPreparation
    ) -> PairVerdict {
        guard
            let pairs = ClauseRepair.align(
                source: source,
                candidate: candidate,
                language: preparation.language
            )
        else {
            return PairVerdict(reason: .clauseAlignmentFailed, acceptedEdits: 0, rejectedEdits: 1)
        }

        var acceptedEdits = 0
        var rejectedEdits = 0
        for pair in pairs {
            guard questionMarkCount(in: pair.source) == questionMarkCount(in: pair.candidate) else {
                return PairVerdict(
                    reason: .propositionChanged,
                    acceptedEdits: acceptedEdits,
                    rejectedEdits: rejectedEdits + 1
                )
            }
            let sourceFacts = FactLedger.extract(from: pair.source, language: preparation.language)
            let candidateFacts = FactLedger.extract(
                from: pair.candidate,
                language: preparation.language
            )
            guard sourceFacts.isEquivalent(to: candidateFacts) else {
                return PairVerdict(
                    reason: .factChanged,
                    acceptedEdits: acceptedEdits,
                    rejectedEdits: rejectedEdits + 1
                )
            }

            let sourceInvariants = Set(
                ClauseAnalyzer.invariants(in: pair.source, language: preparation.language)
            )
            let candidateInvariants = Set(
                ClauseAnalyzer.invariants(in: pair.candidate, language: preparation.language)
            )
            guard sourceInvariants == candidateInvariants else {
                return PairVerdict(
                    reason: .propositionChanged,
                    acceptedEdits: acceptedEdits,
                    rejectedEdits: rejectedEdits + 1
                )
            }

            let script = EditScript.build(source: pair.source, candidate: pair.candidate)
            let decisions = EditGate.evaluate(
                script,
                source: pair.source,
                preparation: preparation,
                evidence: preparation.transcriptEvidence?.rebased(to: pair.source)
            )
            acceptedEdits += decisions.filter { $0.disposition != .rejected }.count
            rejectedEdits += decisions.filter { $0.disposition == .rejected }.count
            if decisions.contains(where: { $0.disposition == .rejected }) {
                return PairVerdict(
                    reason: .unsupportedEdit,
                    acceptedEdits: acceptedEdits,
                    rejectedEdits: rejectedEdits
                )
            }
            guard
                contentCoverage(
                    source: pair.source,
                    candidate: pair.candidate,
                    mode: preparation.cleanupMode,
                    justifiedSubstitutionCount: decisions.filter {
                        $0.edit.kind == .substitution && $0.disposition != .rejected
                    }.count
                )
            else {
                return PairVerdict(
                    reason: .missingContent,
                    acceptedEdits: acceptedEdits,
                    rejectedEdits: rejectedEdits + 1
                )
            }
        }
        return PairVerdict(
            reason: nil,
            acceptedEdits: acceptedEdits,
            rejectedEdits: rejectedEdits
        )
    }

    static func questionMarkCount(in text: String) -> Int {
        text.reduce(0) { count, character in
            count + (character == "?" || character == "？" ? 1 : 0)
        }
    }

    static func contentCoverage(
        source: String,
        candidate: String,
        mode: CleanupMode,
        justifiedSubstitutionCount: Int
    ) -> Bool {
        let sourceWords = ClauseAnalyzer.lexicalWords(in: source)
        var candidateWords = ClauseAnalyzer.lexicalWords(in: candidate)
        guard !sourceWords.isEmpty else { return true }
        var matched = 0
        for word in sourceWords {
            if let index = candidateWords.firstIndex(where: {
                $0 == word || sameStem($0, word)
            }) {
                matched += 1
                candidateWords.remove(at: index)
            }
        }
        let minimum = mode == .rewrite ? 0.55 : 0.82
        return Double(min(sourceWords.count, matched + justifiedSubstitutionCount))
            / Double(sourceWords.count) >= minimum
    }

    static func sameStem(_ left: String, _ right: String) -> Bool {
        let prefix = zip(left, right).prefix { $0.0 == $0.1 }.count
        return prefix >= 4 && abs(left.count - right.count) <= 3
    }

    static func placeholders(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\bVOXOLP\d+\b"#) else {
            return []
        }
        let source = text as NSString
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ).map { source.substring(with: $0.range) }
    }

    static func reject(
        _ reason: FidelityV3RejectionReason,
        preparation: DeterministicPreparation,
        acceptedEdits: Int = 0,
        rejectedEdits: Int = 1
    ) -> FidelityV3Decision {
        FidelityV3Decision(
            text: preparation.normalizedText,
            status: .rejected,
            rejectionReason: reason,
            acceptedEditCount: acceptedEdits,
            rejectedEditCount: rejectedEdits
        )
    }
}
