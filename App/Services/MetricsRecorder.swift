import FidelityKit
import Foundation
import PersonalizationKit
import TextProcessingKit

/// Content-free per-dictation metrics, appended locally as JSON lines.
///
/// The product's real question is not the word error rate on a frozen corpus —
/// it is "how often does a dictation need no retouching, and how expensive is
/// the retouching when it happens". Answering that requires remembering, for
/// every dictation, that it happened and what became of it, without keeping
/// any of its words: numbers, kinds and timings only, so the log stays
/// harmless even read aloud. `Scripts/weekly-kpis.py` turns it into the five
/// numbers worth tracking.
@MainActor
enum MetricsRecorder {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("VoxoL/Metrics/dictations.jsonl")
    }

    /// One inserted dictation.
    static func recordDictation(
        id: UUID,
        wordCount: Int,
        mode: String,
        language: String,
        bundleIdentifier: String?,
        route: String,
        releaseToTextMilliseconds: Int?
    ) {
        append([
            "type": "dictation",
            "id": id.uuidString,
            "ts": Int(Date().timeIntervalSince1970),
            "words": wordCount,
            "mode": mode,
            "language": language,
            "app": bundleIdentifier ?? "unknown",
            "route": route,
            "latencyMs": releaseToTextMilliseconds as Any? ?? NSNull(),
        ])
    }

    /// What the destination field said became of it.
    static func recordOutcome(
        id: UUID,
        outcome: InsertionCorrection.Outcome,
        insertedText: String,
        currentSpan: String?
    ) {
        var payload: [String: Any] = [
            "type": "outcome",
            "id": id.uuidString,
            "ts": Int(Date().timeIntervalSince1970),
            "outcome": label(for: outcome),
        ]
        if case .corrected(let corrected) = outcome {
            payload["wordEdits"] = wordEditDistance(insertedText, corrected)
            payload["criticalTouched"] = criticalTouched(
                inserted: insertedText,
                corrected: corrected
            )
        } else if let currentSpan, currentSpan != insertedText {
            payload["wordEdits"] = wordEditDistance(insertedText, currentSpan)
        }
        append(payload)
    }

    private static func label(for outcome: InsertionCorrection.Outcome) -> String {
        switch outcome {
        case .unchanged: "unchanged"
        case .corrected: "corrected"
        case .continued: "continued"
        case .editedElsewhere: "editedElsewhere"
        case .rewritten: "rewritten"
        }
    }

    /// Word-level edit distance — the unit users feel, unlike characters.
    static func wordEditDistance(_ left: String, _ right: String) -> Int {
        let a = DictionaryLearning.words(left).map { $0.lowercased() }
        let b = DictionaryLearning.words(right).map { $0.lowercased() }
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i]
            for j in 1...b.count {
                let substitution: Int = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                let deletion: Int = previous[j] + 1
                let insertion: Int = current[j - 1] + 1
                current.append(min(substitution, deletion, insertion))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Whether the correction touched a meaning-critical word — the release
    /// blocker class: a user manually restoring a "aucun" the pipeline lost.
    static func criticalTouched(inserted: String, corrected: String) -> Bool {
        let language: TextLanguage =
            LanguageDetector.detect(corrected) == .french ? .french : .english
        let critical = SpanRepair.criticalWords(for: language)
        func counts(_ text: String) -> [String: Int] {
            DictionaryLearning.words(text)
                .map { DictionaryLearning.fold($0) }
                .filter { critical.contains($0) }
                .reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        return counts(inserted) != counts(corrected)
    }

    private static func append(_ payload: [String: Any]) {
        guard !UserDefaults.standard.bool(forKey: "voxol.privateMode") else { return }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        else { return }
        let url = fileURL
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}
