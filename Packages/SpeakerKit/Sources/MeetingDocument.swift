import Foundation

/// Editorial intent supplied to the local writer without imposing fixed section headings.
public enum MeetingReportStyle: String, CaseIterable, Sendable {
    case complete, concise, technical, followup

    /// Writing guidance for the selected document variant.
    public var instruction: String {
        switch self {
        case .complete:
            "Write a complete, readable report covering the substantive discussion and its reasons."
        case .concise:
            "Write a short executive summary in 2-4 paragraphs, focusing on the main issues and actual outcomes."
        case .technical:
            "Write a technical brief explaining the observed problem, alternatives, explicit trade-offs and next steps when supported."
        case .followup:
            "Write a follow-up brief in prose, with a short task list only for explicit commitments. Do not add a greeting, recipients or signature."
        }
    }
}

/// Portable document semantics shared by the editor, generation and exports.
public struct MeetingDocument: Codable, Equatable, Sendable {
    /// Version of the semantic document schema.
    public var version = 1
    /// Editable display title; never used as proof of spoken content.
    public var title: String
    /// Ordered paragraphs, headings and lists composing the document.
    public var blocks: [MeetingDocumentBlock]
    /// Optional explanation of source selection or limited coverage.
    public var coverageNotice: String?

    /// Creates this value from explicit document or source data.
    public init(title: String, blocks: [MeetingDocumentBlock] = [], coverageNotice: String? = nil) {
        self.title = title
        self.blocks = blocks
        self.coverageNotice = coverageNotice
    }

    /// Document body without formatting or source annotations.
    public var plainText: String { blocks.map(\.text).joined(separator: "\n\n") }

    /// Exports supported Markdown styles; highlights retain their text and sources are optional.
    public func markdown(includeSources: Bool = true, transcript: SpeakerTranscript? = nil)
        -> String
    {
        var lines = ["# " + title, ""]
        for block in blocks {
            let prefix: String
            switch block.kind {
            case .heading: prefix = "## "
            case .subheading: prefix = "### "
            case .bullet: prefix = "- "
            case .numbered: prefix = "1. "
            case .task: prefix = block.checked ? "- [x] " : "- [ ] "
            case .quote: prefix = "> "
            case .paragraph: prefix = ""
            }
            let content = block.runs.map { run in
                var text = run.text
                for character in ["\\", "*", "_", "[", "]", "`"] {
                    text = text.replacingOccurrences(of: character, with: "\\" + character)
                }
                if run.bold { text = "**\(text)**" }
                if run.italic { text = "*\(text)*" }
                // Highlight is a visual style; plain Markdown intentionally retains its text.
                if let link = run.link, let url = URL(string: link),
                    ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
                {
                    text =
                        "[\(text)](\(url.absoluteString.replacingOccurrences(of: ")", with: "%29")))"
                }
                return text
            }.joined()
            lines += [prefix + content, ""]
            if includeSources, !block.sourceTurnIDs.isEmpty {
                let sources = block.sourceTurnIDs.map { id in
                    if let turn = transcript?.turns.first(where: { $0.id == id }) {
                        return SpeakerTranscript.timestamp(turn.start)
                    }
                    return "#\(id)"
                }.joined(separator: " · ")
                lines += ["_Sources : \(sources)_", ""]
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Legacy Markdown remains in the draft/revision as a lossless migration backup.
    public static func migrating(_ markdown: String, transcript: SpeakerTranscript? = nil) -> Self {
        var result = Self(title: transcript?.title ?? "")
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("# "), result.blocks.isEmpty {
                result.title = String(line.dropFirst(2)); continue
            }
            if line.hasPrefix("_Sources : "), let last = result.blocks.indices.last,
                let transcript
            {
                result.blocks[last].sourceTurnIDs = transcript.turns.filter {
                    line.contains(SpeakerTranscript.timestamp($0.start))
                }.map(\.id)
                continue
            }
            var kind: MeetingDocumentBlock.Kind = .paragraph
            var text = line
            var checked = false
            for (prefix, type) in [
                ("### ", MeetingDocumentBlock.Kind.subheading),
                ("## ", .heading), ("- [ ] ", .task), ("- [x] ", .task),
                ("- ", .bullet), ("* ", .bullet), ("> ", .quote),
            ]
            where line.hasPrefix(prefix) {
                kind = type; text = String(line.dropFirst(prefix.count))
                checked = prefix == "- [x] "
                break
            }
            if kind == .paragraph,
                let range = line.range(of: #"^\d+\. "#, options: .regularExpression)
            {
                kind = .numbered; text = String(line[range.upperBound...])
            }
            result.blocks.append(
                MeetingDocumentBlock(
                    kind: kind, runs: MeetingTextRun.parseInline(text), checked: checked))
        }
        return result
    }
}

/// A contiguous text span with portable inline formatting.
public struct MeetingTextRun: Codable, Equatable, Sendable {
    /// Plain text represented by this value.
    public var text: String
    /// Whether this span uses bold emphasis.
    public var bold: Bool
    /// Whether this span uses italic emphasis.
    public var italic: Bool
    /// Whether this span receives a restrained background highlight.
    public var highlighted: Bool
    /// Optional HTTP, HTTPS or mail link; unsupported schemes are excluded by renderers.
    public var link: String?

    /// Creates this value from explicit document or source data.
    public init(
        _ text: String, bold: Bool = false, italic: Bool = false,
        highlighted: Bool = false, link: String? = nil
    ) {
        self.text = text; self.bold = bold; self.italic = italic
        self.highlighted = highlighted; self.link = link
    }

    /// Imports the inline Markdown subset supported by existing meeting drafts.
    public static func parseInline(_ text: String) -> [Self] {
        var runs = [Self]()
        var buffer = ""
        var bold = false, italic = false, highlight = false
        var cursor = text.startIndex
        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(Self(buffer, bold: bold, italic: italic, highlighted: highlight))
            buffer = ""
        }
        while cursor < text.endIndex {
            let rest = text[cursor...]
            if rest.hasPrefix("\\"), text.index(after: cursor) < text.endIndex {
                cursor = text.index(after: cursor); buffer.append(text[cursor])
                cursor = text.index(after: cursor); continue
            }
            if rest.hasPrefix("**") || rest.hasPrefix("==") {
                flush()
                if rest.hasPrefix("**") { bold.toggle() } else { highlight.toggle() }
                cursor = text.index(cursor, offsetBy: 2); continue
            }
            if text[cursor] == "*" || text[cursor] == "_" {
                flush(); italic.toggle(); cursor = text.index(after: cursor); continue
            }
            if text[cursor] == "[", let close = rest.range(of: "]("),
                let end = text[close.upperBound...].firstIndex(of: ")")
            {
                let address = String(text[close.upperBound..<end])
                if let url = URL(string: address),
                    ["https", "http", "mailto"].contains(url.scheme ?? "")
                {
                    flush()
                    runs.append(
                        Self(
                            String(text[text.index(after: cursor)..<close.lowerBound]),
                            bold: bold, italic: italic, highlighted: highlight, link: address))
                    cursor = text.index(after: end); continue
                }
            }
            buffer.append(text[cursor]); cursor = text.index(after: cursor)
        }
        flush()
        return runs.isEmpty ? [Self("")] : runs
    }
}

/// One editable paragraph or list item with its transcript provenance.
public struct MeetingDocumentBlock: Codable, Equatable, Identifiable, Sendable {
    /// Semantic paragraph style used consistently by editing and export.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case paragraph, heading, subheading, bullet, numbered, task, quote
    }
    /// Stable identity used across editing and persistence.
    public var id: UUID
    /// The paragraph or list style of this block.
    public var kind: Kind
    /// Ordered inline spans that make up this paragraph.
    public var runs: [MeetingTextRun]
    /// Stable transcript turn identifiers supporting this block.
    public var sourceTurnIDs: [Int]
    /// True after wording changes may have invalidated the original citations.
    public var sourcesNeedReview: Bool
    /// Completion state for a task block, independent of the recorded conversation.
    public var checked: Bool
    /// Plain text represented by this value.
    public var text: String { runs.map(\.text).joined() }

    /// Creates this value from explicit document or source data.
    public init(
        id: UUID = UUID(), kind: Kind = .paragraph, runs: [MeetingTextRun],
        sourceTurnIDs: [Int] = [], sourcesNeedReview: Bool = false, checked: Bool = false
    ) {
        self.id = id; self.kind = kind; self.runs = runs; self.sourceTurnIDs = sourceTurnIDs
        self.sourcesNeedReview = sourcesNeedReview; self.checked = checked
    }
}

/// A restorable document snapshot or a pending generated proposal.
public struct MeetingReportVersion: Codable, Equatable, Identifiable, Sendable {
    /// Stable identity used across editing and persistence.
    public var id: UUID
    /// Time the document snapshot was created.
    public var date: Date
    /// Semantic document retained in this snapshot.
    public var document: MeetingDocument
    /// Fingerprint of the transcript evidence used to create this version.
    public var sourceFingerprint: String
    /// Optional local generator identifier; nil for an entirely manual draft.
    public var generator: String?
    /// Original Markdown retained when a legacy document is migrated.
    public var legacyMarkdown: String?

    /// Creates this value from explicit document or source data.
    public init(
        document: MeetingDocument, sourceFingerprint: String, generator: String?,
        legacyMarkdown: String? = nil
    ) {
        id = UUID(); date = Date(); self.document = document
        self.sourceFingerprint = sourceFingerprint; self.generator = generator
        self.legacyMarkdown = legacyMarkdown
    }
}

/// A local event snapshot; calendar changes do not rewrite past meeting evidence.
public struct MeetingCalendarLink: Codable, Equatable, Sendable {
    /// Calendar occurrence identity, including the occurrence date.
    public var eventID: String
    /// Editable display title; never used as proof of spoken content.
    public var title: String
    /// Scheduled start of this calendar occurrence.
    public var start: Date
    /// Scheduled end of this calendar occurrence.
    public var end: Date
    /// Display name of the source calendar.
    public var calendar: String
    /// Time-zone identifier associated with the event snapshot.
    public var timeZone: String
    /// Creates this value from explicit document or source data.
    public init(
        eventID: String, title: String, start: Date, end: Date,
        calendar: String, timeZone: String
    ) {
        self.eventID = eventID; self.title = title; self.start = start; self.end = end
        self.calendar = calendar; self.timeZone = timeZone
    }
}

/// A private local bookmark allowing playback of the original media.
public struct MeetingAudioReference: Codable, Equatable, Sendable {
    /// Security-scoped bookmark data, excluded from transcript exports.
    public var bookmark: Data
    /// Display filename for the linked local media.
    public var filename: String
    /// Creates this value from explicit document or source data.
    public init(bookmark: Data, filename: String) {
        self.bookmark = bookmark; self.filename = filename
    }
}

/// A personal bookmark captured on the recording timeline.
public struct MeetingMarker: Codable, Equatable, Identifiable, Sendable {
    /// Stable identity used across editing and persistence.
    public var id = UUID()
    /// Position in the saved audio, with recording pauses excluded.
    public var time: Double
    /// User-authored annotation, kept separate from spoken evidence.
    public var note: String
    /// Creates this value from explicit document or source data.
    public init(time: Double, note: String = "") { self.time = time; self.note = note }
}
