import Foundation
import XCTest

@testable import PersonalizationKit

final class PersonalizationTests: XCTestCase {
    func testRepositoryRoundTripsAndScopesEntries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("personalization.sqlite3")
        let repository = PersonalizationRepository(fileURL: fileURL)
        let scoped = DictionaryEntry(
            canonical: "PostgreSQL",
            spokenForms: ["post gres q l"],
            bundleIdentifiers: ["com.microsoft.VSCode"]
        )
        let global = DictionaryEntry(canonical: "VoxoL")
        let snapshot = PersonalizationSnapshot(dictionary: [scoped, global])

        try await repository.save(snapshot)
        let correction = CorrectionPair(
            rawTranscript: "um send PostgreSQL tomorrow",
            correctedText: "Send PostgreSQL tomorrow.",
            bundleIdentifier: "com.microsoft.VSCode",
            profile: .developer,
            language: .english
        )
        try await repository.addCorrection(correction)
        let loaded = try await repository.load()
        let corrections = try await repository.loadCorrections()

        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(
            loaded.dictionaryEntries(for: "com.apple.mail").map(\.canonical),
            ["VoxoL"]
        )
        XCTAssertEqual(
            Set(loaded.dictionaryEntries(for: "com.microsoft.VSCode").map(\.canonical)),
            Set(["PostgreSQL", "VoxoL"])
        )
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: fileURL).prefix(15), as: UTF8.self),
            "SQLite format 3"
        )
        XCTAssertFalse(
            String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
                .contains("PostgreSQL")
        )
        XCTAssertEqual(corrections.count, 1)
        let restoredCorrection = try XCTUnwrap(corrections.first)
        XCTAssertEqual(restoredCorrection.id, correction.id)
        XCTAssertEqual(
            restoredCorrection.createdAt.timeIntervalSince1970,
            correction.createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(restoredCorrection.rawTranscript, correction.rawTranscript)
        XCTAssertEqual(restoredCorrection.correctedText, correction.correctedText)
        XCTAssertEqual(restoredCorrection.bundleIdentifier, correction.bundleIdentifier)
        XCTAssertEqual(restoredCorrection.profile, correction.profile)
        XCTAssertEqual(restoredCorrection.language, correction.language)
        XCTAssertEqual(restoredCorrection.approved, correction.approved)
    }

    func testDomainSpecificProfileWinsForMatchingApp() {
        let snapshot = PersonalizationSnapshot(
            applicationProfiles: [
                ApplicationProfileRule(
                    bundleIdentifier: "com.apple.Safari",
                    domain: "github.com",
                    profile: .developer
                )
            ]
        )

        XCTAssertEqual(
            snapshot.profile(for: "com.apple.Safari", domain: "gist.github.com"),
            .developer
        )
        XCTAssertNil(snapshot.profile(for: "com.apple.Safari", domain: "example.com"))
    }
}
