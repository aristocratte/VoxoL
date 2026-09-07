import XCTest

@testable import TextProcessingKit

final class TranscriptChunkerTests: XCTestCase {
    func testRunsHoldWholeSentencesUnderTheLimit() {
        let text =
            "Alors je n'aime pas du tout ce que tu as fait. "
            + "L'effet du début n'a pas de lien avec l'application. "
            + "Je pense qu'on va faire un truc splitté au milieu. "
            + "En soi c'est pas grave."

        // Words are counted on letter runs, so "qu'on" is two: 12, 12, 11 and 6 words.
        let runs = TranscriptChunker.split(text, maximumWords: 20)

        XCTAssertEqual(
            runs,
            [
                "Alors je n'aime pas du tout ce que tu as fait.",
                "L'effet du début n'a pas de lien avec l'application.",
                "Je pense qu'on va faire un truc splitté au milieu. En soi c'est pas grave.",
            ]
        )
        XCTAssertEqual(runs.joined(separator: " "), text)
    }

    func testDecimalsAndTimesDoNotEndASentence() {
        let text = "La version 5.2 sort à 23h45. On valide demain."

        XCTAssertEqual(
            TranscriptChunker.sentences(in: text),
            ["La version 5.2 sort à 23h45.", "On valide demain."]
        )
    }

    func testAnOverlongSentenceIsCutAtClausesThenWords() {
        let clauses = "un deux trois, quatre cinq six, sept huit neuf"
        XCTAssertEqual(
            TranscriptChunker.split(clauses, maximumWords: 4),
            ["un deux trois,", "quatre cinq six,", "sept huit neuf"]
        )

        let flat = "un deux trois quatre cinq six sept"
        XCTAssertEqual(
            TranscriptChunker.split(flat, maximumWords: 3),
            ["un deux trois", "quatre cinq six", "sept"]
        )
    }

    func testShortTextIsOneRun() {
        XCTAssertEqual(
            TranscriptChunker.split("Envoie le rapport.", maximumWords: 45),
            ["Envoie le rapport."]
        )
        XCTAssertEqual(TranscriptChunker.split("   ", maximumWords: 45), [])
    }
}
