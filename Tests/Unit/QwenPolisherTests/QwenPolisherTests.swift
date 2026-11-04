import XCTest

@testable import QwenPolisher
@testable import TextProcessingKit

final class QwenPolisherTests: XCTestCase {
    func testReusableBufferCacheBudgetDoesNotBecomeNegative() {
        XCTAssertEqual(QwenPolisherGenerationConfiguration().maximumBufferCacheBytes, 67_108_864)
        XCTAssertNil(
            QwenPolisherGenerationConfiguration(maximumBufferCacheBytes: nil)
                .maximumBufferCacheBytes)
        XCTAssertEqual(
            QwenPolisherGenerationConfiguration(maximumBufferCacheBytes: -1)
                .maximumBufferCacheBytes,
            0
        )
        XCTAssertEqual(
            QwenPolisherGenerationConfiguration(maximumBufferCacheBytes: 67_108_864)
                .maximumBufferCacheBytes,
            67_108_864
        )
    }

    func testTokenCeilingIsEnforcedIndependentlyOfMLXStopReason() {
        let below = QwenPolisherRuntime.outputLimitReached(
            outputTokenCount: 383, maximumOutputTokens: 384
        )
        let atLimit = QwenPolisherRuntime.outputLimitReached(
            outputTokenCount: 384, maximumOutputTokens: 384
        )
        let above = QwenPolisherRuntime.outputLimitReached(
            outputTokenCount: 385, maximumOutputTokens: 384
        )
        XCTAssertFalse(below)
        XCTAssertTrue(atLimit)
        XCTAssertTrue(above)
    }

    func testStructuredGenerationStopsAfterFirstCompleteJSONObject() {
        XCTAssertEqual(
            QwenPolisherRuntime.firstCompleteJSONObject(
                in: "preface {\"d\":[\"E16\"],\"x\":{\"note\":\"brace } and \\\"quote\\\"\"}} trailing"
            ),
            "{\"d\":[\"E16\"],\"x\":{\"note\":\"brace } and \\\"quote\\\"\"}}"
        )
        XCTAssertNil(QwenPolisherRuntime.firstCompleteJSONObject(in: "{\"d\":[\"E16\"]"))
    }

    func testDefaultGenerationConfigurationUsesMeasuredFastPath() {
        let configuration = QwenPolisherGenerationConfiguration()

        XCTAssertNil(configuration.maximumKVCacheSize)
        XCTAssertEqual(configuration.prefillStepSize, 512)
        XCTAssertTrue(configuration.usesPromptPrefixCache)
        XCTAssertTrue(configuration.fusesAdapter)
        XCTAssertNil(configuration.promptLookupTokenCount)
    }

    func testExperimentalDraftBudgetIsBoundedAndExplicit() {
        XCTAssertEqual(
            QwenPolisherGenerationConfiguration(promptLookupTokenCount: -1).promptLookupTokenCount,
            0)
        XCTAssertEqual(
            QwenPolisherGenerationConfiguration(promptLookupTokenCount: 8).promptLookupTokenCount, 8
        )
        XCTAssertEqual(
            QwenPolisherGenerationConfiguration(promptLookupTokenCount: 100).promptLookupTokenCount,
            16)
    }

    func testPromptLookupRequiresAnObservedOutputSuffix() {
        let index = PromptLookupIndex(tokens: [1, 2, 3, 4])
        XCTAssertEqual(index.draft(after: [], maximumCount: 8), [])
        XCTAssertEqual(index.draft(after: [9], maximumCount: 8), [])
        XCTAssertEqual(index.draft(after: [1, 2], maximumCount: 0), [])
        XCTAssertEqual(index.draft(after: [4], maximumCount: 8), [])
    }

    func testPromptLookupUsesLongestSuffixAndBoundsItsDraft() {
        let index = PromptLookupIndex(tokens: [1, 2, 3, 4, 5, 2, 3, 9])
        XCTAssertEqual(index.draft(after: [8, 1, 2, 3], maximumCount: 2), [4, 5])
        XCTAssertEqual(index.draft(after: [7, 2, 3], maximumCount: 8), [9])
    }

    func testPromptLookupHandlesEmptySource() {
        XCTAssertEqual(PromptLookupIndex(tokens: []).draft(after: [1], maximumCount: 8), [])
    }

    func testDraftVerificationNeverAcceptsPastTheFirstMismatch() {
        XCTAssertEqual(
            PromptLookupIndex.acceptedCount(
                draft: [1, 2, 3], predictions: [1, 9, 3, 4], stopTokenIDs: []),
            1
        )
        XCTAssertEqual(
            PromptLookupIndex.acceptedCount(
                draft: [1, 2], predictions: [9, 2, 3], stopTokenIDs: []),
            0
        )
    }

    func testDraftVerificationCannotEmitEOSOrUnverifiedTokens() {
        XCTAssertEqual(
            PromptLookupIndex.acceptedCount(
                draft: [1, 2, 3], predictions: [1, 2, 3, 4], stopTokenIDs: [2]),
            1
        )
        XCTAssertEqual(
            PromptLookupIndex.acceptedCount(draft: [1, 2, 3], predictions: [1], stopTokenIDs: []),
            1
        )
        XCTAssertEqual(
            PromptLookupIndex.acceptedCount(
                draft: [1, 2, 3], predictions: [1, 2, 3, 4], stopTokenIDs: []),
            3
        )
    }

    func testInstalledAdapterRequiresBothFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = root.appendingPathComponent("model", isDirectory: true)
        let adapter = root.appendingPathComponent("voxol-adapter", isDirectory: true)
        try FileManager.default.createDirectory(
            at: adapter,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(QwenPolisherRuntime.installedAdapterRoot(in: model))
        try Data("{}".utf8).write(
            to: adapter.appendingPathComponent("adapter_config.json")
        )
        XCTAssertNil(QwenPolisherRuntime.installedAdapterRoot(in: model))
        try Data().write(to: adapter.appendingPathComponent("adapters.safetensors"))

        XCTAssertEqual(QwenPolisherRuntime.installedAdapterRoot(in: model), adapter)
    }

    func testPromptBudgetStaysBoundedForLongTranscript() {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: (0..<2_000)
                    .map { $0.isMultiple(of: 2) ? "alpha" : "beta" }
                    .joined(separator: " "),
                preferredLanguage: .english,
                preferences: TextProcessingPreferences(fastPathEnabled: false)
            )
        )

        XCTAssertEqual(
            PolishingPromptBuilder.build(from: preparation).maximumOutputTokens,
            384
        )
    }
}
