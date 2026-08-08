import Foundation
import ModelManagerKit
import XCTest

final class RuntimeModelManifestTests: XCTestCase {
    func testRepositoryManifestIsValid() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot =
            sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL =
            repositoryRoot
            .appendingPathComponent("Models/manifests/runtime-models.json")

        let manifest = try RuntimeModelManifest.loadAndValidate(from: manifestURL)

        XCTAssertEqual(manifest.models.map(\.role), [.asr, .polisher])
    }

    func testRejectsThirdRuntimeModel() {
        let manifest = RuntimeModelManifest(
            schemaVersion: 2,
            models: [validASR(), validPolisher(), validASR()]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? RuntimeModelManifestError, .invalidModelCount(3))
        }
    }

    func testRejectsUnauthorizedRepository() {
        let unauthorized = RuntimeModel(
            role: .asr,
            repository: "example/third-model",
            revision: String(repeating: "a", count: 40),
            license: "CC-BY-4.0",
            sourceURL: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            engine: .coreML,
            artifact: pendingArtifact(format: "mlpackage")
        )
        let manifest = RuntimeModelManifest(
            schemaVersion: 2,
            models: [unauthorized, validPolisher()]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? RuntimeModelManifestError,
                .unauthorizedRepository(role: .asr, repository: "example/third-model")
            )
        }
    }

    func testRejectsFloatingRevision() {
        let floatingASR = RuntimeModel(
            role: .asr,
            repository: "nvidia/parakeet-tdt-0.6b-v3",
            revision: "main",
            license: "CC-BY-4.0",
            sourceURL: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            engine: .coreML,
            artifact: pendingArtifact(format: "mlpackage")
        )
        let manifest = RuntimeModelManifest(
            schemaVersion: 2,
            models: [floatingASR, validPolisher()]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? RuntimeModelManifestError,
                .invalidRevision(role: .asr, revision: "main")
            )
        }
    }

    func testReadyArtifactRequiresChecksummedFiles() {
        let readyWithoutFiles = RuntimeModel(
            role: .asr,
            repository: "nvidia/parakeet-tdt-0.6b-v3",
            revision: String(repeating: "a", count: 40),
            license: "CC-BY-4.0",
            sourceURL: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            engine: .coreML,
            artifact: RuntimeModelArtifact(
                state: .ready,
                format: "mlpackage",
                provider: artifactProvider(for: .asr),
                files: []
            )
        )
        let manifest = RuntimeModelManifest(
            schemaVersion: 2,
            models: [readyWithoutFiles, validPolisher()]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? RuntimeModelManifestError,
                .readyArtifactHasNoFiles(.asr)
            )
        }
    }

    func testRejectsInvalidArtifactChecksum() {
        let invalidArtifact = RuntimeModelArtifact(
            state: .ready,
            format: "mlpackage",
            provider: artifactProvider(for: .asr),
            files: [RuntimeModelArtifactFile(path: "model.mlmodel", sha256: "invalid")]
        )
        let invalidASR = RuntimeModel(
            role: .asr,
            repository: "nvidia/parakeet-tdt-0.6b-v3",
            revision: String(repeating: "a", count: 40),
            license: "CC-BY-4.0",
            sourceURL: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            engine: .coreML,
            artifact: invalidArtifact
        )
        let manifest = RuntimeModelManifest(
            schemaVersion: 2,
            models: [invalidASR, validPolisher()]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? RuntimeModelManifestError,
                .invalidSHA256(role: .asr, path: "model.mlmodel")
            )
        }
    }

    func testReadyArtifactRequiresDownloadMetadata() {
        let artifact = RuntimeModelArtifact(
            state: .ready,
            format: "mlpackage",
            provider: artifactProvider(for: .asr),
            files: [
                RuntimeModelArtifactFile(
                    path: "model.mlmodel",
                    sha256: String(repeating: "a", count: 64)
                )
            ]
        )
        let model = RuntimeModel(
            role: .asr,
            repository: "nvidia/parakeet-tdt-0.6b-v3",
            revision: String(repeating: "a", count: 40),
            license: "CC-BY-4.0",
            sourceURL: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            engine: .coreML,
            artifact: artifact
        )

        XCTAssertThrowsError(
            try RuntimeModelManifest(schemaVersion: 2, models: [model, validPolisher()])
                .validate()
        ) { error in
            XCTAssertEqual(
                error as? RuntimeModelManifestError,
                .missingDownloadMetadata(role: .asr, path: "model.mlmodel")
            )
        }
    }

    func testRejectsArtifactPathTraversal() {
        let unsafeArtifact = RuntimeModelArtifact(
            state: .ready,
            format: "mlpackage",
            provider: artifactProvider(for: .asr),
            files: [
                RuntimeModelArtifactFile(
                    path: "../outside.mlmodel",
                    sha256: String(repeating: "a", count: 64)
                )
            ]
        )
        let unsafeASR = RuntimeModel(
            role: .asr,
            repository: "nvidia/parakeet-tdt-0.6b-v3",
            revision: String(repeating: "a", count: 40),
            license: "CC-BY-4.0",
            sourceURL: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            engine: .coreML,
            artifact: unsafeArtifact
        )
        let manifest = RuntimeModelManifest(
            schemaVersion: 2,
            models: [unsafeASR, validPolisher()]
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? RuntimeModelManifestError,
                .invalidArtifactPath(role: .asr, path: "../outside.mlmodel")
            )
        }
    }

    func testRejectsFloatingArtifactRevision() {
        let provider = RuntimeModelArtifactProvider(
            repository: "arhesstide/voxol-parakeet-tdt-0.6b-v3-coreml",
            revision: "main",
            sourceURL: "https://huggingface.co/arhesstide/voxol-parakeet-tdt-0.6b-v3-coreml"
        )
        let artifact = RuntimeModelArtifact(
            state: .ready,
            format: "mlpackage",
            provider: provider,
            files: [
                RuntimeModelArtifactFile(
                    path: "model.mlmodel",
                    sha256: String(repeating: "a", count: 64),
                    downloadURL:
                        "https://huggingface.co/arhesstide/voxol-parakeet-tdt-0.6b-v3-coreml/resolve/main/model.mlmodel?download=true",
                    sizeBytes: 1
                )
            ]
        )
        let model = RuntimeModel(
            role: .asr,
            repository: "nvidia/parakeet-tdt-0.6b-v3",
            revision: String(repeating: "a", count: 40),
            license: "CC-BY-4.0",
            sourceURL: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            engine: .coreML,
            artifact: artifact
        )

        XCTAssertThrowsError(
            try RuntimeModelManifest(schemaVersion: 2, models: [model, validPolisher()])
                .validate()
        ) { error in
            XCTAssertEqual(
                error as? RuntimeModelManifestError,
                .invalidArtifactRevision(role: .asr, revision: "main")
            )
        }
    }
}

private extension RuntimeModelManifestTests {
    func validASR() -> RuntimeModel {
        RuntimeModel(
            role: .asr,
            repository: "nvidia/parakeet-tdt-0.6b-v3",
            revision: String(repeating: "a", count: 40),
            license: "CC-BY-4.0",
            sourceURL: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            engine: .coreML,
            artifact: pendingArtifact(format: "mlpackage")
        )
    }

    func validPolisher() -> RuntimeModel {
        RuntimeModel(
            role: .polisher,
            repository: "Qwen/Qwen3.5-0.8B",
            revision: String(repeating: "b", count: 40),
            license: "Apache-2.0",
            sourceURL: "https://huggingface.co/Qwen/Qwen3.5-0.8B",
            engine: .mlx,
            artifact: pendingArtifact(format: "mlx-4bit-qwen3.5")
        )
    }

    func pendingArtifact(format: String) -> RuntimeModelArtifact {
        RuntimeModelArtifact(state: .pendingConversion, format: format, files: [])
    }

    func artifactProvider(for role: RuntimeModelRole) -> RuntimeModelArtifactProvider {
        switch role {
        case .asr:
            RuntimeModelArtifactProvider(
                repository: "arhesstide/voxol-parakeet-tdt-0.6b-v3-coreml",
                revision: String(repeating: "c", count: 40),
                sourceURL: "https://huggingface.co/arhesstide/voxol-parakeet-tdt-0.6b-v3-coreml"
            )
        case .polisher:
            RuntimeModelArtifactProvider(
                repository: "mlx-community/Qwen3.5-0.8B-4bit",
                revision: String(repeating: "d", count: 40),
                sourceURL: "https://huggingface.co/mlx-community/Qwen3.5-0.8B-4bit"
            )
        }
    }
}
