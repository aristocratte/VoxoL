import XCTest

@testable import TextProcessingKit

final class SeamAndRoutingTests: XCTestCase {
    private func prepare(
        _ transcript: String,
        mode: CleanupMode = .faithful,
        fastPath: Bool = true
    ) -> DeterministicPreparation {
        DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: transcript,
                preferredLanguage: .french,
                preferences: TextProcessingPreferences(
                    cleanupMode: mode, fastPathEnabled: fastPath)))
    }

    // MARK: Seam echoes

    func testAnEchoOfTheWordEndingAfterAPeriodIsRemoved() {
        XCTAssertEqual(
            prepare("la direction.ction artistique du site").normalizedText,
            "La direction artistique du site")
        XCTAssertEqual(
            prepare("c'est complètement.ement faux").normalizedText,
            "C'est complètement faux")
    }

    func testAnEchoSeparatedByASpaceIsRemoved() {
        XCTAssertEqual(
            prepare("il faut le déployer. yer ce soir").normalizedText,
            "Il faut le déployer ce soir")
    }

    func testDottedNamesAreNotMistakenForEchoes() {
        for text in ["Ouvre agent.md et Next.js.", "Le fichier main.swift est prêt."] {
            XCTAssertEqual(prepare(text).normalizedText, text)
        }
    }

    func testRawModeKeepsTheTranscriptAsHeard() {
        XCTAssertEqual(
            prepare("la direction.ction artistique", mode: .raw).normalizedText,
            "la direction.ction artistique")
    }

    // MARK: When the model is asked

    func testFaithfulCleanProseSkipsTheModel() {
        XCTAssertFalse(
            prepare("le slot du haut est géré par le chipset de la carte").shouldUsePolisher)
    }

    func testAnUnresolvedSelfCorrectionAsksTheModel() {
        XCTAssertTrue(
            prepare("envoie le rapport à Paul non à Marie demain matin").shouldUsePolisher)
    }

    func testAWordWithADoubledEndingAsksTheModel() {
        XCTAssertTrue(prepare("il faut regarderarder le code de la page").shouldUsePolisher)
    }

    func testRewriteStillSendsCleanProseToTheModel() {
        XCTAssertTrue(
            prepare("le slot du haut est géré par le chipset de la carte", mode: .rewrite)
                .shouldUsePolisher)
    }

    func testWithTheFastPathOffEveryDictationAsksTheModel() {
        XCTAssertTrue(
            prepare("le slot du haut est géré par le chipset de la carte", fastPath: false)
                .shouldUsePolisher)
    }
}
