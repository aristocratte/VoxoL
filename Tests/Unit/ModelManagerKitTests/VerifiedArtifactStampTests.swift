import Foundation
import ModelManagerKit
import XCTest

final class VerifiedArtifactStampTests: XCTestCase {
    private func directory(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxol-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (name, content) in files {
            try Data(content.utf8).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    func testAStampMatchesTheFilesItWasTakenFrom() throws {
        let root = try directory(["a.bin": "weights", "b.json": "{}"])
        let stamp = try VerifiedArtifactStamp(files: ["a.bin", "b.json"], in: root, digest: "d1")

        XCTAssertTrue(stamp.matches(files: ["a.bin", "b.json"], in: root, digest: "d1"))
    }

    func testAReplacedFileInvalidatesTheStamp() throws {
        let root = try directory(["a.bin": "weights"])
        let stamp = try VerifiedArtifactStamp(files: ["a.bin"], in: root, digest: "d1")
        let file = root.appendingPathComponent("a.bin")
        try FileManager.default.removeItem(at: file)
        try Data("weights".utf8).write(to: file)

        XCTAssertFalse(stamp.matches(files: ["a.bin"], in: root, digest: "d1"))
    }

    func testAMissingFileOrANewManifestInvalidatesTheStamp() throws {
        let root = try directory(["a.bin": "weights"])
        let stamp = try VerifiedArtifactStamp(files: ["a.bin"], in: root, digest: "d1")

        XCTAssertFalse(stamp.matches(files: ["a.bin"], in: root, digest: "d2"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.bin"))
        XCTAssertFalse(stamp.matches(files: ["a.bin"], in: root, digest: "d1"))
    }

    func testAStampSurvivesBeingWrittenAndReadBack() throws {
        let root = try directory(["a.bin": "weights"])
        let stamp = try VerifiedArtifactStamp(files: ["a.bin"], in: root, digest: "d1")
        let url = root.appendingPathComponent(".verified.json")
        try stamp.write(to: url)

        let reloaded = try XCTUnwrap(VerifiedArtifactStamp.read(from: url))
        XCTAssertTrue(reloaded.matches(files: ["a.bin"], in: root, digest: "d1"))
    }
}
