import Foundation

/// Where the app looks for newer releases.
///
/// GitHub's release list rather than a Sparkle appcast: the appcast needs an
/// EdDSA key the maintainer holds and a hosted feed, while this works the day
/// the first release is tagged. Swapping in Sparkle later replaces the
/// transport, not the version comparison.
enum UpdateFeed {
    static let releasesURL = "https://api.github.com/repos/aristocratte/VoxoL/releases"
}
