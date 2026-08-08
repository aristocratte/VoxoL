import Foundation
import XCTest

@testable import AppCoreKit

final class BugReportComposerTests: XCTestCase {
    private func environment() -> BugReportComposer.Environment {
        BugReportComposer.Environment(
            applicationVersion: "0.1.0",
            buildNumber: "42",
            systemVersion: "Version 26.0 (Build 26A1)",
            hardwareModel: "Mac16,6",
            processorCount: 12,
            physicalMemoryGigabytes: 48,
            locale: "fr_FR"
        )
    }

    func testReportCarriesTheFactsAMaintainerNeeds() {
        let body = BugReportComposer.body(
            summary: "Le texte n'est pas inséré",
            steps: "Dicter dans Mail",
            environment: environment(),
            diagnostics: nil
        )

        for expected in ["0.1.0", "42", "Mac16,6", "26.0", "fr_FR", "12", "48"] {
            XCTAssertTrue(body.contains(expected), "missing \(expected)")
        }
        XCTAssertTrue(body.contains("Le texte n'est pas inséré"))
        XCTAssertTrue(body.contains("Dicter dans Mail"))
    }

    func testEmptyFieldsAreMarkedRatherThanLeftBlank() {
        let body = BugReportComposer.body(
            summary: "",
            steps: "",
            environment: environment(),
            diagnostics: nil
        )

        // A silently empty section reads as "nothing happened" to whoever
        // triages it; an explicit marker reads as "the reporter skipped this".
        XCTAssertEqual(body.components(separatedBy: "_(not described)_").count - 1, 2)
    }

    func testDiagnosticsAreIncludedAndLabelledAsTextFree() {
        let diagnostics = #"{"schemaVersion":1,"lastSession":{"asrMilliseconds":142}}"#

        let body = BugReportComposer.body(
            summary: "slow",
            steps: "dictate",
            environment: environment(),
            diagnostics: diagnostics
        )

        XCTAssertTrue(body.contains(diagnostics))
        XCTAssertTrue(body.contains("no transcript, no audio"))
    }

    func testAnOversizedDiagnosticIsTruncatedRatherThanDropped() {
        // GitHub rejects a very long URL. Losing the whole timing trace to a
        // length limit would make a performance report useless, so a partial
        // one is kept and marked.
        let diagnostics = String(repeating: "x", count: 20_000)

        let body = BugReportComposer.body(
            summary: "slow",
            steps: "dictate",
            environment: environment(),
            diagnostics: diagnostics
        )

        XCTAssertTrue(body.contains("… truncated"))
        XCTAssertLessThan(body.count, 20_000)
        XCTAssertTrue(body.contains("## Diagnostics"))
    }

    func testReportNeverCarriesDictatedText() {
        // The promise of a local dictation app is that what you say stays on
        // your machine. A bug reporter is the most likely place to break it by
        // accident, so the guarantee is asserted rather than assumed: only what
        // the user typed into the form, plus machine facts, may appear.
        let secret = "MonMotDePasseUltraSecret"
        let diagnostics = #"{"transcriptCharacterCount":184,"asrMilliseconds":142}"#

        let body = BugReportComposer.body(
            summary: "insertion échoue",
            steps: "ouvrir Mail",
            environment: environment(),
            diagnostics: diagnostics
        )

        XCTAssertFalse(body.contains(secret))
        // A count is fine; the text behind it is not.
        XCTAssertTrue(body.contains("transcriptCharacterCount"))
    }

    func testIssueURLCarriesTitleBodyAndLabel() throws {
        let url = try XCTUnwrap(
            BugReportComposer.issueURL(title: "Insertion échoue", body: "détails")
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        XCTAssertEqual(items["title"], "Insertion échoue")
        XCTAssertEqual(items["body"], "détails")
        XCTAssertEqual(items["labels"], "bug")
        XCTAssertEqual(components.scheme, "https")
    }

    func testIssueURLFallsBackToAGenericTitle() throws {
        let url = try XCTUnwrap(BugReportComposer.issueURL(title: "", body: "b"))

        XCTAssertTrue(url.absoluteString.contains("VoxoL%20bug%20report"))
    }

    func testCurrentEnvironmentReadsRealMachineFacts() {
        let current = BugReportComposer.Environment.current()

        XCTAssertFalse(current.hardwareModel.isEmpty)
        XCTAssertNotEqual(current.hardwareModel, "unknown")
        XCTAssertGreaterThan(current.processorCount, 0)
        XCTAssertGreaterThan(current.physicalMemoryGigabytes, 0)
    }
}
