import Foundation

/// One text run and the decoder evidence re-aligned to that run.
public struct TranscriptChunk: Equatable, Sendable {
    /// Transcript content for this bounded run.
    public let text: String
    /// Decoder evidence rebased so its offsets address `text`.
    public let evidence: TranscriptEvidence?

    /// Creates one text-and-evidence chunk.
    public init(text: String, evidence: TranscriptEvidence?) {
        self.text = text
        self.evidence = evidence
    }
}

/// Splits a long transcript into runs of whole sentences, each short enough for one bounded
/// polisher call.
///
/// The polisher's cost grows with the length of what it is asked to rewrite while its budget
/// is fixed, so past roughly a hundred words a single call reliably ran out of time — and the
/// user got the deterministic text after the longest wait of all. Sentence runs keep every call
/// inside the budget an ordinary dictation already meets, and a run that fails costs only its
/// own sentences.
public enum TranscriptChunker {
    /// Runs of consecutive sentences holding at most `maximumWords` words each, in order.
    /// Joined back with single spaces they reproduce the text up to whitespace.
    public static func split(_ text: String, maximumWords: Int) -> [String] {
        let limit = max(1, maximumWords)
        var runs = [String]()
        var current = [String]()
        var currentWords = 0

        func flush() {
            if !current.isEmpty {
                runs.append(current.joined(separator: " "))
                current.removeAll()
                currentWords = 0
            }
        }

        for sentence in sentences(in: text) {
            let words = wordCount(sentence)
            if words > limit {
                flush()
                runs.append(contentsOf: pieces(of: sentence, maximumWords: limit))
                continue
            }
            if currentWords + words > limit {
                flush()
            }
            current.append(sentence)
            currentWords += words
        }
        flush()
        return runs
    }

    /// Splits text and evidence together so a run can never inherit offsets from another run.
    public static func split(
        _ text: String,
        evidence: TranscriptEvidence?,
        maximumWords: Int
    ) -> [TranscriptChunk] {
        let runs = split(text, maximumWords: maximumWords)
        guard let alignedEvidence = evidence?.rebased(to: text) else {
            return runs.map { TranscriptChunk(text: $0, evidence: nil) }
        }
        var wordOffset = 0
        return runs.map { run in
            let count = TranscriptEvidenceLexing.lexemes(in: run).count
            let end = min(alignedEvidence.words.count, wordOffset + count)
            let chunkEvidence = alignedEvidence.slice(
                words: wordOffset..<end,
                rebasedTo: run
            )
            wordOffset = end
            return TranscriptChunk(text: run, evidence: chunkEvidence)
        }
    }

    /// Sentences as the recogniser punctuated them: a terminator followed by whitespace or the
    /// end closes one. A full stop inside "5.2" or "23h45.30" is followed by a digit and stays.
    static func sentences(in text: String) -> [String] {
        var result = [String]()
        var current = ""
        var iterator = text.makeIterator()
        var pending: Character? = iterator.next()
        while let character = pending {
            let next = iterator.next()
            current.append(character)
            if terminators.contains(character), next.map(\.isWhitespace) ?? true {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
                current = ""
            }
            pending = next
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            result.append(tail)
        }
        return result
    }

    /// A sentence too long on its own is cut at its clause boundaries, and failing those, at
    /// the word count — better a clean cut than a call that cannot finish.
    static func pieces(of sentence: String, maximumWords: Int) -> [String] {
        var result = [String]()
        var current = [String]()
        var currentWords = 0
        for clause in clauses(in: sentence) {
            let words = wordCount(clause)
            if words > maximumWords {
                if !current.isEmpty {
                    result.append(current.joined(separator: " "))
                    current.removeAll()
                    currentWords = 0
                }
                let tokens = clause.split(whereSeparator: \.isWhitespace).map(String.init)
                for start in stride(from: 0, to: tokens.count, by: maximumWords) {
                    let end = min(tokens.count, start + maximumWords)
                    result.append(tokens[start..<end].joined(separator: " "))
                }
                continue
            }
            if currentWords + words > maximumWords, !current.isEmpty {
                result.append(current.joined(separator: " "))
                current.removeAll()
                currentWords = 0
            }
            current.append(clause)
            currentWords += words
        }
        if !current.isEmpty {
            result.append(current.joined(separator: " "))
        }
        return result
    }

    static func clauses(in sentence: String) -> [String] {
        var result = [String]()
        var current = ""
        var iterator = sentence.makeIterator()
        var pending: Character? = iterator.next()
        while let character = pending {
            let next = iterator.next()
            current.append(character)
            if character == "," || character == ";" || character == ":",
                next.map(\.isWhitespace) ?? true
            {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
                current = ""
            }
            pending = next
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            result.append(tail)
        }
        return result
    }

    static func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
}
