import AppCoreKit
import Foundation
import XCTest

final class TrainingReviewTests: XCTestCase {
    func testLoadsMachineReviewAndSavesExplicitHumanDecision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("sessions/one", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: session.appendingPathComponent("audio.wav"))
        try Data(
            """
            {"date":"2026-08-30T00:00:00Z","language":"fr","application":"notes","durationSeconds":3,"rawText":"ouvre repo","finalText":"Ouvre repo."}
            """.utf8
        ).write(to: session.appendingPathComponent("meta.json"))
        let machine = TrainingReviewDocument(
            id: "one",
            audioPath: "sessions/one/audio.wav",
            status: .contextReview,
            provenance: TrainingReviewProvenance(
                tier: "ensemble-candidate",
                humanReviewed: false,
                rationale: "Teachers differ."
            ),
            chosen: TrainingReviewChoice(
                verbatim: "ouvre le repo",
                clean: "Ouvre le repo.",
                verbatimSource: "wispr",
                cleanSource: "wispr",
                verbatimSHA256: "raw",
                cleanSHA256: "clean"
            )
        )
        let encoder = JSONEncoder()
        try encoder.encode(machine).write(to: session.appendingPathComponent("review.json"))
        let repository = TrainingReviewRepository(rootURL: root)

        let loaded = try await repository.load()
        let saved = try await repository.save(
            TrainingReviewDecision(
                id: "one",
                verbatim: "ouvre le dépôt",
                faithful: "Ouvre le dépôt.",
                rewrite: "Ouvrez le dépôt.",
                code: "openRepository()",
                disposition: .accept,
                rationale: "Explicitly corrected in Training Studio."
            )
        )

        XCTAssertEqual(loaded.first?.status, .contextReview)
        XCTAssertEqual(saved.status, .accepted)
        XCTAssertEqual(saved.review?.provenance.tier, "human-reviewed")
        XCTAssertTrue(saved.review?.provenance.humanReviewed == true)
        XCTAssertEqual(
            try String(
                contentsOf: session.appendingPathComponent("corrected.txt"),
                encoding: .utf8
            ),
            "Ouvre le dépôt."
        )
        XCTAssertEqual(
            try String(contentsOf: session.appendingPathComponent("faithful.txt"), encoding: .utf8),
            "Ouvre le dépôt."
        )
        XCTAssertEqual(
            try String(contentsOf: session.appendingPathComponent("rewrite.txt"), encoding: .utf8),
            "Ouvrez le dépôt."
        )
        XCTAssertEqual(
            try String(contentsOf: session.appendingPathComponent("code.txt"), encoding: .utf8),
            "openRepository()"
        )
        XCTAssertEqual(saved.review?.schemaVersion, "voxol-transcript-adjudication-v2")
    }

    func testExportContainsReviewDocumentsOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("sessions/one", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: session.appendingPathComponent("audio.wav"))
        try Data("{\"rawText\":\"hello\",\"finalText\":\"Hello.\"}".utf8)
            .write(to: session.appendingPathComponent("meta.json"))
        let repository = TrainingReviewRepository(rootURL: root)

        let before = try await repository.exportJSONL()
        _ = try await repository.save(
            TrainingReviewDecision(
                id: "one",
                verbatim: "hello",
                clean: "Hello.",
                disposition: .accept,
                rationale: "Reviewed."
            )
        )
        let after = try await repository.exportJSONL()

        XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(String(decoding: after, as: UTF8.self).split(separator: "\n").count, 1)
    }

    func testLegacyChoiceDecodesIntoFaithfulReference() throws {
        let data = Data(
            """
            {
              "verbatim": "ouvre le repo",
              "clean": "Ouvre le repo.",
              "verbatim_source": "teacher",
              "clean_source": "teacher",
              "verbatim_sha256": "raw",
              "clean_sha256": "clean"
            }
            """.utf8
        )

        let choice = try JSONDecoder().decode(TrainingReviewChoice.self, from: data)

        XCTAssertEqual(choice.verbatim, "ouvre le repo")
        XCTAssertEqual(choice.faithful, "Ouvre le repo.")
        XCTAssertEqual(choice.rewrite, "")
        XCTAssertEqual(choice.code, "")
        XCTAssertEqual(choice.clean, choice.faithful)
    }
}
