import Foundation
import TextProcessingKit
import XCTest

final class SpokenFormattingTests: XCTestCase {
    func testSyntheticCommandAndLiteralRegressionCorpus() throws {
        struct Suite: Decodable { let cases: [Case] }
        struct Case: Decodable {
            let id: String
            let language: TextLanguage
            let transcript: String
            let expected: String
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let suite = try JSONDecoder().decode(
            Suite.self,
            from: Data(
                contentsOf: root.appendingPathComponent(
                    "Performance/Fixtures/spoken-formatting-v1.json"))
        )
        for item in suite.cases {
            let preparation = DeterministicTextProcessor.prepare(
                TextProcessingRequest(
                    rawTranscript: item.transcript, preferredLanguage: item.language,
                    preferences: TextProcessingPreferences(profile: .chat)
                )
            )
            XCTAssertEqual(preparation.normalizedText, item.expected, item.id)
            if SpokenFormatting.apply(to: item.transcript, language: item.language).applied {
                XCTAssertFalse(preparation.shouldUsePolisher, item.id)
            }
        }
    }

    func testRawModePreservesSpokenCommands() {
        let input = "Bonjour début du gras important fin du gras point final"
        let output = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: input, preferredLanguage: .french,
                preferences: TextProcessingPreferences(cleanupMode: .raw)
            )
        )
        XCTAssertEqual(output.normalizedText, input)
        XCTAssertFalse(output.hasSpokenBold)
    }

    func testFormattingDoesNotInventAnAmbiguousWord() {
        let input = "Je veux créer des tapus"
        XCTAssertEqual(SpokenFormatting.apply(to: input, language: .french).text, input)
    }

    func testAdditionalExplicitCommandsAndLiteralMentions() {
        let cases: [(String, String)] = [
            ("Tu viens ajoute un point d’interrogation", "Tu viens ?"),
            ("Bonjour ajoute une virgule Paul", "Bonjour, Paul"),
            ("Merci emoji cœur rouge", "Merci ❤️"),
            (
                "Je veux mettre un point final, un. Point d’exclamation",
                "Je veux mettre un point final, un. Point d’exclamation"
            ),
            ("Paul, pardon, je suis en retard", "Paul, pardon, je suis en retard"),
            ("Garde `lundi, non, mardi`", "Garde `lundi, non, mardi`"),
            ("Il a dit « Paul, pardon, Pierre »", "Il a dit « Paul, pardon, Pierre »"),
            (
                "Crée une liste à puces. Première puce acheter du pain. Nouvelle puce envoyer le rapport.",
                "• Acheter du pain.\n• Envoyer le rapport."
            ),
            (
                "La puce électronique est différente de la puce du chat",
                "La puce électronique est différente de la puce du chat"
            ),
        ]
        for (input, expected) in cases {
            let output = DeterministicTextProcessor.prepare(
                TextProcessingRequest(
                    rawTranscript: input, preferredLanguage: .french,
                    preferences: TextProcessingPreferences(profile: .chat)
                )
            )
            XCTAssertEqual(output.normalizedText, expected, input)
        }
    }
}
