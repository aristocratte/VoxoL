import XCTest

@testable import FidelityKit
@testable import TextProcessingKit

/// The release gate: several hundred generated meaning-flip attempts, none of
/// which may ever pass, and benign cleanups that must keep passing.
///
/// A validator proven on five hand-picked cases is proven on five cases. This
/// generates the space systematically — negation drops, quantifier drops,
/// modality swaps, condition drops, entity swaps, protected-token loss —
/// across both languages and both contracts, and fails the build on the first
/// candidate that slips through. The benign half exists because a gate that
/// blocks everything also blocks the product: filler removal under the
/// rewrite contract has to keep working or safety has quietly eaten quality.
final class ChallengeCorpusTests: XCTestCase {
    private func prepared(
        _ text: String,
        language: TextLanguage,
        mode: CleanupMode
    ) -> DeterministicPreparation {
        DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: text,
                preferredLanguage: language,
                preferences: TextProcessingPreferences(
                    cleanupMode: mode,
                    fastPathEnabled: false
                )
            )
        )
    }

    private struct Attack {
        let source: String
        let candidate: String
        let label: String
    }

    private static let frenchBodies = [
        "le contrat est signé par le client",
        "la sauvegarde est activée sur le poste",
        "le rapport part vendredi soir",
        "l'équipe valide la proposition demain",
        "le serveur redémarre après la mise à jour",
        "la facture est réglée par le prestataire",
        "le dossier reste accessible aux invités",
        "la livraison arrive avant la réunion",
    ]

    private static let englishBodies = [
        "the contract is signed by the client",
        "the backup is enabled on this machine",
        "the report goes out on friday evening",
        "the team approves the proposal tomorrow",
        "the server restarts after the update",
        "the invoice is paid by the vendor",
        "the folder stays accessible to guests",
        "the delivery arrives before the meeting",
    ]

    private func attacks(for language: TextLanguage) -> [Attack] {
        let bodies = language == .french ? Self.frenchBodies : Self.englishBodies
        var attacks: [Attack] = []
        for body in bodies {
            if language == .french {
                // Négation supprimée : le sens s'inverse. Émise seulement si la
                // phrase porte réellement une négation à supprimer — sinon le
                // candidat n'est qu'un nettoyage bénin, accepté à raison.
                let negated = body.replacingOccurrences(of: " est ", with: " n'est pas ")
                if negated != body {
                    attacks.append(
                        Attack(
                            source: "en fait \(negated)",
                            candidate: sentenceCase(body),
                            label: "negation-drop"
                        )
                    )
                }
                // Quantificateur supprimé : « seulement » disparaît.
                attacks.append(
                    Attack(
                        source: "donc seulement \(body)",
                        candidate: sentenceCase(body),
                        label: "quantifier-drop"
                    )
                )
                // Modalité inversée : obligation devient permission.
                attacks.append(
                    Attack(
                        source: "le dossier doit rester fermé ce soir vraiment \(body)",
                        candidate: sentenceCase(
                            "le dossier peut rester fermé ce soir vraiment \(body)"
                        ),
                        label: "modality-swap"
                    )
                )
                // Condition supprimée.
                attacks.append(
                    Attack(
                        source: "sauf contrordre \(body)",
                        candidate: sentenceCase(body),
                        label: "condition-drop"
                    )
                )
                // Entité remplacée.
                attacks.append(
                    Attack(
                        source: "d'après Martin \(body)",
                        candidate: sentenceCase("d'après Julien \(body)"),
                        label: "entity-swap"
                    )
                )
            } else {
                let negated = body.replacingOccurrences(of: " is ", with: " is not ")
                if negated != body {
                    attacks.append(
                        Attack(
                            source: "so \(negated)",
                            candidate: sentenceCase(body),
                            label: "negation-drop"
                        )
                    )
                }
                attacks.append(
                    Attack(
                        source: "well only \(body)",
                        candidate: sentenceCase(body),
                        label: "quantifier-drop"
                    )
                )
                attacks.append(
                    Attack(
                        source: "the folder must stay closed tonight honestly \(body)",
                        candidate: sentenceCase(
                            "the folder may stay closed tonight honestly \(body)"
                        ),
                        label: "modality-swap"
                    )
                )
                attacks.append(
                    Attack(
                        source: "unless told otherwise \(body)",
                        candidate: sentenceCase(body),
                        label: "condition-drop"
                    )
                )
                attacks.append(
                    Attack(
                        source: "according to Martin \(body)",
                        candidate: sentenceCase("according to Julian \(body)"),
                        label: "entity-swap"
                    )
                )
            }
        }
        return attacks
    }

    private func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst() + "."
    }

    func testNoMeaningFlipPassesInEitherModeOrLanguage() {
        var checked = 0
        for language in [TextLanguage.french, .english] {
            for mode in [CleanupMode.faithful, .rewrite] {
                for attack in attacks(for: language) {
                    let preparation = prepared(attack.source, language: language, mode: mode)
                    let decision = FidelityValidator.validateWithRepair(
                        candidate: attack.candidate,
                        against: preparation
                    )
                    checked += 1
                    XCTAssertFalse(
                        decision.usedModelOutput,
                        "\(attack.label) [\(language)/\(mode)] est passé : "
                            + "« \(attack.source) » → « \(attack.candidate) »"
                    )
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 140)
    }

    func testProtectedTokenLossNeverPasses() {
        // Numbers are minted into placeholders by the deterministic layer; a
        // candidate that loses one is rejected whatever else it fixed.
        let sources = [
            (TextLanguage.french, "la livraison prend trois jours en fait pas plus"),
            (TextLanguage.english, "the delivery takes three days actually no more"),
        ]
        for (language, source) in sources {
            for mode in [CleanupMode.faithful, .rewrite] {
                let preparation = prepared(source, language: language, mode: mode)
                guard let token = preparation.protectedTokens.first else {
                    XCTFail("expected a protected token in « \(source) »")
                    continue
                }
                let candidate = preparation.promptText
                    .replacingOccurrences(of: token.placeholder, with: "")
                let decision = FidelityValidator.validateWithRepair(
                    candidate: candidate,
                    against: preparation
                )
                XCTAssertFalse(decision.usedModelOutput, "token loss passed [\(language)/\(mode)]")
            }
        }
    }

    func testBenignCleanupsKeepPassingInRewrite() {
        let benign: [(TextLanguage, String, String)] = [
            (
                .french,
                "en fait le rapport est presque terminé quoi",
                "Le rapport est presque terminé."
            ),
            (
                .french,
                "bah écoute la maquette est prête hein",
                "La maquette est prête."
            ),
            (
                .french,
                "donc euh je te partage le lien du dossier ce soir",
                "Je te partage le lien du dossier ce soir."
            ),
            (
                .english,
                "so basically the report is like almost done",
                "The report is almost done."
            ),
            (
                .english,
                "well the mockup is ready you know",
                "The mockup is ready."
            ),
        ]
        for (language, source, candidate) in benign {
            let preparation = prepared(source, language: language, mode: .rewrite)
            let decision = FidelityValidator.validateWithRepair(
                candidate: candidate,
                against: preparation
            )
            XCTAssertTrue(
                decision.usedModelOutput,
                "un nettoyage bénin est bloqué [\(language)] : « \(source) » → « \(candidate) »"
                    + " (\(decision.rejectionReason?.rawValue ?? "?"))"
            )
        }
    }
}
