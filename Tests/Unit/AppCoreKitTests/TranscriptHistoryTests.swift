import AppCoreKit
import Foundation
import XCTest

final class TranscriptHistoryTests: XCTestCase {
    func testRecordCalculatesWordsAndSpeakingRate() {
        let record = TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: 0),
            applicationName: "Notes",
            text: "One two\nthree   four five",
            durationSeconds: 30
        )

        XCTAssertEqual(record.wordCount, 5)
        XCTAssertEqual(record.wordsPerMinute, 10)
    }

    func testMetricsUseTotalSpeakingTime() {
        let records = [
            TranscriptRecord(
                createdAt: Date(timeIntervalSince1970: 0),
                applicationName: "Mail",
                text: "one two three four five",
                durationSeconds: 30
            ),
            TranscriptRecord(
                createdAt: Date(timeIntervalSince1970: 1),
                applicationName: "Notes",
                text: "six seven eight nine ten",
                durationSeconds: 30
            ),
        ]

        let metrics = TranscriptHistoryMetrics(records: records)

        XCTAssertEqual(metrics.words, 10)
        XCTAssertEqual(metrics.sessions, 2)
        XCTAssertEqual(metrics.speakingSeconds, 60)
        XCTAssertEqual(metrics.averageWordsPerMinute, 10)
    }

    func testUndoRestoresPreviousText() {
        var record = TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: 0),
            applicationName: "Mail",
            text: "Original",
            durationSeconds: 4
        )
        record.replaceText(with: "Edited", at: Date(timeIntervalSince1970: 1))

        XCTAssertTrue(record.canUndo)
        XCTAssertTrue(record.undoLastEdit())
        XCTAssertEqual(record.text, "Original")
        XCTAssertFalse(record.canUndo)
    }

    func testRedoPutsBackWhatUndoTookAway() {
        var record = TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: 0),
            applicationName: "Mail",
            text: "Original",
            durationSeconds: 4
        )
        record.replaceText(with: "Edited", at: Date(timeIntervalSince1970: 1))
        record.undoLastEdit(at: Date(timeIntervalSince1970: 2))

        XCTAssertTrue(record.canRedo)
        XCTAssertTrue(record.redoLastEdit(at: Date(timeIntervalSince1970: 3)))
        XCTAssertEqual(record.text, "Edited")
        XCTAssertFalse(record.canRedo)
        // Stepping forward must leave undo available again, or the pair is a
        // one-way trip in the other direction.
        XCTAssertTrue(record.canUndo)
    }

    func testAFreshEditDropsTheRedoBranch() {
        var record = TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: 0),
            applicationName: "Mail",
            text: "Original",
            durationSeconds: 4
        )
        record.replaceText(with: "Edited", at: Date(timeIntervalSince1970: 1))
        record.undoLastEdit(at: Date(timeIntervalSince1970: 2))
        record.replaceText(with: "Rewritten", at: Date(timeIntervalSince1970: 3))

        // "Edited" no longer follows from here; offering to redo into it would
        // jump to text that never succeeded the current value.
        XCTAssertFalse(record.canRedo)
        XCTAssertEqual(record.text, "Rewritten")
    }

    func testHistorySavedBeforeRedoExistedStillLoads() throws {
        // The synthesized decoder fails on a missing key even when the property
        // has a default, and the store answers a decode failure by showing
        // example data — which looks precisely like an update wiping the user's
        // history. This is the regression guard for that.
        let legacy = """
            {
              "id": "8C1B6E1E-5F2B-4E9A-9B3E-2E4F6A1C7D90",
              "createdAt": 0,
              "applicationName": "Mail",
              "text": "Original",
              "durationSeconds": 4,
              "revisions": []
            }
            """
        let decoder = JSONDecoder()
        let record = try decoder.decode(
            TranscriptRecord.self,
            from: XCTUnwrap(legacy.data(using: .utf8))
        )

        XCTAssertEqual(record.text, "Original")
        XCTAssertFalse(record.canRedo)
        XCTAssertFalse(record.isExample)
    }

    func testAudioIsOptInAtRecordLevel() {
        let record = TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: 0),
            applicationName: "Mail",
            text: "Private by default",
            durationSeconds: 3
        )

        XCTAssertNil(record.audioRelativePath)
    }
}

final class TranscriptDiffTests: XCTestCase {
    func testIdenticalTextsProduceNoDiff() {
        XCTAssertNil(
            TranscriptDiff.tokens(raw: "send it wednesday", final: "send it wednesday")
        )
    }

    func testEmptyRawProducesNoDiff() {
        XCTAssertNil(TranscriptDiff.tokens(raw: "   ", final: "Send it Wednesday."))
    }

    func testKeptWordsAreUnchangedAndEditsAreMarked() throws {
        let tokens = try XCTUnwrap(
            TranscriptDiff.tokens(
                raw: "um send it tuesday no wednesday morning",
                final: "Send it Wednesday morning."
            )
        )

        // Reading only what survived must give back the raw transcript…
        let heard =
            tokens
            .filter { $0.change != .added }
            .map(\.text)
            .joined(separator: " ")
        XCTAssertEqual(heard, "um send it tuesday no wednesday morning")

        // …and reading only what the model kept or wrote must give back the final text.
        let written =
            tokens
            .filter { $0.change != .removed }
            .map(\.text)
            .joined(separator: " ")
        XCTAssertEqual(written, "Send it Wednesday morning.")

        XCTAssertTrue(tokens.contains { $0.text == "um" && $0.change == .removed })
        XCTAssertTrue(tokens.contains { $0.text == "morning." && $0.change == .added })
        XCTAssertTrue(tokens.contains { $0.text == "morning" && $0.change == .removed })
    }

    func testCommonWordsAreNotRepeatedAsEdits() throws {
        let tokens = try XCTUnwrap(
            TranscriptDiff.tokens(raw: "hello lea we are good", final: "Hello Lea, we are good.")
        )

        let unchanged = tokens.filter { $0.change == .unchanged }.map(\.text)
        XCTAssertEqual(unchanged, ["we", "are"])
    }

    func testVeryLongTextsAreSkippedRatherThanCompared() {
        let raw = Array(repeating: "word", count: 601).joined(separator: " ")
        let final = Array(repeating: "mot", count: 601).joined(separator: " ")
        XCTAssertNil(TranscriptDiff.tokens(raw: raw, final: final))
    }
}
