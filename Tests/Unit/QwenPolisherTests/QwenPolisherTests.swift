import XCTest

@testable import QwenPolisher
@testable import TextProcessingKit

final class QwenPolisherTests: XCTestCase {
    func testDefaultGenerationConfigurationUsesMeasuredFastPath() {
        let configuration = QwenPolisherGenerationConfiguration()

        XCTAssertNil(configuration.maximumKVCacheSize)
        XCTAssertEqual(configuration.prefillStepSize, 512)
        XCTAssertTrue(configuration.usesPromptPrefixCache)
        XCTAssertTrue(configuration.fusesAdapter)
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
