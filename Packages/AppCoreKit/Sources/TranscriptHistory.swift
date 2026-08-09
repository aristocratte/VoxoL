import Foundation

/// One recoverable text value that preceded a transcript edit.
public struct TranscriptRevision: Codable, Equatable, Identifiable, Sendable {
    /// A stable identifier for list rendering and serialization.
    public let id: UUID

    /// The transcript text before the edit.
    public let text: String

    /// When the replacement was made.
    public let createdAt: Date

    /// Creates a recoverable transcript revision.
    public init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// A locally retained dictation result and its recoverable revisions.
public struct TranscriptRecord: Codable, Equatable, Identifiable, Sendable {
    /// A stable identifier for this dictation.
    public let id: UUID

    /// When the dictation completed.
    public let createdAt: Date

    /// The user-facing name of the destination application.
    public let applicationName: String

    /// The destination bundle identifier, when available.
    public let applicationBundleIdentifier: String?

    /// The latest retained transcript text.
    public var text: String

    /// The measured speaking duration used to calculate rate.
    public let durationSeconds: TimeInterval

    /// Earlier text values ordered from oldest to newest.
    public var revisions: [TranscriptRevision]

    /// Values removed by undo, newest last, awaiting redo.
    public var undoneRevisions: [TranscriptRevision] = []

    /// An opt-in path relative to VoxoL's application-support directory.
    public let audioRelativePath: String?

    /// Whether this record is a non-persistent Debug fixture.
    public let isExample: Bool

    /// Creates a locally retained transcript record.
    public init(
        id: UUID = UUID(),
        createdAt: Date,
        applicationName: String,
        applicationBundleIdentifier: String? = nil,
        text: String,
        durationSeconds: TimeInterval,
        revisions: [TranscriptRevision] = [],
        audioRelativePath: String? = nil,
        isExample: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.applicationName = applicationName
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.text = text
        self.durationSeconds = durationSeconds
        self.revisions = revisions
        self.audioRelativePath = audioRelativePath
        self.isExample = isExample
    }

    /// Decodes a record, tolerating history written before redo existed.
    ///
    /// Worth the boilerplate: the synthesized decoder treats a missing key as a
    /// failure even when the property has a default, so shipping `undoneRevisions`
    /// without this would have made every previously saved `transcripts.json`
    /// throw on load — and the store answers a load failure by falling back to
    /// example data, which reads exactly like the user's history being erased by
    /// an update.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        applicationName = try container.decode(String.self, forKey: .applicationName)
        applicationBundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .applicationBundleIdentifier
        )
        text = try container.decode(String.self, forKey: .text)
        durationSeconds = try container.decode(TimeInterval.self, forKey: .durationSeconds)
        revisions = try container.decode([TranscriptRevision].self, forKey: .revisions)
        undoneRevisions =
            try container.decodeIfPresent(
                [TranscriptRevision].self,
                forKey: .undoneRevisions
            ) ?? []
        audioRelativePath = try container.decodeIfPresent(String.self, forKey: .audioRelativePath)
        isExample = try container.decodeIfPresent(Bool.self, forKey: .isExample) ?? false
    }

    /// The whitespace-delimited number of words in the current text.
    public var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// The rounded speaking rate derived from words and duration.
    public var wordsPerMinute: Int {
        guard durationSeconds > 0, wordCount > 0 else {
            return 0
        }
        return Int((Double(wordCount) / durationSeconds * 60).rounded())
    }

    /// Whether an earlier transcript value can be restored.
    public var canUndo: Bool {
        !revisions.isEmpty
    }

    /// Whether an undone value can be put back.
    public var canRedo: Bool {
        !undoneRevisions.isEmpty
    }

    /// Restores the most recent revision, if one exists.
    ///
    /// The displaced text is kept rather than dropped. Undo used to destroy it,
    /// which made the first press irreversible: the polished text became the
    /// raw transcript and there was no way back to compare the two, so the one
    /// question worth asking — what did the model actually change? — could not
    /// be answered twice.
    @discardableResult
    public mutating func undoLastEdit(at date: Date = Date()) -> Bool {
        guard let revision = revisions.popLast() else {
            return false
        }
        undoneRevisions.append(TranscriptRevision(text: text, createdAt: date))
        text = revision.text
        return true
    }

    /// Restores the most recently undone value, if one exists.
    @discardableResult
    public mutating func redoLastEdit(at date: Date = Date()) -> Bool {
        guard let undone = undoneRevisions.popLast() else {
            return false
        }
        revisions.append(TranscriptRevision(text: text, createdAt: date))
        text = undone.text
        return true
    }

    /// Replaces the text after preserving its current value for one-step recovery.
    public mutating func replaceText(with newText: String, at date: Date = Date()) {
        guard newText != text else {
            return
        }
        revisions.append(TranscriptRevision(text: text, createdAt: date))
        // A fresh edit forks the history: the versions that were undone are no
        // longer reachable from here, and keeping them would let redo jump to
        // text that never followed this one.
        undoneRevisions.removeAll()
        text = newText
    }

    /// The transcript as the recogniser produced it, before any later revision.
    ///
    /// Held at the bottom of the undo stack rather than in its own field, so it
    /// stays correct whichever direction the user has stepped through.
    public var originalText: String {
        revisions.first?.text ?? text
    }
}

/// Aggregate activity metrics calculated from retained transcript records.
public struct TranscriptHistoryMetrics: Equatable, Sendable {
    /// Total retained words.
    public let words: Int

    /// Rate computed from total words divided by total speaking time.
    public let averageWordsPerMinute: Int

    /// Number of retained dictations.
    public let sessions: Int

    /// Total measured speaking duration.
    public let speakingSeconds: TimeInterval

    /// Calculates aggregate metrics for the supplied records.
    public init(records: [TranscriptRecord]) {
        words = records.reduce(0) { $0 + $1.wordCount }
        sessions = records.count
        speakingSeconds = records.reduce(0) { $0 + max(0, $1.durationSeconds) }
        averageWordsPerMinute =
            speakingSeconds > 0
            ? Int((Double(words) / speakingSeconds * 60).rounded())
            : 0
    }
}

/// The versioned JSON envelope stored in Application Support.
public struct TranscriptArchive: Codable, Equatable, Sendable {
    /// The only archive schema understood by this build.
    public static let currentSchemaVersion = 1

    /// The schema version encoded in this archive.
    public let schemaVersion: Int

    /// Locally retained transcript records.
    public var records: [TranscriptRecord]

    /// Creates a versioned transcript archive.
    public init(schemaVersion: Int = currentSchemaVersion, records: [TranscriptRecord]) {
        self.schemaVersion = schemaVersion
        self.records = records
    }
}

/// A word-level difference between what the microphone heard and what VoxoL wrote.
///
/// The raw transcript is kept as the first revision of a record, so this compares two real
/// strings — never a reconstruction. Tokens are compared exactly, punctuation included: adding a
/// comma or a capital *is* the work, and hiding it would misrepresent what happened.
public enum TranscriptDiff {
    /// What happened to one word between the two texts.
    public enum Change: Equatable {
        /// Heard and kept as it was.
        case unchanged
        /// Heard, and not in the finished text.
        case removed
        /// Written by VoxoL, and not in what was heard.
        case added
    }

    /// One word of the comparison, in reading order.
    public struct Token: Identifiable, Equatable {
        /// Position in the comparison.
        public let id: Int
        /// The word itself, exactly as it appears in its own text.
        public let text: String
        /// What happened to it.
        public let change: Change
    }

    /// Beyond this many words the quadratic table stops being worth it and the comparison is
    /// skipped rather than freezing the interface.
    private static let wordLimit = 600

    /// Returns nil when the two texts are identical or too long to compare.
    public static func tokens(raw: String, final finalText: String) -> [Token]? {
        let old = words(raw)
        let new = words(finalText)
        guard old != new, !old.isEmpty, !new.isEmpty else { return nil }
        guard old.count <= wordLimit, new.count <= wordLimit else { return nil }

        // Longest common subsequence, then a walk back through the table.
        var lengths = Array(
            repeating: Array(repeating: 0, count: new.count + 1),
            count: old.count + 1
        )
        for oldIndex in stride(from: old.count - 1, through: 0, by: -1) {
            for newIndex in stride(from: new.count - 1, through: 0, by: -1) {
                lengths[oldIndex][newIndex] =
                    old[oldIndex] == new[newIndex]
                    ? lengths[oldIndex + 1][newIndex + 1] + 1
                    : max(lengths[oldIndex + 1][newIndex], lengths[oldIndex][newIndex + 1])
            }
        }

        var tokens: [Token] = []
        var oldIndex = 0
        var newIndex = 0
        func append(_ text: String, _ change: Change) {
            tokens.append(Token(id: tokens.count, text: text, change: change))
        }

        while oldIndex < old.count, newIndex < new.count {
            if old[oldIndex] == new[newIndex] {
                append(old[oldIndex], .unchanged)
                oldIndex += 1
                newIndex += 1
            } else if lengths[oldIndex + 1][newIndex] >= lengths[oldIndex][newIndex + 1] {
                append(old[oldIndex], .removed)
                oldIndex += 1
            } else {
                append(new[newIndex], .added)
                newIndex += 1
            }
        }
        while oldIndex < old.count {
            append(old[oldIndex], .removed)
            oldIndex += 1
        }
        while newIndex < new.count {
            append(new[newIndex], .added)
            newIndex += 1
        }
        return tokens
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
