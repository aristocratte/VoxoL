import CryptoKit
import Foundation

/// A locally editable Markdown report. The source transcript is kept separately.
public struct MeetingReportDraft: Codable, Equatable, Identifiable, Sendable {
    /// Identifier of the source transcript.
    public var id: UUID { transcriptID }
    /// Identifier used to link the report to its source transcript.
    public let transcriptID: UUID
    /// Time when the initial draft was created.
    public let createdAt: Date
    /// Time of the latest edit.
    public var updatedAt: Date
    /// Hash of the transcript, speaker names, and corrections used as evidence.
    public let sourceFingerprint: String
    /// Nil for a report started from the empty template.
    public let generator: String?
    /// Editable Markdown content.
    public var markdown: String

    /// Creates a report draft with its source fingerprint and Markdown content.
    public init(
        transcriptID: UUID, createdAt: Date = Date(), updatedAt: Date = Date(),
        sourceFingerprint: String, generator: String?, markdown: String
    ) {
        self.transcriptID = transcriptID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceFingerprint = sourceFingerprint
        self.generator = generator
        self.markdown = markdown
    }

    /// Speaker corrections and names change the evidence used for a generated report.
    public static func fingerprint(of transcript: SpeakerTranscript) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(transcript))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns whether the transcript still matches the evidence used by this draft.
    public func isCurrent(for transcript: SpeakerTranscript) -> Bool {
        (try? Self.fingerprint(of: transcript)) == sourceFingerprint
    }

    /// Creates an empty, editable report outline for a transcript.
    public static func template(for transcript: SpeakerTranscript, french: Bool) throws -> Self {
        let date = formattedMeetingDate(transcript.createdAt, french: french)
        let speakers = transcript.speakerIDs.map {
            transcript.name(for: $0, prefix: french ? "Intervenant" : "Speaker")
        }.joined(separator: ", ")
        let markdown: String
        if french {
            markdown = """
                # Compte rendu — \(transcript.title)

                **Date :** \(date)  
                **Durée :** \(SpeakerTranscript.timestamp(transcript.duration))  
                **Participants :** \(speakers.isEmpty ? "À confirmer" : speakers)

                ## Synthèse

                _À rédiger à partir de la transcription._

                ## Par intervenant

                _Résumez les contributions de chaque personne après vérification des voix._

                ## Décisions confirmées

                _Ajoutez uniquement les décisions effectivement prises._

                ## Actions

                _Indiquez pour chaque action son responsable et son échéance lorsqu'ils sont mentionnés._

                ## Points ouverts

                _Questions et éléments à confirmer._
                """
        } else {
            markdown = """
                # Meeting report — \(transcript.title)

                **Date:** \(date)  
                **Duration:** \(SpeakerTranscript.timestamp(transcript.duration))  
                **Participants:** \(speakers.isEmpty ? "To confirm" : speakers)

                ## Summary

                _Write from the transcript._

                ## By speaker

                _Summarize each person's contribution after reviewing speaker assignments._

                ## Confirmed decisions

                _Include only decisions actually made._

                ## Actions

                _Name an owner and due date only when stated._

                ## Open questions

                _Questions and items to confirm._
                """
        }
        return try Self(
            transcriptID: transcript.id,
            sourceFingerprint: fingerprint(of: transcript),
            generator: nil,
            markdown: markdown
        )
    }
}

/// Versioned report archive, separate from the immutable speaker transcript archive.
public actor MeetingReportArchiveStore {
    private struct Archive: Codable {
        var version = 1
        var reports: [MeetingReportDraft]
    }

    private let url: URL

    /// Stores report drafts at the given archive URL.
    public init(url: URL) { self.url = url }

    /// Loads report drafts from the versioned archive.
    public func load() throws -> [MeetingReportDraft] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw SpeakerError.archiveVersion }
        return archive.reports
    }

    /// Saves the complete archive with owner-only permissions.
    public func save(_ reports: [MeetingReportDraft]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(reports: reports)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Errors raised when model output cannot be tied to transcript evidence.
public enum MeetingReportGenerationError: LocalizedError, Sendable {
    case invalidOutput
    case invalidSource

    /// User-facing explanation of a rejected draft.
    public var errorDescription: String? {
        switch self {
        case .invalidOutput: "The local model did not return a complete meeting report. Try again."
        case .invalidSource: "The local model cited a passage outside this transcript. Try again."
        }
    }
}

/// One exact transcript fragment addressable by the local report model.
/// The model returns only the integer ID; Swift owns the quoted text and turn ID.
public struct MeetingReportEvidence: Equatable, Sendable {
    /// Dense identifier scoped to one report chunk.
    public let id: Int
    /// Source speaker turn containing this fragment.
    public let turnID: Int
    /// Exact, non-empty substring copied from the source turn.
    public let text: String

    /// Creates one model-addressable source fragment.
    public init(id: Int, turnID: Int, text: String) {
        self.id = id
        self.turnID = turnID
        self.text = text
    }
}

/// Builds short exact evidence fragments so the model can cite IDs instead of regenerating
/// transcript text token by token. Fragmentation is deterministic and never rewrites content.
public enum MeetingReportEvidenceBuilder {
    /// Splits one turn at sentence/clause punctuation, then bounds unusually long clauses.
    public static func fragments(in text: String, maximumCharacters: Int = 280) -> [String] {
        let limit = max(40, maximumCharacters)
        var clauses = [String]()
        var current = ""
        var iterator = text.makeIterator()
        var pending: Character? = iterator.next()
        while let character = pending {
            let next = iterator.next()
            current.append(character)
            if punctuation.contains(character), next.map(\.isWhitespace) ?? true {
                appendBounded(current, limit: limit, to: &clauses)
                current = ""
            }
            pending = next
        }
        appendBounded(current, limit: limit, to: &clauses)
        return clauses
    }

    private static func appendBounded(_ source: String, limit: Int, to result: inout [String]) {
        var remainder = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while remainder.count > limit {
            let tentative = remainder.index(remainder.startIndex, offsetBy: limit)
            let prefix = remainder[..<tentative]
            let split = prefix.lastIndex(where: \.isWhitespace) ?? tentative
            let piece = remainder[..<split].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(String(piece)) }
            remainder = remainder[split...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !remainder.isEmpty { result.append(remainder) }
    }

    private static let punctuation: Set<Character> = [".", "!", "?", "…", ",", ";", ":"]
}

/// Typed model output. Verbatim source quotes keep decisions and open points
/// tied to what was actually said, even when a small model overstates a summary.
public struct MeetingReportExtraction: Decodable, Sendable {
    struct EvidencePoint: Decodable, Sendable {
        let text: String?
        let quote: String
        let turnID: Int

        private enum CodingKeys: String, CodingKey {
            case text, quote
            case turnID = "turn_id"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            text = try values.decodeIfPresent(String.self, forKey: .text)
            quote = try values.decode(String.self, forKey: .quote)
            turnID = try values.decode(ReportTurnReference.self, forKey: .turnID).id
        }

        init(text: String?, quote: String, turnID: Int) {
            self.text = text
            self.quote = quote
            self.turnID = turnID
        }
    }

    struct Decision: Decodable, Sendable {
        let approvalQuote: String
        let approvalTurnID: Int

        private enum CodingKeys: String, CodingKey {
            case approvalQuote = "approval_quote"
            case approvalTurnID = "approval_turn_id"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            approvalQuote = try values.decode(String.self, forKey: .approvalQuote)
            approvalTurnID = try values.decode(ReportTurnReference.self, forKey: .approvalTurnID).id
        }

        init(approvalQuote: String, approvalTurnID: Int) {
            self.approvalQuote = approvalQuote
            self.approvalTurnID = approvalTurnID
        }
    }

    struct Action: Decodable, Sendable {
        let task: String
        let commitmentQuote: String
        let commitmentTurnID: Int
        let owner: String?
        let due: String?

        private enum CodingKeys: String, CodingKey {
            case task, owner, due
            case commitmentQuote = "commitment_quote"
            case commitmentTurnID = "commitment_turn_id"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            task = try values.decode(String.self, forKey: .task)
            commitmentQuote = try values.decode(String.self, forKey: .commitmentQuote)
            commitmentTurnID = try values.decode(
                ReportTurnReference.self, forKey: .commitmentTurnID
            ).id
            owner = try values.decodeIfPresent(String.self, forKey: .owner)
            due = try values.decodeIfPresent(String.self, forKey: .due)
        }

        init(
            task: String, commitmentQuote: String, commitmentTurnID: Int,
            owner: String?, due: String?
        ) {
            self.task = task
            self.commitmentQuote = commitmentQuote
            self.commitmentTurnID = commitmentTurnID
            self.owner = owner
            self.due = due
        }
    }

    struct OpenQuestion: Decodable, Sendable {
        let openQuote: String
        let openTurnID: Int

        private enum CodingKeys: String, CodingKey {
            case openQuote = "open_quote"
            case openTurnID = "open_turn_id"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            openQuote = try values.decode(String.self, forKey: .openQuote)
            openTurnID = try values.decode(ReportTurnReference.self, forKey: .openTurnID).id
        }

        init(openQuote: String, openTurnID: Int) {
            self.openQuote = openQuote
            self.openTurnID = openTurnID
        }
    }

    let topicQuote: String
    let topicSourceID: Int
    let summaryPoints: [EvidencePoint]
    let speakerPoints: [EvidencePoint]
    let decisions: [Decision]
    let actions: [Action]
    let openQuestions: [OpenQuestion]

    private enum CodingKeys: String, CodingKey {
        case decisions, actions
        case topicQuote = "topic_quote"
        case topicSourceID = "topic_source_id"
        case summaryPoints = "summary_points"
        case speakerPoints = "speaker_points"
        case openQuestions = "open_questions"
    }

    private struct CompactSpeakerPoint: Decodable {
        let evidence: Int
        let text: String

        private enum CodingKeys: String, CodingKey {
            case evidence = "e"
            case text = "x"
        }
    }

    private struct CompactAction: Decodable {
        let evidence: Int
        let task: String
        let owner: String?
        let due: String?

        private enum CodingKeys: String, CodingKey {
            case evidence = "e"
            case task = "x"
            case owner = "o"
            case due = "u"
        }
    }

    private struct CompactExtraction: Decodable {
        let topic: Int
        let summaries: [Int]
        let speakerPoints: [CompactSpeakerPoint]
        let decisions: [Int]
        let actions: [CompactAction]
        let questions: [Int]

        private enum CodingKeys: String, CodingKey {
            case topic = "t"
            case summaries = "s"
            case speakerPoints = "p"
            case decisions = "d"
            case actions = "a"
            case questions = "q"
        }
    }

    private struct DAQSelection {
        let decisions: [MeetingReportEvidence]
        let actions: [MeetingReportEvidence]
        let questions: [MeetingReportEvidence]
    }

    /// Decodes the model's structured extraction.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        topicQuote = try values.decode(String.self, forKey: .topicQuote)
        topicSourceID = try values.decode(ReportTurnReference.self, forKey: .topicSourceID).id
        summaryPoints =
            try values.decodeIfPresent([EvidencePoint].self, forKey: .summaryPoints) ?? []
        speakerPoints =
            try values.decodeIfPresent([EvidencePoint].self, forKey: .speakerPoints) ?? []
        decisions = try values.decode([Decision].self, forKey: .decisions)
        actions = try values.decode([Action].self, forKey: .actions)
        openQuestions = try values.decode([OpenQuestion].self, forKey: .openQuestions)
    }

    private init(
        topicQuote: String, topicSourceID: Int, summaryPoints: [EvidencePoint],
        speakerPoints: [EvidencePoint], decisions: [Decision], actions: [Action],
        openQuestions: [OpenQuestion]
    ) {
        self.topicQuote = topicQuote
        self.topicSourceID = topicSourceID
        self.summaryPoints = summaryPoints
        self.speakerPoints = speakerPoints
        self.decisions = decisions
        self.actions = actions
        self.openQuestions = openQuestions
    }

    /// Decodes the token-efficient meeting schema. Every evidence ID is resolved to immutable
    /// transcript text in Swift, so model output cannot fabricate or alter a source quotation.
    public static func parseCompact(
        _ output: String, evidence: [Int: MeetingReportEvidence]
    ) throws -> Self {
        guard let compact = try? JSONDecoder().decode(
            CompactExtraction.self, from: Data(output.utf8)),
            compact.decisions.count <= 20,
            compact.actions.count <= 20,
            compact.questions.count <= 20,
            compact.summaries.count <= 8,
            compact.speakerPoints.count <= 12,
            let topic = validEvidence(compact.topic, in: evidence),
            compact.summaries.allSatisfy({ validEvidence($0, in: evidence) != nil }),
            compact.speakerPoints.allSatisfy({ point in
                validEvidence(point.evidence, in: evidence) != nil
                    && !point.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && point.text.count <= 300
            }),
            compact.decisions.allSatisfy({ validEvidence($0, in: evidence) != nil }),
            compact.actions.allSatisfy({ action in
                validEvidence(action.evidence, in: evidence) != nil
                    && !action.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && action.task.count <= 300
            }),
            compact.questions.allSatisfy({ validEvidence($0, in: evidence) != nil })
        else { throw MeetingReportGenerationError.invalidOutput }

        let summaries = compact.summaries.compactMap { id -> EvidencePoint? in
            guard let source = evidence[id] else { return nil }
            return EvidencePoint(text: nil, quote: source.text, turnID: source.turnID)
        }
        let speakerPoints = compact.speakerPoints.compactMap { point -> EvidencePoint? in
            guard let source = evidence[point.evidence] else { return nil }
            return EvidencePoint(text: point.text, quote: source.text, turnID: source.turnID)
        }
        let decisions = compact.decisions.compactMap { id -> Decision? in
            guard let source = evidence[id] else { return nil }
            return Decision(approvalQuote: source.text, approvalTurnID: source.turnID)
        }
        let actions = compact.actions.compactMap { action -> Action? in
            guard let source = evidence[action.evidence] else { return nil }
            return Action(
                task: action.task, commitmentQuote: source.text,
                commitmentTurnID: source.turnID, owner: action.owner, due: action.due)
        }
        let questions = compact.questions.compactMap { id -> OpenQuestion? in
            guard let source = evidence[id] else { return nil }
            return OpenQuestion(openQuote: source.text, openTurnID: source.turnID)
        }
        return Self(
            topicQuote: topic.text, topicSourceID: topic.turnID,
            summaryPoints: summaries, speakerPoints: speakerPoints, decisions: decisions,
            actions: actions, openQuestions: questions)
    }

    /// Decodes the minimal decision/action/question classifier used by meeting mode.
    /// The model emits only immutable evidence labels; Swift reconstructs all report text.
    public static func parseDAQ(
        _ output: String, evidence: [Int: MeetingReportEvidence]
    ) throws -> Self {
        let selection = try decodeDAQ(output, evidence: evidence)
        let validEvidence = evidence.values.filter {
            Self.validEvidence($0.id, in: evidence) != nil
        }
        guard !validEvidence.isEmpty else { throw MeetingReportGenerationError.invalidOutput }

        let questions = selection.questions.filter { isExplicitOpenQuestion($0.text) }
        var summarySources = [MeetingReportEvidence]()
        var seenSummaryIDs = Set<Int>()
        for source in selection.decisions + selection.actions + questions {
            if seenSummaryIDs.insert(source.id).inserted { summarySources.append(source) }
        }
        for source in validEvidence.sorted(by: {
            if $0.text.count == $1.text.count { return $0.id < $1.id }
            return $0.text.count > $1.text.count
        }) where summarySources.count < 3 {
            if seenSummaryIDs.insert(source.id).inserted { summarySources.append(source) }
        }
        summarySources = Array(summarySources.prefix(3))
        guard let topic = summarySources.first ?? validEvidence.min(by: { $0.id < $1.id }) else {
            throw MeetingReportGenerationError.invalidOutput
        }

        return Self(
            topicQuote: topic.text,
            topicSourceID: topic.turnID,
            summaryPoints: summarySources.map {
                EvidencePoint(text: nil, quote: $0.text, turnID: $0.turnID)
            },
            speakerPoints: [],
            decisions: selection.decisions.map {
                Decision(approvalQuote: $0.text, approvalTurnID: $0.turnID)
            },
            actions: selection.actions.map {
                Action(
                    task: $0.text,
                    commitmentQuote: $0.text,
                    commitmentTurnID: $0.turnID,
                    owner: nil,
                    due: nil)
            },
            openQuestions: questions.map {
                OpenQuestion(openQuote: $0.text, openTurnID: $0.turnID)
            })
    }

    /// The locally resolved part of a DAQ candidate set plus only the IDs that still need Qwen.
    public struct DeterministicDAQPartition: Equatable, Sendable {
        public let resolvedOutput: String
        public let unresolvedIDs: [Int]

        public init(resolvedOutput: String, unresolvedIDs: [Int]) {
            self.resolvedOutput = resolvedOutput
            self.unresolvedIDs = unresolvedIDs
        }
    }

    /// Resolves every low-ambiguity candidate locally while preserving ambiguous candidates for
    /// semantic classification. Invalid or duplicate source IDs still fail closed.
    public static func deterministicDAQPartition(
        candidateIDs: [Int], evidence: [Int: MeetingReportEvidence]
    ) -> DeterministicDAQPartition? {
        guard Set(candidateIDs).count == candidateIDs.count else { return nil }
        var decisions = [Int]()
        var actions = [Int]()
        var questions = [Int]()
        var unresolved = [Int]()

        for id in candidateIDs {
            guard let source = validEvidence(id, in: evidence) else { return nil }
            let folded = classifierText(source.text)
            let matches = [
                isExplicitDecision(folded),
                isExplicitAction(folded),
                isExplicitOpenQuestion(source.text),
                isExplicitNonMatch(folded),
            ]
            guard matches.filter({ $0 }).count == 1 else {
                unresolved.append(id)
                continue
            }
            if matches[0] {
                decisions.append(id)
            } else if matches[1] {
                actions.append(id)
            } else if matches[2] {
                questions.append(id)
            }
        }

        func labels(_ ids: [Int]) -> String {
            ids.map { "\"E\($0)\"" }.joined(separator: ",")
        }
        return DeterministicDAQPartition(
            resolvedOutput:
                "{\"d\":[\(labels(decisions))],\"a\":[\(labels(actions))],\"q\":[\(labels(questions))]}",
            unresolvedIDs: unresolved)
    }

    /// Resolves only explicit, low-ambiguity decision/action/question formulations locally.
    /// Returning nil means at least one supplied candidate still needs semantic classification.
    public static func deterministicDAQOutput(
        candidateIDs: [Int], evidence: [Int: MeetingReportEvidence]
    ) -> String? {
        guard
            let partition = deterministicDAQPartition(
                candidateIDs: candidateIDs, evidence: evidence),
            partition.unresolvedIDs.isEmpty
        else { return nil }
        return partition.resolvedOutput
    }

    /// Accepts only output whose cited quotes occur in the supplied turns.
    public static func parse(_ output: String, sourceTurns: [Int: String]) throws -> Self {
        guard let result = try? JSONDecoder().decode(Self.self, from: Data(output.utf8)),
            validQuote(result.topicQuote, in: result.topicSourceID, sourceTurns: sourceTurns),
            result.decisions.count <= 20,
            result.actions.count <= 20,
            result.openQuestions.count <= 20,
            result.summaryPoints.count <= 8,
            result.speakerPoints.count <= 12,
            (result.summaryPoints + result.speakerPoints).allSatisfy({
                validQuote($0.quote, in: $0.turnID, sourceTurns: sourceTurns)
            }),
            result.speakerPoints.allSatisfy({
                guard let text = $0.text else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && text.count <= 300
            }),
            result.decisions.allSatisfy({
                validQuote($0.approvalQuote, in: $0.approvalTurnID, sourceTurns: sourceTurns)
            }),
            result.actions.allSatisfy({
                validQuote($0.commitmentQuote, in: $0.commitmentTurnID, sourceTurns: sourceTurns)
                    && !$0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.task.count <= 300
            }),
            result.openQuestions.allSatisfy({
                validQuote($0.openQuote, in: $0.openTurnID, sourceTurns: sourceTurns)
            })
        else { throw MeetingReportGenerationError.invalidOutput }
        return result
    }

    private static func validQuote(
        _ quote: String, in turnID: Int, sourceTurns: [Int: String]
    ) -> Bool {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500, let source = sourceTurns[turnID] else {
            return false
        }
        return source.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func validEvidence(
        _ id: Int, in evidence: [Int: MeetingReportEvidence]
    ) -> MeetingReportEvidence? {
        guard let source = evidence[id] else { return nil }
        let text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500, source.turnID >= 0 else { return nil }
        return source
    }

    private static func classifierText(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .replacingOccurrences(of: "’", with: "'")
        .replacingOccurrences(of: "‘", with: "'")
    }

    private static func isExplicitDecision(_ folded: String) -> Bool {
        let proposalMarkers = [
            "je propose", "je suggere", "je prefererais", "on pourrait", "il faudrait",
            "i propose", "i suggest", "i would prefer", "we could", "proposal",
        ]
        if proposalMarkers.contains(where: folded.contains) { return false }

        let strongMarkers = [
            "decision prise", "decision confirmee", "decision validee",
            "on decide", "nous decidons", "nous avons decide",
            "c'est valide", "c est valide",
            "we decided", "we have decided", "we approved", "we accepted",
            "we rejected", "we confirmed", "we validated",
            "decision confirmed", "decision approved", "decision accepted",
            "decision rejected", "decision validated",
        ]
        if strongMarkers.contains(where: folded.contains) { return true }

        let hypotheticalPrefixes = ["si ", "if ", "quand ", "when "]
        if hypotheticalPrefixes.contains(where: folded.hasPrefix) { return false }
        let passiveMarkers = [
            " est approuve", " est approuvee", " was approved", " is approved",
            " was accepted", " is accepted", " was rejected", " is rejected",
            " was validated", " is validated",
        ]
        return passiveMarkers.contains(where: folded.contains)
    }

    private static func isExplicitAction(_ folded: String) -> Bool {
        let uncertaintyMarkers = [
            "peut-etre", "peut etre", "j'aimerais", "je voudrais",
            "maybe", "perhaps", "might ", "could ", "would like", "i'd like",
        ]
        if uncertaintyMarkers.contains(where: folded.contains) { return false }
        if folded.contains("je ne vais pas") || folded.contains("i will not") { return false }

        let frenchMarkers = [
            "je m'engage", "je prends en charge", "je vais ",
            "je ferai", "je preparerai", "je terminerai", "je verifierai", "je publierai",
        ]
        if frenchMarkers.contains(where: folded.contains) { return true }
        if folded.contains("i commit ") || folded.contains("i will ") { return true }
        if folded.hasPrefix("i, ")
            && (folded.contains(", commit ") || folded.contains(", will "))
        {
            return true
        }
        return false
    }

    private static func isExplicitNonMatch(_ folded: String) -> Bool {
        let proposalMarkers = [
            "je propose", "je suggere", "je prefererais", "on pourrait", "il faudrait",
            "i propose", "i suggest", "i would prefer", "we could",
        ]
        return proposalMarkers.contains(where: folded.contains)
    }

    private static func decodeDAQ(
        _ output: String, evidence: [Int: MeetingReportEvidence]
    ) throws -> DAQSelection {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)),
            let dictionary = object as? [String: Any],
            Set(dictionary.keys) == Set(["d", "a", "q"]),
            let decisionLabels = dictionary["d"] as? [String],
            let actionLabels = dictionary["a"] as? [String],
            let questionLabels = dictionary["q"] as? [String],
            decisionLabels.count <= 20,
            actionLabels.count <= 20,
            questionLabels.count <= 20,
            Set(decisionLabels).count == decisionLabels.count,
            Set(actionLabels).count == actionLabels.count,
            Set(questionLabels).count == questionLabels.count,
            Set(decisionLabels).isDisjoint(with: actionLabels),
            Set(decisionLabels).isDisjoint(with: questionLabels),
            Set(actionLabels).isDisjoint(with: questionLabels)
        else { throw MeetingReportGenerationError.invalidOutput }

        func resolve(_ labels: [String]) throws -> [MeetingReportEvidence] {
            try labels.map { label in
                let bytes = Array(label.utf8)
                guard bytes.count >= 2, bytes[0] == 69,
                    bytes.dropFirst().allSatisfy({ $0 >= 48 && $0 <= 57 }),
                    let id = Int(label.dropFirst()), label == "E\(id)",
                    let source = validEvidence(id, in: evidence)
                else { throw MeetingReportGenerationError.invalidSource }
                return source
            }
        }

        return try DAQSelection(
            decisions: resolve(decisionLabels),
            actions: resolve(actionLabels),
            questions: resolve(questionLabels))
    }

    private static func isExplicitOpenQuestion(_ text: String) -> Bool {
        let folded = classifierText(text)
        let markers = [
            "pas encore decid", "encore decid", "reste en attente", "en attente",
            "approbation", "pending", "still have not decided", "not yet decided",
            "still need to decide", "remains to be decided", "waiting for approval",
            "approval has not been given", "approval hasn't been given", "approval not given",
            "undecid", "unanswered", "?",
        ]
        return markers.contains { folded.contains($0) }
    }
}

private struct ReportTurnReference: Decodable {
    let id: Int

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let id = try? value.decode(Int.self) {
            self.id = id
        } else {
            let label = try value.decode(String.self)
            guard label.first == "T", let id = Int(label.dropFirst()), id >= 0 else {
                throw MeetingReportGenerationError.invalidSource
            }
            self.id = id
        }
    }
}

/// Keeps the layout deterministic; source quotes remain visible beside model wording.
public enum MeetingReportMarkdown {
    /// Renders cited extracts into a stable, editable Markdown report.
    public static func render(
        transcript: SpeakerTranscript,
        extractions: [MeetingReportExtraction],
        french: Bool
    ) -> String {
        let date = formattedMeetingDate(transcript.createdAt, french: french)
        let speakers = transcript.speakerIDs.map {
            transcript.name(for: $0, prefix: french ? "Intervenant" : "Speaker")
        }.map(inline).joined(separator: ", ")
        let title = inline(transcript.title)
        let decisions = unique(extractions.flatMap(\.decisions), key: { $0.approvalQuote })
        let actions = unique(extractions.flatMap(\.actions), key: { $0.commitmentQuote })
        let questions = unique(extractions.flatMap(\.openQuestions), key: { $0.openQuote })
        let summaries = unique(extractions.flatMap(\.summaryPoints), key: { $0.quote })
        let contributions = unique(extractions.flatMap(\.speakerPoints), key: { $0.quote })
        var lines = [
            "# \(french ? "Compte rendu" : "Meeting report") — \(title)",
            "",
            "**\(french ? "Date :" : "Date:")** \(date)  ",
            "**\(french ? "Durée :" : "Duration:")** \(SpeakerTranscript.timestamp(transcript.duration))  ",
            "**\(french ? "Participants :" : "Participants:")** \(speakers.isEmpty ? (french ? "À confirmer" : "To confirm") : speakers)",
            "",
            "## \(french ? "Synthèse" : "Summary")",
            "",
        ]
        for extraction in extractions {
            lines.append(
                "**\(french ? "Sujet abordé" : "Topic discussed") :** « \(inline(extraction.topicQuote)) » \(citation(extraction.topicSourceID, in: transcript))"
            )
        }
        if !summaries.isEmpty { lines.append("") }
        for point in summaries {
            let category: String
            if decisions.contains(where: {
                $0.approvalQuote.localizedCaseInsensitiveContains(point.quote)
            }) {
                category = french ? "Accord exprimé" : "Agreement stated"
            } else if actions.contains(where: {
                $0.commitmentQuote.localizedCaseInsensitiveContains(point.quote)
            }) {
                category = french ? "Engagement" : "Commitment"
            } else if questions.contains(where: {
                $0.openQuote.localizedCaseInsensitiveContains(point.quote)
            }) {
                category = french ? "À confirmer" : "To confirm"
            } else {
                category = french ? "Point évoqué" : "Point discussed"
            }
            lines.append(
                "- **\(category) :** « \(inline(point.quote)) » \(citation(point.turnID, in: transcript))"
            )
        }

        lines += ["", "## \(french ? "Par intervenant" : "By speaker")", ""]
        for speaker in transcript.speakerIDs {
            let points = contributions.filter { point in
                transcript.turns.first(where: { $0.id == point.turnID })?
                    .displayedSpeakerIDs == [speaker]
            }
            lines.append(
                "### \(inline(transcript.name(for: speaker, prefix: french ? "Intervenant" : "Speaker")))"
            )
            if points.isEmpty {
                let sourceQuotes = summaries.filter { point in
                    transcript.turns.first(where: { $0.id == point.turnID })?
                        .displayedSpeakerIDs == [speaker]
                }
                if !sourceQuotes.isEmpty {
                    lines += sourceQuotes.prefix(2).map { point in
                        "- **\(french ? "Passage clé" : "Key excerpt") :** « \(inline(point.quote)) » \(citation(point.turnID, in: transcript))"
                    }
                } else if let turn = transcript.turns.filter({ $0.displayedSpeakerIDs == [speaker] }
                )
                .max(by: { $0.text.count < $1.text.count }) {
                    let excerpt = String(turn.text.prefix(220))
                    lines.append(
                        "- **\(french ? "Passage à relire" : "Excerpt to review") :** « \(inline(excerpt)) » \(citation(turn.id, in: transcript))"
                    )
                } else {
                    lines.append(
                        french
                            ? "_Aucun passage attribué avec certitude à cette personne._"
                            : "_No passage attributed to this speaker with confidence._")
                }
            } else {
                lines += points.map { point in
                    "- \(inline(point.text ?? point.quote)) \(citation(point.turnID, in: transcript))  \n  _« \(inline(point.quote)) »_"
                }
            }
            lines.append("")
        }

        lines += ["", "## \(french ? "Décisions à vérifier" : "Decisions to review")", ""]
        lines +=
            decisions.isEmpty
            ? [french ? "_Aucune décision extraite._" : "_No decision extracted._"]
            : decisions.map {
                "- « \(inline($0.approvalQuote)) » \(citation($0.approvalTurnID, in: transcript))"
            }

        lines += ["", "## \(french ? "Actions" : "Actions")", ""]
        lines +=
            actions.isEmpty
            ? [french ? "_Aucune action extraite._" : "_No action extracted._"]
            : actions.map { action in
                let turn = transcript.turns.first { $0.id == action.commitmentTurnID }
                let evidence = turn.map { transcript.label(for: $0) + " " + $0.text } ?? ""
                let owner =
                    supported(action.owner, by: evidence) ?? (french ? "à confirmer" : "to confirm")
                let due =
                    supported(action.due, by: action.commitmentQuote)
                    ?? (french ? "à confirmer" : "to confirm")
                let source = citation(action.commitmentTurnID, in: transcript)
                return
                    "- [ ] **\(inline(action.task))** — \(french ? "Responsable" : "Owner") : \(owner) · \(french ? "Échéance" : "Due") : \(due) \(source)  \n  _\(french ? "Passage" : "Source") : « \(inline(action.commitmentQuote)) »_"
            }

        lines += ["", "## \(french ? "Points ouverts" : "Open questions")", ""]
        lines +=
            questions.isEmpty
            ? [french ? "_Aucun point ouvert extrait._" : "_No open question extracted._"]
            : questions.map {
                "- « \(inline($0.openQuote)) » \(citation($0.openTurnID, in: transcript))"
            }
        lines += [
            "",
            french
                ? "_Brouillon automatique local. Vérifiez les faits et les passages cités avant de le partager._"
                : "_Local automatic draft. Check facts and cited passages before sharing._",
        ]
        return lines.joined(separator: "\n")
    }

    private static func inline(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for character in ["\\", "*", "_", "[", "]", "`"] {
            value = value.replacingOccurrences(of: character, with: "\\" + character)
        }
        return value
    }

    private static func supported(_ value: String?, by evidence: String) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty, value.count <= 80,
            evidence.localizedCaseInsensitiveContains(value)
        else { return nil }
        return inline(value)
    }

    private static func citation(_ id: Int, in transcript: SpeakerTranscript) -> String {
        transcript.turns.first { $0.id == id }.map {
            "[\(SpeakerTranscript.timestamp($0.start))]"
        }
            ?? ""
    }

    private static func unique<T>(_ values: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return values.filter { seen.insert(key($0).lowercased()).inserted }
    }
}

private func formattedMeetingDate(_ date: Date, french: Bool) -> String {
    date.formatted(
        Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(Locale(identifier: french ? "fr_FR" : "en_US")))
}
