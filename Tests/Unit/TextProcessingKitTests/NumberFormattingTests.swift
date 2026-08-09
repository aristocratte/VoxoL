import Foundation
import XCTest

@testable import TextProcessingKit

final class NumberFormattingTests: XCTestCase {
    private func french(_ input: String) -> String {
        SpokenNumberFormatter.applyingDigits(to: input, language: .french)
    }

    private func english(_ input: String) -> String {
        SpokenNumberFormatter.applyingDigits(to: input, language: .english)
    }

    func testTheModelNumberThatStartedThis() {
        // Dictating "B450" produced "B quatre cent cinquante" and nothing
        // downstream turned it back, which is what made real dictation unusable
        // for technical text.
        XCTAssertEqual(
            french("Sur une B quatre cent cinquante, le slot du haut"),
            "Sur une B450, le slot du haut"
        )
    }

    func testFrenchCompoundsAndScales() {
        XCTAssertEqual(french("quatre-vingt-dix-huit"), "98")
        XCTAssertEqual(french("quatre-vingts"), "80")
        XCTAssertEqual(french("soixante-dix"), "70")
        XCTAssertEqual(french("vingt et un"), "21")
        XCTAssertEqual(french("deux mille vingt-six"), "2026")
        XCTAssertEqual(french("trois cent cinquante mille"), "350000")
        XCTAssertEqual(french("un million deux cent mille"), "1200000")
    }

    func testEnglishScales() {
        XCTAssertEqual(english("four hundred fifty"), "450")
        XCTAssertEqual(english("twenty one"), "21")
        XCTAssertEqual(english("two thousand twenty six"), "2026")
        XCTAssertEqual(english("three hundred and fifty thousand"), "350000")
    }

    func testALoneOneStaysAWordBecauseItIsUsuallyAnArticle() {
        // "un chipset" must never become "1 chipset".
        XCTAssertEqual(french("un chipset et une carte"), "un chipset et une carte")
        XCTAssertEqual(french("il y a une erreur"), "il y a une erreur")
        // But a one that carries a scale is a real quantity.
        XCTAssertEqual(french("un million"), "1000000")
        XCTAssertEqual(french("cent un"), "101")
    }

    func testConnectorsOnlyJoinWhenANumberFollows() {
        XCTAssertEqual(french("deux et le reste"), "2 et le reste")
        XCTAssertEqual(english("two and the rest"), "2 and the rest")
    }

    func testNonNumberTextIsUntouched() {
        let sentence = "Le slot du haut est géré par le chipset, pas la carte."
        XCTAssertEqual(french(sentence), sentence)
    }

    func testPunctuationAndSpacingSurvive() {
        XCTAssertEqual(
            french("J'en veux trente-deux, pas soixante-quatre."),
            "J'en veux 32, pas 64."
        )
    }

    func testSeparateNumbersDoNotMergeAcrossPunctuation() {
        // A comma ends a number; joining across it would invent a value.
        XCTAssertEqual(french("deux, trois"), "2, 3")
        XCTAssertEqual(french("trois. Quatre"), "3. 4")
    }

    func testAnAmbiguousRunIsLeftSpokenRatherThanGuessed() {
        // A spoken year does not accumulate: "twenty twenty six" is 2026, not
        // 20 + 20 + 6. Refusing the whole run beats inventing 46, and refusing
        // only its head would leave "twenty 26".
        XCTAssertEqual(
            english("scheduled for twenty twenty six"),
            "scheduled for twenty twenty six"
        )
        XCTAssertEqual(french("vingt vingt-six"), "vingt vingt-six")
    }

    func testOrdinalsAreLeftAlone() {
        XCTAssertEqual(english("July twenty fourth"), "July twenty fourth")
        XCTAssertEqual(french("le vingt-quatrième jour"), "le vingt-quatrième jour")
    }

    func testACapitalOpeningASentenceKeepsItsSpace() {
        // "B 450" mid-sentence is a part number; "A 5 star rating" is prose.
        XCTAssertEqual(english("A five star rating"), "A 5 star rating")
    }

    func testHyphenatedPlaceNamesAreNotQuantities() {
        // Real French toponyms open with number words. Converting them writes
        // an address nobody has: Trois-Rivières is a city, not three of
        // anything.
        XCTAssertEqual(
            french("Je vais à Trois-Rivières demain"),
            "Je vais à Trois-Rivières demain"
        )
        XCTAssertEqual(
            french("le département des Deux-Sèvres"),
            "le département des Deux-Sèvres"
        )
        XCTAssertEqual(french("Sept-Îles est au Québec"), "Sept-Îles est au Québec")
        // Hyphens inside a genuine number still convert.
        XCTAssertEqual(french("trente-deux ans"), "32 ans")
        XCTAssertEqual(french("dix-huit heures trente"), "18 heures 30")
    }

    func testZeroIsConverted() {
        XCTAssertEqual(french("zéro"), "0")
        XCTAssertEqual(english("zero"), "0")
    }

    func testDigitsAlreadyPresentAreLeftAlone() {
        XCTAssertEqual(french("une B450 et 32 Go"), "une B450 et 32 Go")
    }

    func testAccentedSpellingIsRecognised() {
        XCTAssertEqual(french("zéro"), "0")
    }

    func testFormatterRunsInTheDeterministicLayerWhateverTheRoute() throws {
        // The conversion has to live in the deterministic layer rather than in
        // the prompt: the polisher can be off, time out or be declined by the
        // placeholder audit, and a number spelled out in words must survive all
        // three. Written as a long dictation because that is the case that used
        // to bypass the model entirely.
        let request = TextProcessingRequest(
            rawTranscript: "Sur une B quatre cent cinquante le slot du haut est "
                + "géré par le chipset et pas par la carte graphique installée "
                + "dans le second emplacement disponible juste au-dessus de "
                + "la nappe reliant le bloc arrière du boîtier principal",
            preferredLanguage: .french,
            context: TextProcessingContext(),
            preferences: TextProcessingPreferences(fastPathEnabled: true)
        )

        let preparation = DeterministicTextProcessor.prepare(request)

        XCTAssertTrue(preparation.normalizedText.contains("B450"))
        XCTAssertFalse(preparation.normalizedText.contains("quatre cent"))
    }
}

/// The gating that decides whether Qwen cleanup runs at all.
///
/// Three separate faults made it fire far less often than intended, and none
/// was visible from the code: the artefact test ran on text the filler removal
/// had already cleaned, its patterns were case-sensitive while the recogniser
/// capitalises the first word, and writing a number as digits counted as
/// "already fixed deterministically".
final class PolisherGatingTests: XCTestCase {
    private func prepare(_ text: String) -> DeterministicPreparation {
        DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: text,
                preferredLanguage: .french,
                preferences: TextProcessingPreferences(fastPathEnabled: true)
            )
        )
    }

    func testACapitalisedDiscourseMarkerIsRecognised() {
        // These are not removed deterministically, so they are genuinely
        // unresolved and must reach the model. The patterns were
        // case-sensitive while the recogniser capitalises the first word, so a
        // sentence opening with one was invisible to the check.
        XCTAssertTrue(prepare("Non je voulais dire autre chose entièrement").shouldUsePolisher)
        XCTAssertTrue(prepare("non je voulais dire autre chose entièrement").shouldUsePolisher)
    }

    func testARemovedHesitationIsNoLongerAReasonToSkipTheModel() {
        // The hesitation itself is resolved — that part of the old reasoning
        // held. What did not hold is the conclusion: stripping "euh" leaves the
        // *rest* of the sentence in spoken form, and that is the half only the
        // model rewrites. Skipping it here is how ordinary dictation went out
        // reading like a recogniser dump.
        XCTAssertTrue(prepare("euh envoie le rapport demain matin").shouldUsePolisher)
    }

    func testWritingANumberAsDigitsDoesNotCancelCleanup() {
        // Rewriting "quatre cent cinquante" as 450 resolves nothing about the
        // words around it, so it must not count as the deterministic layer
        // having already done the polisher's job.
        XCTAssertTrue(
            prepare("Sur une B quatre cent cinquante le slot du haut").shouldUsePolisher
        )
    }

    func testFreshDigitsAreHiddenFromTheModelAndRestored() {
        // The formatter mints digits after protect() has run. Unwrapped, they
        // would be the one number class the model can rewrite without the
        // placeholder audit noticing.
        let preparation = prepare("Sur une B quatre cent cinquante le slot du haut")

        XCTAssertFalse(
            preparation.promptText.contains("450"),
            "digits must reach the model as placeholders"
        )
        XCTAssertTrue(preparation.promptText.contains("VOXOLP"))
        XCTAssertTrue(preparation.normalizedText.contains("B450"))
        XCTAssertTrue(
            preparation.protectedTokens.contains {
                $0.value == "B450" && $0.kind == .number
            }
        )
    }

    func testACleanShortDictationStillUsesCleanup() {
        XCTAssertTrue(prepare("Le slot du haut est géré par le chipset").shouldUsePolisher)
    }

    func testALongDictationIsExactlyWhatTheModelIsFor() {
        // This used to assert the opposite, on the reasoning that a long text
        // with no detected artefact has nothing to repair. Real use disproved
        // it: length is where false starts, repetition and speaking-order
        // clauses accumulate, and none of them match an artefact pattern. The
        // dictations that read worst were the ones this rule exempted.
        let long = (1...40).map { "mot\($0)" }.joined(separator: " ")
        XCTAssertTrue(prepare(long).shouldUsePolisher)
    }
}

/// Real dictation, and why it was being skipped.
///
/// A 58-word transcript full of "du coup" and "en gros" read as clean to the
/// gate — none of those words were in any list — so the fast path swallowed it
/// and no cleanup ran on precisely the kind of text that needs it.
final class SpokenFrenchGatingTests: XCTestCase {
    private let dictated = """
        Donc on va regarder que gouvernance du coup est supprimé architectura, \
        mais il faudra bien préciser qu'on veut espagnol. Parce qu' tous les \
        trois, on juge qu'on souhaite beaucoup progresser en espagnol et qu'on \
        en a vraiment besoin. Et que du coup, il faudra. Et qu'en gros, on aura \
        le nombre total de crédits suffisants avec espagnol inclus.
        """

    private func prepare(_ text: String) -> DeterministicPreparation {
        DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: text,
                preferredLanguage: .french,
                preferences: TextProcessingPreferences(fastPathEnabled: true)
            )
        )
    }

    func testALongDictationFullOfCrutchesReachesCleanup() {
        let preparation = prepare(dictated)

        XCTAssertGreaterThan(preparation.promptText.split(separator: " ").count, 24)
        XCTAssertTrue(
            preparation.shouldUsePolisher,
            "past the length window, only the crutches can ask for cleanup"
        )
    }

    func testTheCommonFrenchCrutchesAreEachEnough() {
        for crutch in ["du coup", "en gros", "en fait", "genre", "voilà", "tu vois"] {
            let long = (1...30).map { "mot\($0)" }.joined(separator: " ")
            XCTAssertTrue(
                prepare("\(long) \(crutch) autre chose").shouldUsePolisher,
                "\(crutch) should ask for cleanup"
            )
        }
    }

    func testAGroupPronounIsNotAQuantity() {
        // "tous les trois" counts the people speaking, and "tous les 3" is
        // wrong in a way a reader notices at once.
        XCTAssertEqual(
            SpokenNumberFormatter.applyingDigits(
                to: "Parce que tous les trois on veut progresser",
                language: .french
            ),
            "Parce que tous les trois on veut progresser"
        )
        // A count of things still becomes digits.
        XCTAssertEqual(
            SpokenNumberFormatter.applyingDigits(
                to: "les trois fichiers",
                language: .french
            ),
            "les 3 fichiers"
        )
    }
}
