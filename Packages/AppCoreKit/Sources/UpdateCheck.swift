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
    /// Failures that must not be presented as a successful check with no update.
    public enum FeedError: Error, Equatable, Sendable {
        case invalidResponse
        case httpStatus(Int)
        case unexpectedPayload
    }

    /// Both settings and the sidebar present the result of the same check.
    public struct State: Equatable, Sendable {
        /// User-visible progress and outcome of the most recent check.
        public enum Phase: Equatable, Sendable {
            case idle, checking, current, available, failed
        }

        /// The current operation or the outcome of the most recent one.
        public private(set) var phase: Phase = .idle
        /// The last verified update, retained if a subsequent check fails.
        public private(set) var available: Release?

        /// Starts without claiming the installed version has been checked.
        public init() {}

        /// Coalesces a manual check with one already running at launch.
        @discardableResult
        public mutating func begin() -> Bool {
            guard phase != .checking else { return false }
            phase = .checking
            return true
        }

        /// Records a successfully retrieved and parsed release feed.
        public mutating func finish(current: String, releases: [Release]) {
            available = UpdateCheck.availableUpdate(current: current, releases: releases)
            phase = available == nil ? .current : .available
        }

        /// Records an unsuccessful check while preserving a previously discovered update.
        public mutating func fail() {
            // A connection failure cannot revoke a previously discovered update.
            phase = .failed
        }
    }

    /// A release as published by the update feed.
    public struct Release: Sendable, Equatable {
        /// Version string such as `0.2.0`, with any leading `v` removed.
        public let version: String
        /// Page a user opens to download it.
        public let url: URL
        /// Direct link to the installable disk image, when the release has
        /// one. The built-in installer needs the file, not the page: sending
        /// someone to a web page to update an app they are already inside is
        /// the browser's job leaking into the product.
        public let diskImageURL: URL?

        /// Creates a release, stripping any leading `v` from the tag.
        public init(version: String, url: URL, diskImageURL: URL? = nil) {
            self.version = Self.normalized(version)
            self.url = url
            self.diskImageURL = diskImageURL
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
    public static func releases(fromGitHubJSON data: Data, statusCode: Int = 200) throws
        -> [Release]
    {
        guard (200..<300).contains(statusCode) else {
            throw FeedError.httpStatus(statusCode)
        }
        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw FeedError.unexpectedPayload
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
            let diskImage = (entry["assets"] as? [[String: Any]])?
                .compactMap { asset -> URL? in
                    guard
                        let name = asset["name"] as? String,
                        name.lowercased().hasSuffix(".dmg"),
                        let link = asset["browser_download_url"] as? String
                    else {
                        return nil
                    }
                    return URL(string: link)
                }
                .first
            return Release(version: tag, url: url, diskImageURL: diskImage)
        }
    }
}
