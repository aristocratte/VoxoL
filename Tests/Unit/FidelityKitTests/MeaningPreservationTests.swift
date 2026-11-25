import XCTest

@testable import FidelityKit
@testable import TextProcessingKit

/// Changes a spell-checker would call small and a reader would call a different sentence.
final class MeaningPreservationTests: XCTestCase {
    private func accepts(
        _ source: String, _ candidate: String, _ language: TextLanguage = .french
    ) -> Bool {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(rawTranscript: source, preferredLanguage: language))
        return FidelityValidator.validate(candidate: candidate, against: preparation)
            .usedModelOutput
    }

    func testSwappingWhoDoesWhatIsRejected() {
        XCTAssertFalse(accepts("Paul appelle Marie demain.", "Marie appelle Paul demain."))
        XCTAssertFalse(
            accepts("The client pays the supplier.", "The supplier pays the client.", .english))
    }

    func testAShortWordIsNotReplacedByALookalike() {
        for (source, candidate) in [
            ("Je suis parti hier.", "Je suis parti hiver."),
            ("Elle a peu dormi cette nuit.", "Elle a peur dormi cette nuit."),
        ] {
            XCTAssertFalse(accepts(source, candidate), "\(source) -> \(candidate)")
        }
    }

    func testAnAuxiliaryIsNotDropped() {
        for (source, candidate) in [
            ("Il a fini le rapport.", "Il fini le rapport."),
            ("Les tests sont passés hier.", "Les tests passés hier."),
        ] {
            XCTAssertFalse(accepts(source, candidate), "\(source) -> \(candidate)")
        }
        XCTAssertFalse(
            accepts("They have finished the report.", "They finished the report.", .english))
    }

    func testAStatementDoesNotBecomeAQuestion() {
        XCTAssertFalse(accepts("Tu viens demain.", "Tu viens demain ?"))
    }

    func testASentenceThatReallyOpensWithVoiciKeepsItsSpellingFix() {
        XCTAssertTrue(
            accepts("Lis le raport que tu as demandé.", "Lis le rapport que tu as demandé."),
            "control: the spelling fix alone is accepted")
        XCTAssertTrue(
            accepts("Voici le raport que tu as demandé.", "Voici le rapport que tu as demandé."))
    }
}
