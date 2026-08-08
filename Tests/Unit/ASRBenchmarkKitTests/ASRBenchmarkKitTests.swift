import ASRBenchmarkKit
import Foundation
import XCTest

final class ASRBenchmarkKitTests: XCTestCase {
    func testManifestFreezesAndValidatesStableDigest() throws {
        let manifest = ASRBenchmarkManifest(
            benchmarkID: "pilot",
            items: [
                item(
                    id: "fr-1",
                    speaker: "speaker-fr",
                    session: "session-fr",
                    split: .blind,
                    language: .french
                )
            ]
        )

        let frozen = try manifest.frozen(at: "2026-07-24T18:00:00Z")

        try frozen.validate(requireFrozen: true)
        XCTAssertEqual(frozen.contentSHA256, try frozen.digest())
    }

    func testManifestRejectsSpeakerLeakageAcrossSplits() {
        let manifest = ASRBenchmarkManifest(
            benchmarkID: "pilot",
            items: [
                item(
                    id: "one",
                    speaker: "same",
                    session: "one",
                    split: .development,
                    language: .french
                ),
                item(
                    id: "two",
                    speaker: "same",
                    session: "two",
                    split: .blind,
                    language: .english
                ),
            ]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? ASRBenchmarkManifestError,
                .speakerCrossesSplits("same")
            )
        }
    }

    func testManifestRejectsUnsafeAudioPath() {
        let invalid = ASRBenchmarkItem(
            id: "unsafe",
            audioPath: "../outside.wav",
            speakerID: "speaker",
            sessionID: "session",
            split: .blind,
            language: .french,
            microphone: "built-in",
            environment: "quiet",
            tags: [],
            reference: ASRBenchmarkReference(
                verbatim: "Bonjour",
                clean: "Bonjour.",
                reviewed: true
            )
        )
        let manifest = ASRBenchmarkManifest(benchmarkID: "pilot", items: [invalid])

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? ASRBenchmarkManifestError,
                .unsafeAudioPath("../outside.wav")
            )
        }
    }

    func testScoringSeparatesVerbatimCleanAndCriticalSpans() throws {
        let manifest = try ASRBenchmarkManifest(
            benchmarkID: "pilot",
            items: [
                item(
                    id: "fr-1",
                    speaker: "speaker",
                    session: "session",
                    split: .blind,
                    language: .french
                )
            ]
        ).frozen(at: "2026-07-24T18:00:00Z")
        let report = try ASRBenchmarkScorer.score(
            manifest: manifest,
            predictions: [
                ASRBenchmarkPrediction(
                    id: "fr-1",
                    rawText: "Le budget est de 4500 euros",
                    finalText: "Le budget est de 4500 euros.",
                    languageDrift: false,
                    inferenceMilliseconds: 120,
                    releaseToInsertionMilliseconds: 180
                )
            ]
        )

        XCTAssertEqual(report.rawVerbatim.wordErrors.errorRate, 0)
        XCTAssertEqual(report.finalClean.wordErrors.errorRate, 0)
        XCTAssertEqual(report.finalClean.criticalSpanErrorRate, 0)
        XCTAssertEqual(report.finalClean.exactMatchRate, 1)
        XCTAssertEqual(report.rawByLanguage["french"]?.wordErrors.errorRate, 0)
        XCTAssertEqual(report.rawByTag["numbers"]?.itemCount, 1)
        XCTAssertEqual(report.latency.inference?.p95Milliseconds, 120)
        XCTAssertEqual(report.latency.releaseToInsertion?.p99Milliseconds, 180)
        XCTAssertEqual(report.finalClean.languageDriftAssessedItemCount, 1)
        XCTAssertEqual(report.finalClean.languageDriftRate, 0)
    }

    func testPerItemScoresSumToTheAggregateTheyExplain() throws {
        // Published confidence intervals are bootstrapped from these rows. If
        // they ever stopped adding up to the report they came from, every
        // interval would describe a benchmark nobody ran.
        let manifest = try ASRBenchmarkManifest(
            benchmarkID: "pilot",
            items: [
                item(
                    id: "fr-1",
                    speaker: "a",
                    session: "s",
                    split: .blind,
                    language: .french
                ),
                item(
                    id: "de-1",
                    speaker: "b",
                    session: "s",
                    split: .blind,
                    language: .german
                ),
            ]
        ).frozen(at: "2026-08-06T00:00:00Z")
        let predictions = [
            ASRBenchmarkPrediction(
                id: "fr-1",
                rawText: "Le budget est de 4500 euros",
                finalText: "Le budget est de 4500 euros."
            ),
            ASRBenchmarkPrediction(
                id: "de-1",
                rawText: "Le budget est",
                finalText: "Le budget est"
            ),
        ]

        let report = try ASRBenchmarkScorer.score(
            manifest: manifest,
            predictions: predictions
        )
        let items = try ASRBenchmarkScorer.scoreItems(
            manifest: manifest,
            predictions: predictions
        )

        XCTAssertEqual(items.map(\.id), ["fr-1", "de-1"])
        XCTAssertEqual(items.map(\.language), ["french", "german"])
        XCTAssertEqual(
            items.reduce(0) { $0 + $1.rawWordErrors.referenceUnitCount },
            report.rawVerbatim.wordErrors.referenceUnitCount
        )
        XCTAssertEqual(
            items.reduce(0) {
                $0 + $1.rawWordErrors.substitutions + $1.rawWordErrors.deletions
                    + $1.rawWordErrors.insertions
            },
            report.rawVerbatim.wordErrors.substitutions
                + report.rawVerbatim.wordErrors.deletions
                + report.rawVerbatim.wordErrors.insertions
        )
        // The truncated hypothesis dropped three of six words.
        XCTAssertEqual(items[1].rawWordErrors.deletions, 3)
        XCTAssertTrue(items[0].rawExact)
        XCTAssertFalse(items[1].rawExact)
    }

    func testPerItemScoringRejectsAnUnscorableBenchmark() throws {
        let manifest = try ASRBenchmarkManifest(
            benchmarkID: "pilot",
            items: [
                item(
                    id: "fr-1",
                    speaker: "a",
                    session: "s",
                    split: .blind,
                    language: .french
                )
            ]
        ).frozen(at: "2026-08-06T00:00:00Z")

        XCTAssertThrowsError(
            try ASRBenchmarkScorer.scoreItems(manifest: manifest, predictions: [])
        ) { error in
            XCTAssertEqual(
                error as? ASRBenchmarkScoringError,
                .missingPrediction("fr-1")
            )
        }
    }

    private func item(
        id: String,
        speaker: String,
        session: String,
        split: ASRBenchmarkSplit,
        language: ASRBenchmarkLanguage
    ) -> ASRBenchmarkItem {
        ASRBenchmarkItem(
            id: id,
            audioPath: "audio/\(id).wav",
            speakerID: speaker,
            sessionID: session,
            split: split,
            language: language,
            microphone: "built-in",
            environment: "quiet",
            tags: ["numbers"],
            reference: ASRBenchmarkReference(
                verbatim: "Le budget est de 4500 euros",
                clean: "Le budget est de 4500 euros.",
                criticalSpans: [
                    ASRCriticalSpan(kind: .currency, expected: "4500 euros")
                ],
                reviewed: true
            )
        )
    }
}
