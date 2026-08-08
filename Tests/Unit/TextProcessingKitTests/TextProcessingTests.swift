import PersonalizationKit
import XCTest

@testable import TextProcessingKit

final class TextProcessingTests: XCTestCase {
    func testAlreadyCorrectFrenchChatPreservesSurfaceTypography() {
        let transcripts = [
            "Alors j'aimerais bien que tu réduises l'ensemble des",
            "J'ai mis des assets dans la scène. Est-ce que tu peux faire le texturing aussi ?",
        ]

        for transcript in transcripts {
            let preparation = DeterministicTextProcessor.prepare(
                TextProcessingRequest(
                    rawTranscript: transcript,
                    preferredLanguage: .french,
                    preferences: TextProcessingPreferences(
                        fastPathEnabled: false,
                        profile: .chat
                    )
                )
            )

            XCTAssertEqual(preparation.normalizedText, transcript)
        }
    }

    func testFrenchDimensionalNumbersRemainProtectedAndUnchanged() {
        let transcript = "Une carte en 2D ou 2,5D"
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: transcript,
                preferredLanguage: .french,
                preferences: TextProcessingPreferences(
                    fastPathEnabled: false,
                    profile: .chat
                )
            )
        )

        XCTAssertEqual(preparation.normalizedText, transcript)
        XCTAssertEqual(
            preparation.protectedTokens.filter { $0.kind == .number }.map(\.value),
            ["2D", "2,5D"]
        )
    }

    func testRawModePreservesSpeechArtifactsAndCasing() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "um i i need this raw",
                preferences: TextProcessingPreferences(cleanupMode: .raw)
            )
        )

        XCTAssertEqual(preparation.normalizedText, "um i i need this raw")
        XCTAssertEqual(preparation.profile, .raw)
        XCTAssertFalse(preparation.shouldUsePolisher)
    }

    func testExplicitSingleWordCorrectionIsSafeWithoutQwen() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "Ship Tuesday—actually Wednesday morning",
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )

        XCTAssertEqual(preparation.normalizedText, "Ship Wednesday morning")
    }

    func testSpokenCorrectionWithoutPunctuationIsResolvedBeforeProtection() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript:
                    "Je vais envoyer le rapport mardi non mercredi matin et pense à joindre le PDF",
                preferredLanguage: .french,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )

        XCTAssertFalse(preparation.normalizedText.contains("mardi"))
        XCTAssertTrue(preparation.normalizedText.contains("mercredi matin"))
        XCTAssertFalse(preparation.protectedTokens.contains { $0.value == "non" })
    }

    func testFrenchNegationIsNotMisreadAsSelfCorrection() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "Le document est non signé",
                preferredLanguage: .french,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )

        XCTAssertEqual(preparation.normalizedText, "Le document est non signé")
        XCTAssertTrue(preparation.protectedTokens.contains { $0.value == "non" })
    }

    func testNumericSelfCorrectionKeepsOnlyTheCorrectedProtectedFact() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript:
                    "Le budget est 4200 euros non pardon 4500 euros et la livraison est le 24 juillet 2026",
                preferredLanguage: .french,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )

        XCTAssertFalse(preparation.normalizedText.contains("4200"))
        XCTAssertFalse(preparation.normalizedText.lowercased().contains("pardon"))
        XCTAssertTrue(preparation.normalizedText.contains("4500 euros"))
        XCTAssertTrue(preparation.normalizedText.contains("24 juillet 2026"))
        XCTAssertTrue(preparation.protectedTokens.contains { $0.value == "4500" })
        XCTAssertFalse(preparation.protectedTokens.contains { $0.value == "4200" })
    }

    func testNaturalLanguageDatesAreProtectedAsOneSemanticSpan() {
        let french = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "La livraison est prévue le 24 juillet 2026",
                preferredLanguage: .french,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )
        let english = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "Delivery is scheduled for July 24, 2026",
                preferredLanguage: .english,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )

        XCTAssertEqual(
            french.protectedTokens.filter { $0.kind == .dateOrTime }.map(\.value),
            ["24 juillet 2026"]
        )
        XCTAssertEqual(
            english.protectedTokens.filter { $0.kind == .dateOrTime }.map(\.value),
            ["July 24, 2026"]
        )
    }

    func testExplicitBulletsAreFormattedDeterministically() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "bullet apples bullet bananas",
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )

        XCTAssertEqual(preparation.normalizedText, "• Apples\n• Bananas")
    }

    func testSpokenFrenchNumberedListDropsMarkerCommasWithoutPolisher() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript:
                    "Premièrement, vérifier le budget. Deuxièmement, appelé Camille. Troisièmement, envoyé le contrat.",
                preferredLanguage: .french
            )
        )

        XCTAssertEqual(
            preparation.normalizedText,
            "1. Vérifier le budget.\n2. Appelé Camille.\n3. Envoyé le contrat."
        )
        XCTAssertFalse(preparation.shouldUsePolisher)
    }

    func testSpeechContextVocabularyUsesDictionaryAndDeveloperTerms() {
        let personalization = PersonalizationSnapshot(
            dictionary: [
                DictionaryEntry(canonical: "Aris", spokenForms: ["Harris"]),
                DictionaryEntry(
                    canonical: "PrivateTerm",
                    bundleIdentifiers: ["com.example.other"]
                ),
            ]
        )
        let context = TextProcessingContext(
            bundleIdentifier: "com.openai.codex",
            applicationName: "Codex"
        )

        let terms = SpeechContextVocabulary.terms(
            profile: .prompt,
            context: context,
            personalization: personalization
        )

        XCTAssertTrue(terms.contains("Aris"))
        XCTAssertTrue(terms.contains("Cursor"))
        XCTAssertTrue(terms.contains("git status"))
        XCTAssertTrue(terms.contains("--no-cache"))
        XCTAssertFalse(terms.contains("Harris"))
        XCTAssertFalse(terms.contains("PrivateTerm"))
        XCTAssertEqual(terms.count, Set(terms.map { $0.lowercased() }).count)
    }

    func testFrenchNormalizationRemovesFillerAndPreservesProtectedFacts() {
        let request = TextProcessingRequest(
            rawTranscript: "euh ajoute --no-cache dans /src/auth.ts le 20/07/2026",
            preferredLanguage: .french,
            context: TextProcessingContext(applicationName: "Cursor"),
            personalization: PersonalizationSnapshot(
                dictionary: [DictionaryEntry(canonical: "VoxoL")]
            )
        )

        let result = DeterministicTextProcessor.prepare(request)

        XCTAssertFalse(result.normalizedText.lowercased().contains("euh"))
        XCTAssertTrue(result.normalizedText.contains("--no-cache"))
        XCTAssertTrue(result.normalizedText.contains("/src/auth.ts"))
        XCTAssertTrue(result.normalizedText.contains("20/07/2026"))
        XCTAssertEqual(
            Set(result.protectedTokens.map(\.value)),
            Set(["--no-cache", "/src/auth.ts", "20/07/2026"]))
    }

    func testDictionaryReplacementAndExactSnippetAreDeterministic() {
        let personalization = PersonalizationSnapshot(
            dictionary: [
                DictionaryEntry(canonical: "PostgreSQL", spokenForms: ["post gres q l"])
            ],
            snippets: [
                VoiceSnippet(trigger: "my status", expansion: "Progress:\nBlockers:\nNext steps:")
            ]
        )
        let dictionaryResult = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "open post gres q l",
                preferredLanguage: .english,
                personalization: personalization
            )
        )
        let snippetResult = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "my status",
                preferredLanguage: .english,
                personalization: personalization
            )
        )

        XCTAssertEqual(dictionaryResult.normalizedText, "Open PostgreSQL")
        XCTAssertTrue(dictionaryResult.protectedTokens.contains { $0.value == "PostgreSQL" })
        XCTAssertEqual(snippetResult.normalizedText, "Progress:\nBlockers:\nNext steps:")
        XCTAssertTrue(snippetResult.usedSnippet)
        XCTAssertFalse(snippetResult.shouldUsePolisher)
    }

    func testCleanCaptureAndResolvedCorrectionUseFastPath() {
        let short = DeterministicTextProcessor.prepare(
            TextProcessingRequest(rawTranscript: "hello Maya", preferredLanguage: .english)
        )
        let correction = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "send it Tuesday actually Wednesday morning",
                preferredLanguage: .english
            )
        )

        XCTAssertFalse(short.shouldUsePolisher)
        XCTAssertFalse(correction.shouldUsePolisher)
    }

    func testResolvedFillerAndExplicitListStayOnFastPath() {
        let filler = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "euh envoie le rapport demain matin à VoxoL",
                preferredLanguage: .french
            )
        )
        let list = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "bullet apples bullet bananas",
                preferredLanguage: .english
            )
        )

        XCTAssertEqual(filler.normalizedText, "Envoie le rapport demain matin à VoxoL")
        XCTAssertFalse(filler.shouldUsePolisher)
        XCTAssertEqual(list.normalizedText, "• Apples\n• Bananas")
        XCTAssertFalse(list.shouldUsePolisher)
    }

    func testSpokenYearDoesNotLoseRepeatedNumberWord() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript:
                    "The release is scheduled for July twenty fourth twenty twenty six",
                preferredLanguage: .english
            )
        )

        XCTAssertEqual(
            preparation.normalizedText,
            "The release is scheduled for July twenty fourth twenty twenty six"
        )
    }

    func testTechnicalDotsDoNotGainSpaces() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "Open MainRootView.swift and example..com",
                preferredLanguage: .english
            )
        )

        XCTAssertEqual(
            preparation.normalizedText,
            "Open MainRootView.swift and example..com"
        )
    }

    func testDocumentEndingInCommaGetsOneTerminalPeriod() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "This captured sentence ends at a chunk boundary,",
                preferredLanguage: .english,
                preferences: TextProcessingPreferences(
                    fastPathEnabled: false,
                    profile: .document
                )
            )
        )

        XCTAssertEqual(
            preparation.normalizedText,
            "This captured sentence ends at a chunk boundary."
        )
    }

    func testInstantModeRoutesShortCorrectionCandidatesButBypassesGreeting() {
        let shortGreeting = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "Bonjour Maya",
                preferredLanguage: .french
            )
        )
        let grammaticalSentence = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "Les rapport sont prêt",
                preferredLanguage: .french
            )
        )
        let naturalEnumeration = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript:
                    "Les priorités sont envoyer le rapport appeler Maya et revoir les chiffres",
                preferredLanguage: .french
            )
        )

        XCTAssertFalse(shortGreeting.shouldUsePolisher)
        XCTAssertTrue(grammaticalSentence.shouldUsePolisher)
        XCTAssertTrue(naturalEnumeration.shouldUsePolisher)
        XCTAssertTrue(
            PolishingPromptBuilder.build(from: naturalEnumeration).system.contains("puces")
        )
    }

    func testDisablingInstantModeExplicitlyRequestsPolisher() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "Les rapport sont prêt",
                preferredLanguage: .french,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )

        XCTAssertTrue(preparation.shouldUsePolisher)
    }

    func testPromptDisablesAnswersAndUsesBoundedOutputBudget() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "What is two plus two do not answer",
                preferredLanguage: .english,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )

        let prompt = PolishingPromptBuilder.build(from: preparation)

        XCTAssertTrue(prompt.system.contains("Never answer"))
        XCTAssertTrue(prompt.user.contains("DICTATION TO CLEAN:\n"))
        XCTAssertFalse(prompt.user.contains("{"))
        XCTAssertFalse(prompt.user.contains("CONTEXT BEFORE:"))
        XCTAssertEqual(PolishingPrompt.version, "voxol-cleanup-v5")
        XCTAssertLessThanOrEqual(prompt.maximumOutputTokens, 384)
    }

    func testPromptExplicitlyListsEveryProtectedPlaceholder() throws {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "Keep 4500 euros and 24/07/2026 exactly",
                preferredLanguage: .english,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )

        let prompt = PolishingPromptBuilder.build(from: preparation)
        let protectedLine = try XCTUnwrap(
            prompt.user.split(separator: "\n").first { $0.hasPrefix("KEEP EXACTLY: ") }
        )
        XCTAssertEqual(
            String(protectedLine),
            "KEEP EXACTLY: "
                + preparation.protectedTokens.map(\.placeholder).joined(separator: " | ")
        )
    }

    func testProtectedPlaceholdersUseTokenizerSafeASCII() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: "Keep 4500 and 24/07/2026 exactly",
                preferredLanguage: .english,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )

        XCTAssertEqual(
            preparation.protectedTokens.map(\.placeholder),
            ["VOXOLP0", "VOXOLP1"]
        )
        XCTAssertTrue(preparation.promptText.unicodeScalars.allSatisfy(\.isASCII))
    }

    func testProtectedFrenchPromptHasEnoughOutputHeadroom() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript:
                    "Le budget est 4200 euros non pardon 4500 euros et la livraison est le 24 juillet 2026",
                preferredLanguage: .french,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )
        let prompt = PolishingPromptBuilder.build(from: preparation)
        let sourceWords = preparation.promptText.split { !$0.isLetter && !$0.isNumber }.count

        XCTAssertGreaterThanOrEqual(prompt.maximumOutputTokens, sourceWords * 2)
    }

    func testLongRepetitionAndComplexUnicodeRemainBounded() {
        let repeated = Array(repeating: "bonjour", count: 2_000).joined(separator: " ")
        let result = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: repeated + " 👩🏽‍💻 e\u{301}xemple 42",
                preferredLanguage: .french
            )
        )

        XCTAssertLessThan(result.normalizedText.count, 80)
        XCTAssertTrue(result.normalizedText.contains("42"))
        XCTAssertTrue(result.protectedTokens.contains { $0.value == "42" })
    }
}
