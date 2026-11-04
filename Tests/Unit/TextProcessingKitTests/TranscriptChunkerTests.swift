import XCTest

@testable import TextProcessingKit

final class TranscriptChunkerTests: XCTestCase {
    func testRelativeClauseStaysWithItsAntecedentDespiteASRStop() {
        let text =
            "Le travail est terminé depuis longtemps. Elle répondait aux besoins. que avait l'association."
        let request = TextProcessingRequest(rawTranscript: text, preferredLanguage: .french)
        let runs = TranscriptChunker.requests(for: request, maximumWords: 10)
        XCTAssertTrue(runs.contains { $0.rawTranscript.contains("besoins. qu'avait") })
        XCTAssertEqual(
            runs.map(\.rawTranscript).joined(separator: " "),
            "Le travail est terminé depuis longtemps. Elle répondait aux besoins. qu'avait l'association."
        )
    }

    func testAutomaticMixedLanguageDoesNotForceEnglishPassagesIntoFrench() {
        let request = TextProcessingRequest(
            rawTranscript:
                "Le rapport est prêt pour demain. We are checking that the service is working and that the backup is available.",
            fallbackLanguage: .french)
        let languages = TranscriptChunker.requests(for: request, maximumWords: 12)
            .map { DeterministicTextProcessor.prepare($0).language }
        XCTAssertTrue(languages.contains(.french))
        XCTAssertTrue(languages.contains(.english))
    }

    func testElisionIsResolvedBeforeTheSplit() {
        let request = TextProcessingRequest(
            rawTranscript: "Les besoins que avait l'association.", preferredLanguage: .french)
        let output = TranscriptChunker.requests(for: request, maximumWords: 3)
            .map { DeterministicTextProcessor.prepare($0).normalizedText }.joined(separator: " ")
        XCTAssertEqual(output, "Les besoins qu'avait l'association.")
    }

    func testForcedSplitsDoNotCreatePunctuationOrCapitals() {
        let text = "Nous allons développer des outils pour les Safe Campus et pour SAFE Global."
        for limit in [3, 5, 8, 10] {
            let request = TextProcessingRequest(rawTranscript: text, preferredLanguage: .french)
            let runs = TranscriptChunker.requests(for: request, maximumWords: limit)
            let prepared = runs.map(DeterministicTextProcessor.prepare)
            XCTAssertEqual(prepared.map(\.normalizedText).joined(separator: " "), text)
            XCTAssertFalse(runs.first!.context.startsMidSentence)
            XCTAssertFalse(runs.last!.context.endsMidSentence)
            XCTAssertTrue(runs.dropFirst().allSatisfy { $0.context.startsMidSentence })
        }
    }

    func testRealSentenceBoundariesStillReceiveNormalFormatting() {
        let request = TextProcessingRequest(
            rawTranscript: "première phrase. deuxième phrase.", preferredLanguage: .french)
        let runs = TranscriptChunker.requests(for: request, maximumWords: 2)
        XCTAssertTrue(
            runs.allSatisfy { !$0.context.startsMidSentence && !$0.context.endsMidSentence })
        XCTAssertEqual(
            runs.map { DeterministicTextProcessor.prepare($0).normalizedText }.joined(
                separator: " "),
            "Première phrase. Deuxième phrase.")
    }

    func testContextContainsSourceOnBothSidesAndRetainsDestination() {
        let request = TextProcessingRequest(
            rawTranscript: "Nous préparons le projet. SAFE Global participe. Le campus suit.",
            preferredLanguage: .french,
            context: TextProcessingContext(beforeCursor: "Destination existante.")
        )
        let runs = TranscriptChunker.requests(for: request, maximumWords: 4)
        XCTAssertEqual(runs[0].context.dictationAfter, "SAFE Global participe. Le campus suit.")
        XCTAssertEqual(runs[1].context.dictationBefore, "Nous préparons le projet.")
        XCTAssertEqual(runs[1].context.beforeCursor, "Destination existante.")
        XCTAssertTrue(runs.allSatisfy { $0.preferredLanguage == .french })
        let prompt = PolishingPromptBuilder.build(from: DeterministicTextProcessor.prepare(runs[1]))
        XCTAssertTrue(prompt.user.contains("DICTÉE PRÉCÉDENTE"))
        XCTAssertTrue(prompt.user.contains("SUITE DE LA DICTÉE"))
        XCTAssertTrue(prompt.user.contains("pas du texte à recopier"))
    }

    func testCompletedLookaheadKeepsPrefetchPromptsIdentical() {
        let sentences = (0..<12).map { "Nous testons la phrase numéro \($0)." }
        let request = TextProcessingRequest(
            rawTranscript: sentences.joined(separator: " "), preferredLanguage: .french)
        var partial = request
        partial.rawTranscript = sentences.prefix(7).joined(separator: " ")
        let fullRuns = TranscriptChunker.requests(for: request, maximumWords: 8)
        let earlyRuns = TranscriptChunker.requests(for: partial, maximumWords: 8)
        for (index, early) in earlyRuns.dropLast(TranscriptChunker.contextLookaheadCount + 1)
            .enumerated()
        {
            XCTAssertEqual(
                PolishingPromptBuilder.build(from: DeterministicTextProcessor.prepare(early)),
                PolishingPromptBuilder.build(
                    from: DeterministicTextProcessor.prepare(fullRuns[index])))
        }
    }

    func testApostrophesUseTheSameWordBudgetInForcedSplits() {
        let text = Array(repeating: "l'association qu'on connaît", count: 9).joined(separator: " ")
        let runs = TranscriptChunker.split(text, maximumWords: 10)
        XCTAssertEqual(runs.joined(separator: " "), text)
        XCTAssertTrue(runs.allSatisfy { TranscriptChunker.wordCount($0) <= 10 })
    }

    func testLongContextRemainsBounded() {
        let request = TextProcessingRequest(
            rawTranscript: String(
                repeating: "Une phrase de contexte suffisamment longue. ", count: 100),
            preferredLanguage: .french)
        let runs = TranscriptChunker.requests(for: request, maximumWords: 45)
        XCTAssertTrue(
            runs.allSatisfy {
                $0.context.dictationBefore.count <= 1_200
                    && $0.context.dictationAfter.count <= 1_200
            })
    }

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
