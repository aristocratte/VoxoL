import ASRBenchmarkKit
import CryptoKit
import Foundation
import XCTest

final class InferenceManifestTests: XCTestCase {
    func testAudioOnlyInferenceDoesNotRelaxReviewedBenchmarkGate() throws {
        let item = ASRBenchmarkItem(
            id: "ai", audioPath: "clip.wav", speakerID: "speaker", sessionID: "session",
            split: .development, language: .french, microphone: "recorded", environment: "recorded",
            tags: [],
            reference: ASRBenchmarkReference(
                verbatim: "Bonjour", clean: "Bonjour.", reviewed: false)
        )
        let manifest = ASRBenchmarkManifest(benchmarkID: "diagnostic", items: [item])
        XCTAssertThrowsError(try manifest.frozen(at: "2026-09-08T00:00:00Z")) { error in
            XCTAssertEqual(error as? ASRBenchmarkManifestError, .unreviewedReference("ai"))
        }
    }

    func testAudioOnlyInputAcceptsMatchingBytesAndRejectsChangedAudio() throws {
        let root = try directory()
        let audio = Data([1, 2, 3])
        let url = root.appendingPathComponent("clip.wav")
        try audio.write(to: url)
        let input = try manifest(paths: ["clip.wav"], audio: audio)
        try input.validate(audioRoot: root)
        try Data([1, 2, 4]).write(to: url)
        XCTAssertThrowsError(try input.validate(audioRoot: root)) { error in
            XCTAssertEqual(error as? ASRInferenceManifestError, .audioChanged("clip-0"))
        }
    }

    func testRejectsDuplicateIDsAndUnsafePaths() throws {
        let root = try directory()
        for path in ["", "../clip.wav", "/tmp/clip.wav", "a//b.wav", "./clip.wav"] {
            XCTAssertThrowsError(try manifest(paths: [path]).validate(audioRoot: root))
        }
        try Data([1]).write(to: root.appendingPathComponent("clip.wav"))
        XCTAssertThrowsError(
            try manifest(paths: ["clip.wav", "clip.wav"], duplicateIDs: true).validate(
                audioRoot: root)
        )
    }

    func testRejectsSymlinkOutsideRoot() throws {
        let root = try directory()
        let outside = try directory().appendingPathComponent("clip.wav")
        try Data([1]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("clip.wav"), withDestinationURL: outside
        )
        XCTAssertThrowsError(try manifest(paths: ["clip.wav"]).validate(audioRoot: root))
    }

    func testRequiresSourceDigestAndNonemptyInput() throws {
        let root = try directory()
        XCTAssertThrowsError(try manifest(paths: []).validate(audioRoot: root))
        XCTAssertThrowsError(
            try manifest(paths: ["clip.wav"], sourceDigest: "unknown").validate(audioRoot: root)
        )
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func manifest(
        paths: [String], audio: Data = Data([1]), duplicateIDs: Bool = false,
        sourceDigest: String = String(repeating: "a", count: 64)
    ) throws -> ASRInferenceManifest {
        let digest = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "sourceManifestSHA256": sourceDigest,
            "items": paths.enumerated().map { i, path in
                ["id": "clip-\(duplicateIDs ? 0 : i)", "audioPath": path, "audioSHA256": digest]
            },
        ])
        return try JSONDecoder().decode(ASRInferenceManifest.self, from: data)
    }
}
