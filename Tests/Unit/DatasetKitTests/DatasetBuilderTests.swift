import DatasetKit
import XCTest

final class DatasetBuilderTests: XCTestCase {
    func testRejectsUnapprovedAndMissingProtectedTokens() {
        let unapproved = example(id: "unapproved", approved: false)
        let unsafe = example(
            id: "unsafe",
            protectedTokens: ["42"],
            targetText: "Send it tomorrow."
        )

        let result = DatasetBuilder.build([unapproved, unsafe])

        XCTAssertEqual(Set(result.rejectedIDs), Set(["unapproved", "unsafe"]))
        XCTAssertTrue(result.train.isEmpty)
        XCTAssertTrue(result.validation.isEmpty)
        XCTAssertTrue(result.test.isEmpty)
    }

    func testSplitIsStableAndOutputUsesRuntimePrompt() {
        let examples = (0..<100).map { index in
            example(
                id: "session-\(index)",
                rawTranscript: "um send item \(index)",
                targetText: "Send item \(index)."
            )
        }

        let first = DatasetBuilder.build(examples)
        let second = DatasetBuilder.build(examples.reversed())

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.train.count + first.validation.count + first.test.count, 100)
        XCTAssertEqual(first.train.first?.messages.map(\.role), ["system", "user", "assistant"])
    }

    func testExplicitSourceGroupsCannotCrossSplits() {
        let train = example(id: "train", split: "train", splitGroup: "recording")
        let test = example(id: "test", split: "test", splitGroup: "recording")

        let result = DatasetBuilder.build([train, test])

        XCTAssertEqual(Set(result.rejectedIDs), Set(["train", "test"]))
        XCTAssertTrue(result.train.isEmpty)
        XCTAssertTrue(result.test.isEmpty)
    }

    func testExplicitSplitOverridesIdentifierBucket() {
        let validation = example(
            id: "forced-validation",
            split: "validation",
            splitGroup: "recording"
        )

        let result = DatasetBuilder.build([validation])

        XCTAssertEqual(result.validation.count, 1)
        XCTAssertTrue(result.train.isEmpty)
        XCTAssertTrue(result.test.isEmpty)
    }

    private func example(
        id: String,
        protectedTokens: [String] = [],
        rawTranscript: String = "um send it tomorrow",
        targetText: String = "Send it tomorrow.",
        approved: Bool = true,
        split: String? = nil,
        splitGroup: String? = nil
    ) -> CleanupDatasetExample {
        CleanupDatasetExample(
            id: id,
            language: "en",
            profile: "email",
            appCategory: "email",
            protectedTokens: protectedTokens,
            rawTranscript: rawTranscript,
            targetText: targetText,
            source: "human",
            approved: approved,
            split: split,
            splitGroup: splitGroup
        )
    }

    func testAutomaticallyDiscoveredProtectedValuesCannotDisappear() {
        let unsafe = example(
            id: "unsafe-auto-token",
            rawTranscript: "Keep 42 in the report",
            targetText: "Keep the report"
        )

        let result = DatasetBuilder.build([unsafe])

        XCTAssertEqual(result.rejectedIDs, ["unsafe-auto-token"])
    }

    func testRejectsTargetThatRequiresMissingSourceContent() {
        let impossible = example(
            id: "audio-only-recovery",
            rawTranscript: "The meeting starts tomorrow",
            targetText:
                "The customer meeting starts tomorrow and includes the quarterly budget review"
        )

        let result = DatasetBuilder.build([impossible])

        XCTAssertEqual(result.rejectedIDs, ["audio-only-recovery"])
        XCTAssertTrue(result.train.isEmpty)
    }

    func testProtectedNegationDoesNotReplaceLettersInsideWords() throws {
        let source = example(
            id: "negation-boundaries",
            rawTranscript: "Une phrase ne change jamais",
            targetText: "Une phrase ne change jamais.",
            split: "test"
        )

        let result = DatasetBuilder.build([source])
        let target = try XCTUnwrap(result.test.first?.messages.last?.content)

        XCTAssertTrue(target.hasPrefix("Une phrase "))
        XCTAssertFalse(target.contains("uVOXOLP"))
        XCTAssertFalse(target.contains("phraVOXOLP"))
        XCTAssertEqual(target.components(separatedBy: "VOXOLP").count - 1, 2)
    }

    func testPreparationMatchesProductionProtectedTokens() {
        let source = example(
            id: "runtime-preparation",
            rawTranscript: "Use port 8080 today.",
            targetText: "Use port 8080 today."
        )

        let preparation = DatasetBuilder.prepare(source)

        XCTAssertEqual(preparation.normalizedText, "Use port 8080 today.")
        XCTAssertEqual(preparation.protectedTokens.map(\.value), ["8080"])
        XCTAssertTrue(preparation.promptText.contains("VOXOLP0"))
    }

    func testEvaluationReportsFidelityWithoutContent() throws {
        let result = CleanupEvaluator.evaluate([
            CleanupEvaluationExample(
                id: "exact",
                expectedText: "Keep 42",
                actualText: "Keep 42",
                protectedTokens: ["42"]
            ),
            CleanupEvaluationExample(
                id: "changed",
                expectedText: "Send tomorrow",
                actualText: "Send confidential today",
                protectedTokens: ["tomorrow"]
            ),
        ])

        XCTAssertEqual(result.exampleCount, 2)
        XCTAssertEqual(result.exactMatchRate, 0.5)
        XCTAssertEqual(result.protectedTokenRecall, 0.5)
        XCTAssertGreaterThan(result.unexpectedWordRate, 0)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("confidential"))
        XCTAssertFalse(encoded.contains("tomorrow"))
    }
}
