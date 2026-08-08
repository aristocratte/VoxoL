import Foundation
import XCTest

@testable import AppCoreKit

final class UpdateCheckTests: XCTestCase {
    private func release(_ version: String) -> UpdateCheck.Release {
        UpdateCheck.Release(
            version: version,
            url: URL(string: "https://example.invalid/\(version)")!
        )
    }

    func testVersionsCompareNumericallyNotAlphabetically() {
        // The bug this exists to prevent: "0.10.0" < "0.9.0" as strings, so a
        // lexical comparison would strand every user on 0.9 forever.
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.9.0", than: "0.10.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.0", than: "0.99.99"))
    }

    func testAnIdenticalVersionIsNotAnUpdate() {
        XCTAssertFalse(UpdateCheck.isNewer("1.2.3", than: "1.2.3"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertFalse(UpdateCheck.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.2.0", than: "1.2"))
        XCTAssertTrue(UpdateCheck.isNewer("1.2.1", than: "1.2"))
    }

    func testTagPrefixIsIgnored() {
        XCTAssertTrue(UpdateCheck.isNewer("v1.1.0", than: "1.0.0"))
        XCTAssertFalse(UpdateCheck.isNewer("v1.0.0", than: "v1.0.0"))
    }

    func testAPreReleaseNeverOutranksItsRelease() {
        // Offering 1.3.0-beta.1 to someone on 1.3.0 would be a downgrade
        // wearing a higher number.
        XCTAssertFalse(UpdateCheck.isNewer("1.3.0-beta.1", than: "1.3.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.3.0-beta.1", than: "1.2.0"))
    }

    func testAMalformedTagDoesNotBreakTheCheck() {
        XCTAssertFalse(UpdateCheck.isNewer("not-a-version", than: "1.0.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.0", than: "garbage"))
    }

    func testTheNewestAvailableReleaseIsOffered() {
        let offered = UpdateCheck.availableUpdate(
            current: "0.1.0",
            releases: [release("0.1.0"), release("0.3.0"), release("0.2.0")]
        )

        XCTAssertEqual(offered?.version, "0.3.0")
    }

    func testNothingIsOfferedWhenTheBuildIsCurrent() {
        XCTAssertNil(
            UpdateCheck.availableUpdate(
                current: "1.0.0",
                releases: [release("1.0.0"), release("0.9.0")]
            )
        )
        XCTAssertNil(UpdateCheck.availableUpdate(current: "1.0.0", releases: []))
    }

    func testDraftsAndPreReleasesAreSkipped() throws {
        let payload = """
            [
              {"tag_name": "v0.4.0", "html_url": "https://example.invalid/4", \
            "draft": true, "prerelease": false},
              {"tag_name": "v0.3.0", "html_url": "https://example.invalid/3", \
            "draft": false, "prerelease": true},
              {"tag_name": "v0.2.0", "html_url": "https://example.invalid/2", \
            "draft": false, "prerelease": false}
            ]
            """.data(using: .utf8)!

        let releases = try UpdateCheck.releases(fromGitHubJSON: payload)

        XCTAssertEqual(releases.map(\.version), ["0.2.0"])
    }

    func testAnEntryWithoutAUsableURLIsSkipped() throws {
        let payload = """
            [
              {"tag_name": "v0.5.0"},
              {"html_url": "https://example.invalid/x"},
              {"tag_name": "v0.4.0", "html_url": "https://example.invalid/4"}
            ]
            """.data(using: .utf8)!

        let releases = try UpdateCheck.releases(fromGitHubJSON: payload)

        XCTAssertEqual(releases.map(\.version), ["0.4.0"])
    }

    func testUnexpectedPayloadShapeYieldsNoReleases() throws {
        let payload = #"{"message":"Not Found"}"#.data(using: .utf8)!

        XCTAssertEqual(try UpdateCheck.releases(fromGitHubJSON: payload).count, 0)
    }
}
