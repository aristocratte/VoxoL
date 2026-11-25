import Foundation
import ModelManagerKit
import XCTest

final class ModelInstallationFailureTests: XCTestCase {
    func testALostConnectionIsReportedAsOffline() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed,
        ]
        for code in codes {
            XCTAssertEqual(ModelInstallationFailure(networkError: URLError(code)), .offline)
        }
    }

    func testAnUnrelatedNetworkErrorIsNotBlamedOnTheConnection() {
        XCTAssertEqual(ModelInstallationFailure(networkError: URLError(.badURL)), .unavailable)
    }

    func testTheDiskMessageSaysHowMuchToFree() {
        let required: Int64 = 2_000_000_000
        let amount = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
        for french in [true, false] {
            let message = ModelInstallationFailure.insufficientDiskSpace(requiredBytes: required)
                .message(french: french)
            XCTAssertTrue(message.contains(amount), message)
        }
    }

    func testARefusalNamesTheStatusSoItCanBeReported() {
        let message = ModelInstallationFailure.serverRefused(statusCode: 429).message(french: false)
        XCTAssertTrue(message.contains("429"), message)
    }

    func testEveryFailureIsWrittenInBothLanguages() {
        let failures: [ModelInstallationFailure] = [
            .offline, .insufficientDiskSpace(requiredBytes: 1), .serverRefused(statusCode: 503),
            .damagedDownload, .unavailable,
        ]
        for failure in failures {
            let french = failure.message(french: true)
            let english = failure.message(french: false)
            XCTAssertFalse(french.isEmpty)
            XCTAssertFalse(english.isEmpty)
            XCTAssertNotEqual(french, english)
        }
    }
}
