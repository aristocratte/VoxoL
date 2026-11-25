import Foundation

/// What an installed model's files looked like when their checksums last passed.
///
/// Every launch used to hash all 1.3 GB of model files before dictation could start. A file
/// that has not been replaced keeps its size, inode and modification date, so when those still
/// match the last successful verification the hashing is skipped. Anything else — a replaced or
/// missing file, a new manifest — falls back to the full check.
public struct VerifiedArtifactStamp: Codable, Equatable, Sendable {
    struct FileStamp: Codable, Equatable, Sendable {
        let path: String
        let size: UInt64
        let inode: UInt64
        let modified: Double
    }

    let digest: String
    let files: [FileStamp]

    /// Records the current state of `files`, which have just passed verification.
    public init(files: [String], in directory: URL, digest: String) throws {
        self.digest = digest
        self.files = try files.map { try Self.stamp($0, in: directory) }
    }

    /// Whether the files are still exactly the ones that were verified for `digest`.
    public func matches(files paths: [String], in directory: URL, digest: String) -> Bool {
        guard digest == self.digest,
            let current = try? paths.map({ try Self.stamp($0, in: directory) })
        else { return false }
        return current == files
    }

    /// Saves the stamp beside the installed models.
    public func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// Reads a saved stamp, or nil when there is none or it cannot be decoded.
    public static func read(from url: URL) -> VerifiedArtifactStamp? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VerifiedArtifactStamp.self, from: data)
    }

    private static func stamp(_ path: String, in directory: URL) throws -> FileStamp {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(path).path)
        guard let size = attributes[.size] as? NSNumber,
            let inode = attributes[.systemFileNumber] as? NSNumber,
            let modified = attributes[.modificationDate] as? Date
        else { throw CocoaError(.fileReadUnknown) }
        return FileStamp(
            path: path, size: size.uint64Value, inode: inode.uint64Value,
            modified: modified.timeIntervalSinceReferenceDate)
    }
}
