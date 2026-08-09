import XCTest

@testable import PersonalizationKit

/// The guards matter more than the feature here: every entry this produces
/// rewrites all later dictations, so a wrong one is not a missing improvement
/// but active corruption of text the user never re-reads.
final class DictionaryLearningTests: XCTestCase {
    private func correction(_ raw: String, _ corrected: String) -> CorrectionPair {
        CorrectionPair(
            rawTranscript: raw,
            correctedText: corrected,
            bundleIdentifier: nil,
            profile: .automatic,
            language: .french
        )
    }

    func testAWordCorrectedTwiceBecomesAnEntry() {
        let suggestions = DictionaryLearning.suggestions(
            from: [
                correction("le chip set gère le slot", "le chipset gère le slot"),
                correction("ce chip set est récent", "ce chipset est récent"),
            ],
            existing: []
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.canonical, "chipset")
        XCTAssertEqual(suggestions.first?.spokenForms, ["chip set"])
    }

    func testASingleCorrectionIsNotEnough() {
        // One correction is a typo or a changed mind until it repeats.
        let suggestions = DictionaryLearning.suggestions(
            from: [correction("le chip set gère le slot", "le chipset gère le slot")],
            existing: []
        )

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testRewritingAWordIntoAnUnrelatedOneIsNotLearned() {
        // The user changing "budget" to "planning" is editing their text. Turned
        // into a rule it would silently replace "budget" in every dictation for
        // the rest of the app's life.
        let suggestions = DictionaryLearning.suggestions(
            from: [
                correction("on valide le budget demain", "on valide le planning demain"),
                correction("le budget est prêt", "le planning est prêt"),
            ],
            existing: []
        )

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testAnEntryAlreadyInTheDictionaryIsNotProposedAgain() {
        let existing = DictionaryEntry(
            canonical: "chipset",
            spokenForms: ["chip set"],
            language: .french
        )
        let suggestions = DictionaryLearning.suggestions(
            from: [
                correction("le chip set gère le slot", "le chipset gère le slot"),
                correction("ce chip set est récent", "ce chipset est récent"),
            ],
            existing: [existing]
        )

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testAccentAndCaseDoNotSplitTheSameMistake() {
        // "Élite" at the start of a sentence and "élite" mid-sentence are one
        // mistake seen twice, not two seen once — which is the difference
        // between being learned and being ignored forever.
        let suggestions = DictionaryLearning.suggestions(
            from: [
                correction("Élite le document maintenant", "Edite le document maintenant"),
                correction("il faut élite le document", "il faut edite le document"),
            ],
            existing: []
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.canonical.lowercased(), "edite")
    }

    func testAnUnchangedCorrectionYieldsNothing() {
        let suggestions = DictionaryLearning.suggestions(
            from: [
                correction("le rapport est prêt", "le rapport est prêt"),
                correction("le rapport est prêt", "le rapport est prêt"),
            ],
            existing: []
        )

        XCTAssertTrue(suggestions.isEmpty)
    }
}
