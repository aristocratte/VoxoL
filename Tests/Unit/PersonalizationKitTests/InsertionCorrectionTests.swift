import XCTest

@testable import PersonalizationKit

/// Most of these assert that nothing is learned. That is the point: reading
/// another app's text field is easy, and the whole difficulty is refusing to
/// treat ordinary typing as a correction.
final class InsertionCorrectionTests: XCTestCase {
    func testCorrectingAWordInPlaceIsRecovered() {
        let corrected = InsertionCorrection.correctedText(
            inserted: "le chip set gère le slot",
            baseline: "Note : le chip set gère le slot",
            current: "Note : le chipset gère le slot"
        )

        XCTAssertEqual(corrected, "le chipset gère le slot")
    }

    func testContinuingToDictateIsNotACorrection() {
        // The most common way this goes wrong: the field changed, it still
        // starts with what was written, and none of it is a repair.
        let corrected = InsertionCorrection.correctedText(
            inserted: "le chip set gère le slot",
            baseline: "le chip set gère le slot",
            current: "le chip set gère le slot et la carte graphique occupe le second"
        )

        XCTAssertNil(corrected)
    }

    func testRewritingTheSentenceEntirelyIsNotACorrection() {
        let corrected = InsertionCorrection.correctedText(
            inserted: "le chip set gère le slot",
            baseline: "le chip set gère le slot",
            current: "finalement je vais parler d'autre chose"
        )

        XCTAssertNil(corrected)
    }

    func testAnEditBeforeTheDictatedTextIsIgnored() {
        // The prefix moved, so nothing can be attributed to what VoxoL wrote.
        let corrected = InsertionCorrection.correctedText(
            inserted: "le chip set gère le slot",
            baseline: "Note : le chip set gère le slot",
            current: "Remarque : le chip set gère le slot"
        )

        XCTAssertNil(corrected)
    }

    func testAnUntouchedFieldYieldsNothing() {
        let corrected = InsertionCorrection.correctedText(
            inserted: "le chip set gère le slot",
            baseline: "le chip set gère le slot",
            current: "le chip set gère le slot"
        )

        XCTAssertNil(corrected)
    }

    func testTextTypedAfterTheDictationDoesNotHideTheCorrection() {
        // Realistic sequence: fix the word, then keep writing. The trailing
        // text is new, so the guard has to tolerate a little growth without
        // tolerating a whole new sentence.
        let corrected = InsertionCorrection.correctedText(
            inserted: "le chip set gère le slot",
            baseline: "le chip set gère le slot",
            current: "le chipset gère le slot."
        )

        XCTAssertEqual(corrected, "le chipset gère le slot.")
    }
}
