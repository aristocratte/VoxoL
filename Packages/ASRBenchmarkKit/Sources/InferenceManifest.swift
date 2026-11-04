// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
import CryptoKit
import Foundation

/// Audio-only input for diagnostic inference. It contains no reference labels
/// and grants no reviewed/frozen benchmark status to the resulting predictions.
public struct ASRInferenceManifest: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let id: String
        public let audioPath: String
        public let audioSHA256: String
    }

    public let schemaVersion: Int
    public let sourceManifestSHA256: String
    public let items: [Item]

    public func validate(audioRoot: URL) throws {
        guard schemaVersion == 1, Self.isDigest(sourceManifestSHA256), !items.isEmpty else {
            throw ASRInferenceManifestError.invalidManifest
        }
        let root = audioRoot.resolvingSymlinksInPath().standardizedFileURL.path
        var ids = Set<String>()
        for item in items {
            let components = item.audioPath.split(separator: "/", omittingEmptySubsequences: false)
            guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                ids.insert(item.id).inserted,
                Self.isDigest(item.audioSHA256),
                !item.audioPath.hasPrefix("/"), !item.audioPath.hasPrefix("~"),
                !components.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." })
            else { throw ASRInferenceManifestError.invalidItem(item.id) }
            let url = audioRoot.appendingPathComponent(item.audioPath)
                .resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root + "/") else {
                throw ASRInferenceManifestError.invalidItem(item.id)
            }
            let digest = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == item.audioSHA256 else {
                throw ASRInferenceManifestError.audioChanged(item.id)
            }
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

public enum ASRInferenceManifestError: Error, Equatable {
    case invalidManifest
    case invalidItem(String)
    case audioChanged(String)
}
