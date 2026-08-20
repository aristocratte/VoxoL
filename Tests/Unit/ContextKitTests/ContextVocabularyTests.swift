import XCTest

@testable import ContextKit

final class ContextVocabularyTests: XCTestCase {
    private func snapshot(
        title: String? = nil,
        selected: String = "",
        before: String = "",
        after: String = ""
    ) -> ContextSnapshot {
        ContextSnapshot(
            bundleIdentifier: "com.apple.mail",
            applicationName: "Mail",
            windowTitle: title,
            controlRole: nil,
            selectedText: selected,
            beforeCursor: before,
            afterCursor: after,
            documentURL: nil,
            isSecure: false
        )
    }

    func testBrandsAndIdentifiersAreKept() {
        let terms = ContextVocabulary.terms(
            from: snapshot(title: "Migration Kubernetes — VoxoL", before: "le chipset B450")
        )

        XCTAssertTrue(terms.contains("Kubernetes"))
        XCTAssertTrue(terms.contains("VoxoL"))
        XCTAssertTrue(terms.contains("B450"))
    }

    func testOrdinaryProseIsNotBoosted() {
        // Boosting common words costs accuracy everywhere else; the trie
        // tuning in ParakeetCore was paid for in word-error points.
        let terms = ContextVocabulary.terms(
            from: snapshot(before: "il faudra relire la partie sur les chiffres demain")
        )

        XCTAssertTrue(terms.isEmpty)
    }

    func testDuplicatesCollapseCaseInsensitively() {
        let terms = ContextVocabulary.terms(
            from: snapshot(title: "GitHub", selected: "github", before: "GITHUB")
        )

        XCTAssertEqual(terms.count, 1)
        XCTAssertEqual(terms.first, "GitHub")
    }

    func testTheListIsCapped() {
        let names = (1...40).map { "Marque\($0)" }.joined(separator: " ")
        let terms = ContextVocabulary.terms(from: snapshot(before: names))

        XCTAssertEqual(terms.count, ContextVocabulary.defaultLimit)
    }

    func testTheTitleOutranksTheCursorText() {
        // When the cap bites, the words naming the document survive first.
        let filler = (1...40).map { "Filler\($0)" }.joined(separator: " ")
        let terms = ContextVocabulary.terms(
            from: snapshot(title: "Datadog", before: filler)
        )

        XCTAssertEqual(terms.first, "Datadog")
    }

    func testDistantDocumentTextIsIgnored() {
        // Words further than the cursor window are the document's past.
        let far = "Elasticsearch " + String(repeating: "a", count: 400)
        let terms = ContextVocabulary.terms(from: snapshot(before: far))

        XCTAssertFalse(terms.contains("Elasticsearch"))
    }
}
