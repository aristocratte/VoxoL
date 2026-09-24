import Foundation

/// A lexical word and its approximate acoustic timing.
public struct SpeakerWord: Sendable {
    /// UTF-16 offsets in the unmodified ASR text.
    public let range: Range<Int>
    /// Start time in seconds from the beginning of the recording.
    public let start: Double?
    /// End time in seconds from the beginning of the recording.
    public let end: Double?

    /// Character offsets use UTF-16, matching Parakeet's word evidence.
    public init(range: Range<Int>, start: Double?, end: Double?) {
        self.range = range
        self.start = start
        self.end = end
    }
}

/// A contiguous portion of the transcript with one attribution.
public struct SpeakerTurn: Codable, Equatable, Identifiable, Sendable {
    /// Stable identifier within its containing document or archive.
    public let id: Int
    /// Start time in seconds from the beginning of the recording.
    public var start: Double
    /// End time in seconds from the beginning of the recording.
    public var end: Double
    /// Anonymous voice slots observed in this result, numbered from zero.
    public let speakerIDs: [Int]
    /// Whether multiple voices were active over these words.
    public let overlapping: Bool
    /// An explicit correction; nil retains the model's original attribution.
    public var correctedSpeakerIDs: [Int]? = nil
    /// Voice slots to display after an optional user correction.
    public var displayedSpeakerIDs: [Int] { correctedSpeakerIDs ?? speakerIDs }
    /// Whether the displayed attribution represents overlapping voices.
    public var displayedOverlap: Bool { correctedSpeakerIDs.map { $0.count > 1 } ?? overlapping }
    /// Unmodified text belonging to this turn, including punctuation.
    public var text: String
}

/// A local, editable speaker-labelled transcript.
public struct SpeakerTranscript: Codable, Equatable, Identifiable, Sendable {
    /// Stable identifier within its containing document or archive.
    public let id: UUID
    /// Time this transcript was produced.
    public let createdAt: Date
    /// User-visible recording title.
    public var title: String
    /// Recording duration in seconds.
    public let duration: Double
    /// Complete text returned by ASR before speaker attribution.
    public let rawText: String
    /// Ordered, timed portions whose concatenated text preserves the raw transcript.
    public var turns: [SpeakerTurn]
    /// User-supplied names for anonymous slots, scoped to this recording.
    public var names: [Int: String]
    /// Immutable revision of the diarization weights used.
    public let diarizationRevision: String

    /// Creates a new value with the supplied local data.
    public init(
        title: String, duration: Double, rawText: String, turns: [SpeakerTurn],
        diarizationRevision: String, id: UUID = UUID(), createdAt: Date = Date()
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.duration = duration
        self.rawText = rawText
        self.turns = turns
        self.names = [:]
        self.diarizationRevision = diarizationRevision
    }

    /// Anonymous voice slots observed in this result, numbered from zero.
    public var speakerIDs: [Int] { Set(turns.flatMap(\.speakerIDs)).sorted() }

    /// Returns the entered name, or a numbered voice label.
    public func name(for id: Int, prefix: String = "Speaker") -> String {
        let custom = names[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? "\(prefix) \(id + 1)" : custom
    }

    /// Formats an attribution, retaining ambiguity when no speaker is assigned.
    public func label(
        for turn: SpeakerTurn, prefix: String = "Speaker", unknown: String = "Uncertain speaker"
    ) -> String {
        turn.displayedSpeakerIDs.isEmpty
            ? unknown
            : turn.displayedSpeakerIDs.map { name(for: $0, prefix: prefix) }.joined(
                separator: " + ")
    }

    /// Exports timestamped turns with the current speaker names.
    public func plainText(
        prefix: String = "Speaker", unknown: String = "Uncertain speaker",
        overlap: String = "Overlapping voices"
    ) -> String {
        turns.map { turn in
            let suffix = turn.displayedOverlap ? " (\(overlap))" : ""
            return
                "[\(Self.timestamp(turn.start))] \(label(for: turn, prefix: prefix, unknown: unknown))\(suffix)\n\(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n\n")
    }

    /// Exports SubRip cues with labels and overlap indications.
    public func subtitles(
        prefix: String = "Speaker", unknown: String = "Uncertain speaker",
        overlap: String = "Overlapping voices"
    ) -> String {
        turns.enumerated().map { index, turn in
            let suffix = turn.displayedOverlap ? " (\(overlap))" : ""
            let name = label(for: turn, prefix: prefix, unknown: unknown)
                .replacingOccurrences(of: "\n", with: " ")
            return
                "\(index + 1)\n\(Self.timestamp(turn.start, milliseconds: true)) --> \(Self.timestamp(turn.end, milliseconds: true))\n\(name)\(suffix): \(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }.joined(separator: "\n")
    }

    /// Formats a timestamp for the UI or a SubRip file.
    public static func timestamp(_ seconds: Double, milliseconds: Bool = false) -> String {
        let bounded = seconds.isFinite ? min(359_999, max(0, seconds)) : 0
        let ms = Int((bounded * 1000).rounded())
        let base = String(
            format: "%02d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60)
        return milliseconds ? base + String(format: ",%03d", ms % 1000) : base
    }
}

/// Word times are approximate ASR evidence. Ambiguous boundaries stay unassigned;
/// simultaneous speaker activity does not identify which overlapping voice said a word.
public enum SpeakerAttribution {
    /// Aligns lexical words with the 10 ms speaker timeline without rewriting the text.
    public static func turns(
        text: String, words: [SpeakerWord], probabilities: [Float], frameCount: Int,
        duration: Double, speakerCount: Int = 8
    ) throws -> [SpeakerTurn] {
        guard duration.isFinite, duration > 0, duration <= 3600, speakerCount > 0,
            speakerCount <= 8,
            frameCount >= 0, frameCount <= Int.max / speakerCount,
            probabilities.count == frameCount * speakerCount,
            probabilities.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
        else { throw SpeakerError.invalidTimeline }
        guard !text.isEmpty else { return [] }
        let source = text as NSString
        guard !words.isEmpty else {
            return [
                .init(
                    id: 0, start: 0, end: duration, speakerIDs: [], overlapping: false, text: text)
            ]
        }
        var previousEnd = 0
        for word in words {
            guard word.range.lowerBound >= previousEnd, !word.range.isEmpty,
                word.range.upperBound <= source.length,
                Range(NSRange(word.range), in: text) != nil
            else { throw SpeakerError.invalidWordRanges }
            previousEnd = word.range.upperBound
        }
        var turns: [SpeakerTurn] = []
        for (index, word) in words.enumerated() {
            let validTime =
                word.start.map { $0.isFinite && $0 >= 0 && $0 < duration } == true
                && word.end.map { $0.isFinite && $0 > (word.start ?? 0) } == true
            let start = validTime ? (word.start ?? 0) : (turns.last?.end ?? 0)
            let nextStart = index + 1 < words.count ? words[index + 1].start : nil
            var end =
                validTime ? min((word.end ?? duration), duration) : min(duration, start + 0.08)
            if let nextStart, nextStart.isFinite, nextStart > start { end = min(end, nextStart) }
            let assignment =
                validTime
                ? assign(
                    start: start, end: end, probabilities: probabilities, frames: frameCount,
                    count: speakerCount)
                : (ids: [Int](), overlapping: false)
            let lo = index == 0 ? 0 : word.range.lowerBound
            let hi = index + 1 < words.count ? words[index + 1].range.lowerBound : source.length
            let fragment = source.substring(with: NSRange(location: lo, length: hi - lo))
            if let last = turns.last, last.speakerIDs == assignment.ids,
                last.overlapping == assignment.overlapping, start - last.end < 1.25,
                end - last.start < 15
            {
                turns[turns.count - 1].text += fragment
                turns[turns.count - 1].end = max(last.end, end)
            } else {
                turns.append(
                    .init(
                        id: turns.count, start: start, end: end, speakerIDs: assignment.ids,
                        overlapping: assignment.overlapping, text: fragment
                    ))
            }
        }
        return turns
    }

    private static func assign(
        start: Double, end: Double, probabilities: [Float], frames: Int, count: Int
    ) -> (ids: [Int], overlapping: Bool) {
        let lo = min(frames, Int(start * 100)), hi = min(frames, Int(ceil(end * 100)))
        guard hi > lo else { return ([], false) }
        var means = [Float](repeating: 0, count: count)
        var overlapFrames = 0
        for frame in lo..<hi {
            var active = 0
            for speaker in 0..<count {
                let p = probabilities[frame * count + speaker]
                means[speaker] += p / Float(hi - lo)
                if p >= 0.5 { active += 1 }
            }
            if active > 1 { overlapFrames += 1 }
        }
        let ranked = (0..<count).sorted { means[$0] > means[$1] }
        guard let best = ranked.first, means[best] >= 0.5 else { return ([], false) }
        let candidates = ranked.filter { means[$0] >= 0.4 && means[$0] >= means[best] * 0.65 }
        if candidates.count > 1 {
            if Double(overlapFrames) / Double(hi - lo) >= 0.2 {
                return (candidates.sorted(), true)
            }
            if means[best] - means[candidates[1]] < 0.15 { return ([], false) }
        }
        return ([best], false)
    }
}

/// Recoverable failures in local speaker processing.
public enum SpeakerError: LocalizedError {
    case invalidTimeline, invalidWordRanges, invalidAudio, modelIntegrity, archiveVersion

    /// A description suitable for an error message.
    public var errorDescription: String? {
        switch self {
        case .invalidTimeline: "Invalid speaker activity timeline."
        case .invalidWordRanges: "The transcript could not be aligned to its words."
        case .invalidAudio: "Choose a non-empty audio file of at most one hour."
        case .modelIntegrity: "Speaker model verification failed. Download the model again."
        case .archiveVersion: "This meeting archive was created by an unsupported version."
        }
    }
}

/// Serializes access to a versioned local transcript archive.
public actor SpeakerArchiveStore {
    private struct Archive: Codable {
        var version = 1
        var transcripts: [SpeakerTranscript]
    }
    private let url: URL
    /// Creates a new value with the supplied local data.
    public init(url: URL) { self.url = url }

    /// Reads the archive; rejects unsupported versions.
    public func load() throws -> [SpeakerTranscript] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw SpeakerError.archiveVersion }
        return archive.transcripts
    }

    /// Atomically saves transcripts with owner-only file permissions.
    public func save(_ transcripts: [SpeakerTranscript]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(transcripts: transcripts)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
