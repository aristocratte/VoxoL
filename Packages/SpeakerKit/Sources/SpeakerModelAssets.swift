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
    ///
    /// `progress` receives the fraction of `downloadBytes` on disk so far: a 200 MB wait with
    /// nothing moving read as a hang.
    public static func install(
        directory: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let fm = FileManager.default
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.path)
            if (try? valid(file, at: destination)) == true {
                completed += file.size
                progress(Double(completed) / Double(downloadBytes))
                continue
            }
            guard
                let url = URL(
                    string:
                        "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.remotePath)"
                )
            else { throw SpeakerError.modelIntegrity }
            let base = completed
            let (temporary, response) = try await ProgressDownload.fetch(url) { written in
                progress(Double(base + written) / Double(downloadBytes))
            }
            defer { try? fm.removeItem(at: temporary) }
            try Task.checkCancellation()
            // A refusal is the server's, not a damaged model: say which.
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            guard try valid(file, at: temporary) else { throw SpeakerError.modelIntegrity }
            completed += file.size
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

/// A download that reports bytes as they arrive; `URLSession.download(from:)` says nothing
/// until it is done.
private final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onBytes: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), any Error>?
    private var result: (URL, URLResponse)?

    private init(onBytes: @escaping @Sendable (Int64) -> Void) {
        self.onBytes = onBytes
    }

    static func fetch(
        _ url: URL, onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = ProgressDownload(onBytes: onBytes)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64
    ) {
        onBytes(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The system deletes `location` when this returns, so it is moved now.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxol-speaker-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            if let response = downloadTask.response {
                lock.withLock { result = (kept, response) }
            }
        } catch {
            lock.withLock {
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        lock.withLock {
            guard let continuation else { return }
            if let error {
                continuation.resume(throwing: error)
            } else if let result {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: URLError(.badServerResponse))
            }
            self.continuation = nil
        }
    }
}
