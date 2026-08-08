import Foundation
import XCTest

@testable import TextProcessingKit

final class RepairShadowTests: XCTestCase {
    private let dictionary = ["chipset", "B450", "raw", "edited", "Kubernetes"]

    private func words(
        _ pairs: [(String, Float)]
    ) -> [(word: String, margin: Float)] {
        pairs.map { (word: $0.0, margin: $0.1) }
    }

    func testTheErrorMotivatingThisThatTextCanReach() {
        // Dictating in French, `edited` came back as `élite`: same first
        // letter, one edit apart once accents are folded away.
        let proposals = RepairShadow.proposals(
            words: words([("le", 9.0), ("normal", 8.1), ("élite", 1.2)]),
            dictionary: dictionary
        )

        XCTAssertEqual(proposals.map(\.candidate), ["edited"])
        XCTAssertEqual(proposals.map(\.index), [2])
    }

    func testTheErrorTextCannotReachIsNotGuessed() {
        // `raw` heard as `Ro` is two edits on three letters. Accepting that
        // would also accept `le` becoming `de`. It needs acoustic evidence,
        // and proposing it from spelling alone would be inventing.
        let proposals = RepairShadow.proposals(
            words: words([("Ro", 0.4)]),
            dictionary: dictionary
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testAConfidentWordIsNeverProposedForChange() {
        // 94% of words above the threshold are already right; touching them is
        // how a repair pass does more harm than good.
        let proposals = RepairShadow.proposals(
            words: words([("chipset", 9.0), ("raw", 8.0)]),
            dictionary: dictionary
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testADistantCandidateIsNotACorrection() {
        // `bonjour` is uncertain but nothing in the dictionary is a plausible
        // rendering of it; proposing one would be inventing, not repairing.
        let proposals = RepairShadow.proposals(
            words: words([("bonjour", 0.2)]),
            dictionary: dictionary
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testAWordThatAlreadySpellsATermIsLeftAlone() {
        // Without this, an uncertain but correct `edited` was proposed for
        // replacement by `editor` — one edit away, and completely wrong.
        let proposals = RepairShadow.proposals(
            words: words([("edited", 0.5)]),
            dictionary: ["edited", "edit", "editor"]
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testAccentsAndCaseDoNotBlockAMatch() {
        let proposals = RepairShadow.proposals(
            words: words([("Kubernétes", 0.3)]),
            dictionary: ["Kubernetes"]
        )

        XCTAssertEqual(proposals.first?.candidate, "Kubernetes")
    }

    func testAnEmptyDictionaryProposesNothing() {
        XCTAssertTrue(
            RepairShadow.proposals(
                words: words([("Ro", 0.1)]),
                dictionary: []
            ).isEmpty
        )
    }

    func testProposalsCarryWhatIsNeededToJudgeThemLater() {
        // The log has to support counting false substitutions after the fact,
        // which needs the confidence and the distance that let it through.
        let proposal = RepairShadow.proposals(
            words: words([("élite", 0.4)]),
            dictionary: ["edited"]
        ).first

        XCTAssertEqual(proposal?.heard, "élite")
        XCTAssertEqual(proposal?.margin, 0.4)
        XCTAssertNotNil(proposal?.distance)
        XCTAssertLessThanOrEqual(
            proposal?.distance ?? 1,
            RepairShadow.defaultDistanceThreshold
        )
    }

    func testEncodesForLogging() throws {
        let proposal = RepairShadow.Proposal(
            heard: "Ro",
            candidate: "raw",
            index: 2,
            margin: 0.4,
            distance: 0.33
        )

        let data = try JSONEncoder().encode(proposal)
        let restored = try JSONDecoder().decode(
            RepairShadow.Proposal.self,
            from: data
        )

        XCTAssertEqual(restored, proposal)
    }
}
