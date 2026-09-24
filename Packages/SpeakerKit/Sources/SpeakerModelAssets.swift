import CryptoKit
import Foundation

/// The optional speaker model is pinned independently of the two dictation models.
public enum SpeakerModelAssets {
    /// Pinned public GA Core ML conversion commit.
    public static let revision = "53445f72d5735e33406ccce7b92116bce7ab1ab7"
    /// Public repository containing the converted weights.
    public static let repository = "FluidInference/nemotron-3-diarization-coreml"
    /// Total size of the pinned artifact files.
    public static let downloadBytes: Int64 = files.reduce(0) { $0 + $1.size }

    private struct Artifact: Sendable {
        let path: String
        let remotePath: String
        let sha256: String
        let size: Int64
    }
    private static let files: [Artifact] = [
        .init(
            path: "learnable_sil_emb.bin", remotePath: "learnable_sil_emb.bin",
            sha256: "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7", size: 2048),
        .init(
            path: "Nemotron3Diarizer_fast32.mlmodelc/analytics/coremldata.bin",
            remotePath: "monolithic/Nemotron3Diarizer_fast32.mlmodelc/analytics/coremldata.bin",
            sha256: "2d9c967cf11244a6c84c09e01ed16ce8f896ae39ebb39f1fa631d0b24c4eeb12", size: 243),
        .init(
            path: "Nemotron3Diarizer_fast32.mlmodelc/coremldata.bin",
            remotePath: "monolithic/Nemotron3Diarizer_fast32.mlmodelc/coremldata.bin",
            sha256: "45119a94c77281b66ce12f529f899004268dde2923844f793a2d7909c2b2d0ae", size: 752),
        .init(
            path: "Nemotron3Diarizer_fast32.mlmodelc/model.mil",
            remotePath: "monolithic/Nemotron3Diarizer_fast32.mlmodelc/model.mil",
            sha256: "f168bcf89471082bcfc566374b89c5d28882e78facb36a382b6371713bd281de", size: 504272
        ),
        .init(
            path: "Nemotron3Diarizer_fast32.mlmodelc/weights/weight.bin",
            remotePath: "monolithic/Nemotron3Diarizer_fast32.mlmodelc/weights/weight.bin",
            sha256: "7353d8e7a5d29a8d15edf86dbf40bed4e82b7b8f456f302d5cdcbf850ed25358",
            size: 198566016),
    ]

    /// Checks every required file against its pinned size and SHA-256.
    public static func verify(directory: URL) throws {
        for file in files {
            try Task.checkCancellation()
            guard try valid(file, at: directory.appendingPathComponent(file.path)) else {
                throw SpeakerError.modelIntegrity
            }
        }
    }

    /// Network access is limited to these immutable public model assets. Audio stays local.
    public static func install(directory: URL) async throws {
        let fm = FileManager.default
        for file in files {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.path)
            if (try? valid(file, at: destination)) == true { continue }
            guard
                let url = URL(
                    string:
                        "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.remotePath)"
                )
            else { throw SpeakerError.modelIntegrity }
            let (temporary, response) = try await URLSession.shared.download(from: url)
            defer { try? fm.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                try valid(file, at: temporary)
            else { throw SpeakerError.modelIntegrity }
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
        }
        try verify(directory: directory)
    }

    private static func valid(_ artifact: Artifact, at url: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
            (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                == artifact.size
        else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == artifact.sha256
    }
}
