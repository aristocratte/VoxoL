import Foundation

/// Compares the running build against the latest published release.
///
/// Without this, a shipped bug is permanent on every machine that already
/// installed the app: there is no channel to tell anyone a fix exists. Sparkle
/// eventually does the downloading and installing, but it needs an EdDSA key
/// the maintainer holds and a hosted appcast; the comparison itself does not,
/// and it is the part that decides whether a user is told anything at all.
///
/// Deliberately inert by default: it reports, it does not fetch or install.
public enum UpdateCheck {
    /// A release as published by the update feed.
    public struct Release: Sendable, Equatable {
        /// Version string such as `0.2.0`, with any leading `v` removed.
        public let version: String
        /// Page a user opens to download it.
        public let url: URL

        /// Creates a release, stripping any leading `v` from the tag.
        public init(version: String, url: URL) {
            self.version = Self.normalized(version)
            self.url = url
        }

        static func normalized(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        }
    }

    /// Ordered comparison of two dotted version strings.
    ///
    /// Compares numerically per component rather than lexically, because `0.10`
    /// is newer than `0.9` and a string comparison says the opposite. Missing
    /// components count as zero so `1.2` and `1.2.0` are the same release.
    /// Non-numeric components sort as zero rather than crashing a user's update
    /// check on a malformed tag.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(of: candidate)
        let right = components(of: current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(of version: String) -> [Int] {
        Release.normalized(version)
            // Drop any pre-release or build suffix: `1.2.0-beta.1` compares as
            // `1.2.0`, so a beta never presents itself as newer than the
            // release it precedes.
            .split(separator: "-", maxSplits: 1).first
            .map(String.init)?
            .split(separator: ".")
            .map { Int($0) ?? 0 } ?? []
    }

    /// The release worth offering, or nil when the running build is current.
    public static func availableUpdate(
        current: String,
        releases: [Release]
    ) -> Release? {
        releases
            .filter { isNewer($0.version, than: current) }
            .max { isNewer($1.version, than: $0.version) }
    }

    /// Parses the GitHub releases API payload.
    ///
    /// Drafts and pre-releases are skipped: someone running the shipped build
    /// should not be pushed onto an unfinished one.
    public static func releases(fromGitHubJSON data: Data) throws -> [Release] {
        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return payload.compactMap { entry in
            guard
                (entry["draft"] as? Bool) != true,
                (entry["prerelease"] as? Bool) != true,
                let tag = entry["tag_name"] as? String,
                let link = entry["html_url"] as? String,
                let url = URL(string: link)
            else {
                return nil
            }
            return Release(version: tag, url: url)
        }
    }
}
