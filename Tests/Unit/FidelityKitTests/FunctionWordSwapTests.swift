import XCTest

@testable import FidelityKit
@testable import TextProcessingKit

/// In faithful mode a swap between closed-class words ("des → mais", "du → que", "mes → tes")
/// changes what was said while every content word survives; agreement, elision and homophone
/// fixes of the same words stay allowed.
final class FunctionWordSwapTests: XCTestCase {
    func testFunctionWordSwapIsRejected() {
        for (source, candidate, language) in [
            ("On parle du module de paiement.", "On parle que module de paiement.", TextLanguage.french),
            ("Je vérifie les fichiers de la base.", "Je vérifie les fichiers en la base.", .french),
            ("Envoie mes notes demain.", "Envoie tes notes demain.", .french),
            ("Il faut des tests avant la livraison.", "Il faut mais tests avant la livraison.", .french),
            ("Send the report to Nora.", "Send the report for Nora.", .english),
            ("Send it to the team and the client.", "Send it to the team or the client.", .english),
        ] {
            let decision = FidelityValidator.validate(
                candidate: candidate, against: prepared(source, language: language))
            XCTAssertFalse(decision.usedModelOutput, "\(source) -> \(candidate)")
            XCTAssertEqual(decision.rejectionReason, .functionWordChanged, "\(source) -> \(candidate)")
        }
    }

    func testFunctionWordDeletionIsRejectedInFaithfulMode() {
        let decision = FidelityValidator.validate(
            candidate: "Je relis le texte je corrige les fautes.",
            against: prepared("Je relis le texte et je corrige les fautes."))
        XCTAssertFalse(decision.usedModelOutput)
        XCTAssertEqual(decision.rejectionReason, .functionWordChanged)
    }

    func testDuplicatedFunctionWordMayBeRemoved() {
        // The deterministic layer already collapses most stutters, so the rule is called directly.
        XCTAssertFalse(
            FidelityValidator.functionWordChanged(
                source: "Je relis le le texte.", candidate: "Je relis le texte.", language: .french))
    }

    func testHomophoneAndAuxiliaryFixesStayAccepted() {
        for (source, candidate, language) in [
            ("Il a pris sont ordinateur", "Il a pris son ordinateur.", TextLanguage.french),
            ("Les fichiers est prêts", "Les fichiers sont prêts.", .french),
            ("Il part ou il reste", "Il part où il reste.", .french),
            ("I need a apple", "I need an apple.", .english),
        ] {
            let decision = FidelityValidator.validate(
                candidate: candidate, against: prepared(source, language: language))
            XCTAssertTrue(
                decision.usedModelOutput,
                "\(source) -> \(candidate): \(String(describing: decision.rejectionReason))")
        }
    }

    func testSentenceRepairKeepsOtherFixesWhenAFunctionWordIsSwapped() {
        let decision = FidelityValidator.validateWithRepair(
            candidate: "Les documents sont complets. On parle que module de paiement.",
            against: prepared("Les document sont complet. On parle du module de paiement."))
        XCTAssertTrue(decision.usedModelOutput)
        XCTAssertEqual(decision.text, "Les documents sont complets. On parle du module de paiement.")
        XCTAssertEqual(decision.repairedSentenceCount, 1)
    }

    func testRewriteModeMayChangeFunctionWords() {
        let decision = FidelityValidator.validate(
            candidate: "On parle de ce module de paiement.",
            against: prepared("On parle du module de paiement.", mode: .rewrite))
        XCTAssertNotEqual(decision.rejectionReason, .functionWordChanged)
    }

    func testElisionFixIsAccepted() {
        for (source, candidate) in [
            ("Je vais envoyer le email au client demain.", "Je vais envoyer l'email au client demain."),
            ("Il faut tester le endpoint ce soir.", "Il faut tester l'endpoint ce soir."),
            ("On contacte la entreprise lundi.", "On contacte l'entreprise lundi."),
        ] {
            let decision = FidelityValidator.validateWithRepair(
                candidate: candidate, against: prepared(source))
            XCTAssertEqual(decision.text, candidate, "\(source)")
        }
    }

    func testRepairNeverStacksAnArticleOnAnElision() {
        for (source, candidate) in [
            ("Je vais envoyer le email au client demain.", "Je vais envoyer l'email au client demain."),
            ("Je parle de Apple ce matin.", "Je parle d'Apple ce matin."),
        ] {
            let text = FidelityValidator.validateWithRepair(
                candidate: candidate, against: prepared(source)
            ).text.lowercased()
            for stacked in ["le l'", "la l'", "de d'"] {
                XCTAssertFalse(text.contains(stacked), "\(source) -> \(text)")
            }
        }
    }

    func testDeterminerAgreementAndSelfCorrectionStayAccepted() {
        for (source, candidate) in [
            ("Je relis le fichiers ce soir.", "Je relis les fichiers ce soir."),
            ("On a un réunion demain.", "On a une réunion demain."),
            ("Envoie le lien au utilisateurs.", "Envoie le lien aux utilisateurs."),
            ("Ils rangent leur fichiers.", "Ils rangent leurs fichiers."),
            ("On parle de le projet.", "On parle du projet."),
            ("Le la voiture est garée.", "La voiture est garée."),
        ] {
            let decision = FidelityValidator.validate(candidate: candidate, against: prepared(source))
            XCTAssertTrue(
                decision.usedModelOutput,
                "\(source) -> \(candidate): \(String(describing: decision.rejectionReason))")
        }
    }

    func testStutterExemptionIsPositional() {
        XCTAssertTrue(
            FidelityValidator.functionWordChanged(
                source: "Je lis et et je dors, je mange et je bois.",
                candidate: "Je lis et et je dors, je mange je bois.", language: .french))
    }

    func testAlphanumericIdentifierIsKept() {
        let decision = FidelityValidator.validate(
            candidate: "Configure la carte B45 ce soir.",
            against: prepared("Configure la carte B450 ce soir."))
        XCTAssertFalse(decision.usedModelOutput)
    }

    private func prepared(
        _ text: String, language: TextLanguage = .french, mode: CleanupMode = .faithful
    ) -> DeterministicPreparation {
        DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: text,
                preferredLanguage: language,
                preferences: TextProcessingPreferences(cleanupMode: mode, fastPathEnabled: false)
            )
        )
    }
}
