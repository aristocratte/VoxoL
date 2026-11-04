import Foundation

/// Prose drafted from a bounded set of transcript passages. Citations are resolved in Swift.
public struct MeetingReportNarrative: Equatable, Sendable {
    /// One immutable transcript fragment considered for the bounded global summary.
    public struct Source: Equatable, Sendable {
        public let turnID: Int
        public let text: String
        public let prioritized: Bool

        public init(turnID: Int, text: String, prioritized: Bool = false) {
            self.turnID = turnID
            self.text = text
            self.prioritized = prioritized
        }
    }

    public struct Paragraph: Equatable, Sendable {
        public let text: String
        public let sourceTurnIDs: [Int]

        public init(text: String, sourceTurnIDs: [Int]) {
            self.text = text
            self.sourceTurnIDs = sourceTurnIDs
        }
    }

    public let paragraphs: [Paragraph]
    public let usesVerbatimFallback: Bool

    public init(paragraphs: [Paragraph], usesVerbatimFallback: Bool = false) {
        self.paragraphs = paragraphs
        self.usesVerbatimFallback = usesVerbatimFallback
    }

    /// Selects a deterministic, duration-independent evidence set for one global narrative.
    ///
    /// Uses the same fragment and candidate selection as full-transcript DAQ extraction.
    public static func boundedEvidence(from transcript: SpeakerTranscript) -> [Int:
        MeetingReportEvidence]
    {
        let sources = transcript.turns.flatMap { turn in
            MeetingReportEvidenceBuilder.fragments(in: turn.text).map { text in
                Source(
                    turnID: turn.id, text: text,
                    prioritized: MeetingReportExtraction.isLikelyDAQCandidate(text))
            }
        }
        return boundedEvidence(from: sources)
    }

    /// Renders bounded evidence for the legacy narrative route and local verification.
    public static func prompt(
        evidence: [Int: MeetingReportEvidence], transcript: SpeakerTranscript, french: Bool
    ) -> String {
        let turns = transcript.turns.reduce(into: [Int: SpeakerTurn]()) { result, turn in
            if result[turn.id] == nil { result[turn.id] = turn }
        }
        let lines = evidence.values.sorted { $0.id < $1.id }.map { source in
            let speaker =
                turns[source.turnID].map {
                    transcript.label(
                        for: $0, prefix: french ? "Intervenant" : "Speaker",
                        unknown: french ? "Voix incertaine" : "Uncertain voice")
                } ?? ""
            return "[E\(source.id)] \(speaker): \(source.text)"
        }.joined(separator: "\n")
        return "<transcript>\n\(lines)\n</transcript>"
    }

    /// Decision/action/question candidates are kept first. Remaining capacity is spread across
    /// the full timeline, and repeated text is collapsed. IDs are reassigned densely so the
    /// structured prompt stays compact and can be validated with the existing parser.
    public static func boundedEvidence(
        from sources: [Source],
        maximumCharacters: Int = 5_200,
        maximumCount: Int = 64
    ) -> [Int: MeetingReportEvidence] {
        let characterBudget = max(256, maximumCharacters)
        let itemBudget = max(1, maximumCount)
        var unique = [Source]()
        var seen = Set<String>()
        for source in sources {
            let text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard source.turnID >= 0, !text.isEmpty else { continue }
            let key = text.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            guard seen.insert(key).inserted else { continue }
            unique.append(Source(turnID: source.turnID, text: text, prioritized: source.prioritized))
        }
        guard !unique.isEmpty else { return [:] }

        // Reserve a conservative amount for E labels, speaker labels and separators that are
        // added by MeetingsStore after this selection.
        func cost(_ source: Source) -> Int { source.text.count + 56 }
        var selected = Set<Int>()
        var usedCharacters = 0
        func add(_ index: Int) {
            guard selected.count < itemBudget, !selected.contains(index) else { return }
            let next = cost(unique[index])
            guard usedCharacters + next <= characterBudget else { return }
            selected.insert(index)
            usedCharacters += next
        }

        let priority = unique.indices.filter { unique[$0].prioritized }
        if priority.reduce(0, { $0 + cost(unique[$1]) }) <= characterBudget,
            priority.count <= itemBudget
        {
            priority.forEach(add)
        } else {
            evenlySpaced(priority, count: min(itemBudget, 32)).forEach(add)
        }

        let remaining = max(0, itemBudget - selected.count)
        if remaining > 0 {
            let coverage = evenlySpaced(
                Array(unique.indices), count: min(unique.count, remaining)
            )
            if let first = coverage.first { add(first) }
            if let last = coverage.last { add(last) }
            if coverage.count > 2 {
                coverage.dropFirst().dropLast().forEach(add)
            }
        }

        return Dictionary(uniqueKeysWithValues: selected.sorted().enumerated().map { newID, index in
            let source = unique[index]
            return (
                newID,
                MeetingReportEvidence(id: newID, turnID: source.turnID, text: source.text)
            )
        })
    }

    private static func evenlySpaced(_ indices: [Int], count: Int) -> [Int] {
        guard !indices.isEmpty, count > 0 else { return [] }
        if count >= indices.count { return indices }
        if count == 1 { return [indices[indices.count / 2]] }
        var result = [Int]()
        var seen = Set<Int>()
        for slot in 0..<count {
            let position = Int(
                (Double(slot) * Double(indices.count - 1) / Double(count - 1)).rounded()
            )
            let index = indices[position]
            if seen.insert(index).inserted { result.append(index) }
        }
        return result
    }

    /// The model may write prose, but every paragraph must point to passages in its own chunk.
    /// Factual anchors that can be checked mechanically must survive unchanged.
    public static func parse(
        _ output: String, evidence: [Int: MeetingReportEvidence], transcript: SpeakerTranscript,
        allowedDecisionEvidenceIDs: Set<Int> = []
    ) throws -> Self {
        struct Draft: Decodable {
            struct Item: Decodable {
                let t: String
                let e: [Int]

                private enum CodingKeys: String, CodingKey { case t, e }

                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    t = try values.decode(String.self, forKey: .t)
                    if let flat = try? values.decode([Int].self, forKey: .e) {
                        e = flat
                        return
                    }
                    if let labels = try? values.decode([String].self, forKey: .e) {
                        e = try labels.map { label in
                            guard label.first == "E", let id = Int(label.dropFirst()), id >= 0,
                                label == "E\(id)"
                            else {
                                throw DecodingError.dataCorruptedError(
                                    forKey: .e, in: values,
                                    debugDescription: "Expected a canonical evidence label")
                            }
                            return id
                        }
                        return
                    }
                    let nested = try values.decode([[Int]].self, forKey: .e)
                    guard nested.count == 1 else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .e,
                            in: values,
                            debugDescription: "Expected a flat evidence-ID list"
                        )
                    }
                    e = nested[0]
                }
            }
            let p: [Item]
        }
        guard let draft = try? JSONDecoder().decode(Draft.self, from: Data(output.utf8)),
            (1...3).contains(draft.p.count)
        else { throw MeetingReportGenerationError.invalidOutput }

        var paragraphs = [Paragraph]()
        for item in draft.p {
            let prose = item.t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (20...1_200).contains(prose.count),
                !prose.contains("\n"), !prose.hasPrefix("-"), !prose.hasPrefix("#"),
                !prose.contains("<|"), !prose.contains("<think>"),
                prose.last.map({ ".!?…".contains($0) }) == true,
                (1...8).contains(item.e.count),
                Set(item.e).count == item.e.count,
                item.e.allSatisfy({ evidence[$0] != nil })
            else { throw MeetingReportGenerationError.invalidOutput }

            let sources = item.e.compactMap { evidence[$0] }
            let sourceText = sources.map { source in
                let speaker = transcript.turns.first { $0.id == source.turnID }
                    .map { transcript.label(for: $0) } ?? ""
                return speaker + " " + source.text
            }.joined(separator: " ")
            guard numericAnchors(in: prose).isSubset(of: numericAnchors(in: sourceText))
            else { throw MeetingReportGenerationError.invalidSource }
            if assertsSettledDecision(prose),
                !item.e.contains(where: { allowedDecisionEvidenceIDs.contains($0) })
            {
                throw MeetingReportGenerationError.invalidSource
            }
            paragraphs.append(Paragraph(
                text: prose,
                sourceTurnIDs: Array(Set(sources.map(\.turnID))).sorted()))
        }
        return Self(paragraphs: paragraphs)
    }

    /// A source-only paragraph is still readable when Qwen returns malformed or unsupported prose.
    public static func verbatimFallback(
        evidence: [Int: MeetingReportEvidence], transcript: SpeakerTranscript, french: Bool
    ) -> Self {
        let ordered = evidence.values.sorted { $0.id < $1.id }
        guard !ordered.isEmpty else { return Self(paragraphs: [], usesVerbatimFallback: true) }
        let positions = [0, ordered.count / 2, ordered.count - 1]
        var seen = Set<Int>()
        let selected = positions.compactMap { index -> MeetingReportEvidence? in
            let source = ordered[index]
            return seen.insert(source.id).inserted ? source : nil
        }
        let sentences = selected.map { source -> String in
            let speaker = transcript.turns.first { $0.id == source.turnID }
                .flatMap { turn -> String? in
                    guard turn.displayedSpeakerIDs.count == 1,
                        let id = turn.displayedSpeakerIDs.first else { return nil }
                    return transcript.name(for: id, prefix: french ? "Intervenant" : "Speaker")
                }
            let introduction = speaker.map {
                french ? "\($0) indique" : "\($0) says"
            } ?? (french ? "Un passage indique" : "One passage states")
            return "\(introduction) : « \(source.text) »"
        }
        return Self(
            paragraphs: [Paragraph(
                text: sentences.map { $0.hasSuffix(".") ? $0 : $0 + "." }
                    .joined(separator: " "),
                sourceTurnIDs: Array(Set(selected.map(\.turnID))).sorted())],
            usesVerbatimFallback: true)
    }

    private static func numericAnchors(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(numberPattern.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }

    private static let numberPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])\d+(?:[.,:/-]\d+)*(?![\p{L}\p{N}])"#)

    private static func assertsSettledDecision(_ text: String) -> Bool {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return ["a ete approuv", "a ete valid", "ont approuv", "ont valid",
                "a ete decide", "ont decide", "a ete acte", "was approved",
                "was decided", "was agreed", "were approved"].contains {
            folded.contains($0)
        }
    }
}
