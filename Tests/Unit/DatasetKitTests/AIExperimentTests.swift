import DatasetKit
import XCTest

final class AIExperimentTests: XCTestCase {
    private func row(
        id: String = "ai-one", source: String = "ai-curated-experimental",
        approved: Bool = false, target: String = "Keep port 8080.",
        split: String = "train"
    ) -> CleanupDatasetExample {
        CleanupDatasetExample(
            id: id, language: "en", profile: "document", appCategory: "document",
            protectedTokens: ["8080"], rawTranscript: "Keep port 8080.",
            targetText: target, source: source, approved: approved,
            split: split, splitGroup: "one-recording", mode: "faithful"
        )
    }

    func testHumanLaneStillRejectsAICuration() {
        XCTAssertEqual(DatasetBuilder.build([row()]).rejectedIDs, ["ai-one"])
    }

    func testExplicitAILaneUsesRuntimePromptWithoutHumanApproval() {
        let result = DatasetBuilder.buildAIExperiment([row()])
        XCTAssertEqual(result.train.count, 1)
        XCTAssertTrue(result.rejectedIDs.isEmpty)
        XCTAssertTrue(result.train[0].messages[0].content.contains("You correct English dictation."))
        XCTAssertTrue(result.train[0].messages[2].content.contains("VOXOLP0"))
    }

    func testAILaneRejectsWrongProvenanceAndHumanApproval() {
        for input in [row(source: "human"), row(approved: true)] {
            XCTAssertEqual(DatasetBuilder.buildAIExperiment([input]).rejectedIDs, ["ai-one"])
        }
    }

    func testAILanePreservesValuesAndGroupIsolation() {
        XCTAssertEqual(
            DatasetBuilder.buildAIExperiment([row(target: "Keep port 8081.")]).rejectedIDs,
            ["ai-one"]
        )
        let result = DatasetBuilder.buildAIExperiment([
            row(id: "train"), row(id: "validation", split: "validation"),
        ])
        XCTAssertEqual(Set(result.rejectedIDs), Set(["train", "validation"]))
    }
}
