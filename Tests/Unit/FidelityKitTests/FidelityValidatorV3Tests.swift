import XCTest

@testable import FidelityKit
@testable import TextProcessingKit

final class FidelityValidatorV3Tests: XCTestCase {
    func testQuestionIntentCannotBecomeAStatement() {
        let source = "Je pense qu'il faut revoir le plan, non ?"
        let decision = FidelityValidatorV3.validateWithRepair(
            candidate: "Je pense qu'il faut revoir le plan, non.",
            against: prepared(source, language: .french)
        )

        XCTAssertEqual(decision.status, .rejected)
        XCTAssertEqual(decision.rejectionReason, .propositionChanged)
    }

    func testDiagnosticRewriteEditScript() {
        let script = EditScript.build(
            source: "en fait le rapport est presque terminé quoi",
            candidate: "Le rapport est presque terminé."
        )
        XCTAssertEqual(
            script.edits.filter { $0.kind == .substitution }.count,
            0,
            "\(script.edits)"
        )
    }

    func testCanonicalNumberFormsProduceTheSameFact() {
        let digits = FactLedger.extract(from: "le délai est de 3 jours", language: .french)
        let words = FactLedger.extract(from: "le délai est de trois jours", language: .french)

        XCTAssertTrue(digits.isEquivalent(to: words))
    }

    func testSwappingNumbersBetweenRolesIsRejected() {
        let preparation = prepared(
            "le port 80 utilise un délai de 30 secondes",
            language: .french
        )
        let decision = FidelityValidatorV3.validateWithRepair(
            candidate: "Le port 30 utilise un délai de 80 secondes.",
            against: preparation
        )

        XCTAssertEqual(decision.status, .rejected)
        XCTAssertEqual(decision.rejectionReason, .factChanged)
    }

    func testPropositionOperatorsCannotChange() {
        let cases: [(String, String)] = [
            ("le serveur ne redémarre pas", "Le serveur redémarre."),
            ("le dossier doit rester fermé", "Le dossier peut rester fermé."),
            ("seulement les admins entrent", "Les admins entrent."),
            ("si le test passe on publie", "Le test passe, on publie."),
        ]

        for (source, candidate) in cases {
            let decision = FidelityValidatorV3.validateWithRepair(
                candidate: candidate,
                against: prepared(source, language: .french)
            )
            XCTAssertEqual(decision.status, .rejected, "operator change passed: \(source)")
            XCTAssertEqual(decision.rejectionReason, .propositionChanged)
        }
    }

    func testUnsafeClauseIsRevertedWithoutLosingSafeCleanup() {
        let preparation = prepared(
            "le rapport est pret. le port 80 reste ouvert.",
            language: .french
        )
        let decision = FidelityValidatorV3.validateWithRepair(
            candidate: "Le rapport est prêt. Le port 81 reste ouvert.",
            against: preparation
        )

        XCTAssertEqual(decision.status, .repaired)
        XCTAssertEqual(decision.repairedClauseCount, 1)
        XCTAssertTrue(decision.text.contains("rapport est prêt"))
        XCTAssertTrue(decision.text.contains("port 80"))
        XCTAssertFalse(decision.text.contains("port 81"))
    }

    func testDictionarySubstitutionNeedsCalibratedAcousticRisk() {
        let source = "ouvre vocal maintenant"
        let highRisk = preparationWithEvidence(source: source, errorProbability: 0.9)
        let lowRisk = preparationWithEvidence(source: source, errorProbability: 0.1)

        XCTAssertEqual(
            FidelityValidatorV3.validateWithRepair(
                candidate: "Ouvre voxol maintenant.",
                against: highRisk
            ).status,
            .accepted
        )
        let rejected = FidelityValidatorV3.validateWithRepair(
            candidate: "Ouvre voxol maintenant.",
            against: lowRisk
        )
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(rejected.rejectionReason, .unsupportedEdit)
    }

    func testExactArtifactCannotDisappear() {
        let preparation = prepared(
            "ouvre https://voxol.app maintenant",
            language: .french
        )
        let decision = FidelityValidatorV3.validateWithRepair(
            candidate: "Ouvre le site maintenant.",
            against: preparation
        )

        XCTAssertEqual(decision.status, .rejected)
        XCTAssertEqual(decision.rejectionReason, .exactArtifactChanged)
    }
}

private extension FidelityValidatorV3Tests {
    func prepared(_ text: String, language: TextLanguage) -> DeterministicPreparation {
        DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: text,
                preferredLanguage: language,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )
    }

    func preparationWithEvidence(
        source: String,
        errorProbability: Double
    ) -> DeterministicPreparation {
        let range = (source as NSString).range(of: "vocal")
        let evidence = TranscriptEvidence(
            sourceText: source,
            source: .parakeet,
            words: [
                TranscriptWordEvidence(
                    surface: "vocal",
                    sourceRange: range.location..<(range.location + range.length),
                    minimumLogitMargin: 0.2,
                    meanLogitMargin: 0.3,
                    calibratedErrorProbability: errorProbability,
                    contextBiasActive: false,
                    nearChunkBoundary: false
                )
            ]
        )
        return DeterministicPreparation(
            rawTranscript: source,
            normalizedText: source,
            promptText: source,
            protectedTokens: [],
            language: .french,
            profile: .chat,
            shouldUsePolisher: true,
            usedSnippet: false,
            dictionaryTerms: ["voxol"],
            context: TextProcessingContext(),
            automaticLists: false,
            cleanupMode: .faithful,
            transcriptEvidence: evidence,
            featureFlags: TextQualityFeatureFlags(selectiveASRRescue: true)
        )
    }
}
