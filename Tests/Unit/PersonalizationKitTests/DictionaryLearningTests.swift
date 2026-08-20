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

    func testOneCorrectionBecomesAPendingSuggestionNotAnEntry() {
        let corrections = [correction("le chip set gère le slot", "le chipset gère le slot")]

        let pending = DictionaryLearning.pendingSuggestions(from: corrections, existing: [])
        XCTAssertEqual(pending.map(\.canonical), ["chipset"])
        XCTAssertEqual(pending.first?.origin, .learned)
        // The same evidence must not auto-promote.
        XCTAssertTrue(DictionaryLearning.suggestions(from: corrections, existing: []).isEmpty)
    }

    func testAPromotedPairStopsBeingPending() {
        let corrections = [
            correction("le chip set gère le slot", "le chipset gère le slot"),
            correction("ce chip set est récent", "ce chipset est récent"),
        ]

        XCTAssertTrue(
            DictionaryLearning.pendingSuggestions(from: corrections, existing: []).isEmpty
        )
    }

    func testTheSuggestionKeyIsStableAcrossCaseAndAccents() {
        let a = DictionaryEntry(canonical: "Edite", spokenForms: ["Élite"], origin: .learned)
        let b = DictionaryEntry(canonical: "edite", spokenForms: ["élite"], origin: .learned)

        XCTAssertEqual(
            DictionaryLearning.suggestionKey(a),
            DictionaryLearning.suggestionKey(b)
        )
    }

    func testAnEntrySavedBeforeOriginExistedStillLoads() throws {
        // Same failure mode as transcript history: the synthesized decoder
        // rejects a missing key even when the property has a default, and a
        // personalization file that stops decoding reads as the user's
        // vocabulary being erased by an update.
        let legacy = """
            {
              "id": "8C1B6E1E-5F2B-4E9A-9B3E-2E4F6A1C7D90",
              "canonical": "chipset",
              "spokenForms": ["chip set"],
              "language": "french",
              "bundleIdentifiers": [],
              "isEnabled": true
            }
            """
        let entry = try JSONDecoder().decode(
            DictionaryEntry.self,
            from: XCTUnwrap(legacy.data(using: .utf8))
        )

        XCTAssertEqual(entry.origin, .manual)
        XCTAssertEqual(entry.canonical, "chipset")
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
