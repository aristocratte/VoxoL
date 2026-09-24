import AppKit
import InjectionKit
import XCTest

final class FormattedInsertionTests: XCTestCase {
    @MainActor
    func testRichClipboardPastesBoldIntoNativeTextView() throws {
        let content = try XCTUnwrap(
            FormattedInsertion.boldText(from: "Bonjour **Élodie** ❤️\nÀ demain"))
        let board = NSPasteboard(name: NSPasteboard.Name("VoxoL.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        try TextInjector(pasteboard: board).copyForManualPaste(content.plainText, richText: content)
        XCTAssertEqual(board.string(forType: .string), "Bonjour Élodie ❤️\nÀ demain")
        let view = NSTextView()
        view.isRichText = true
        XCTAssertTrue(view.readSelection(from: board, type: .rtf))
        XCTAssertEqual(view.string, content.plainText)
        let storage = try XCTUnwrap(view.textStorage)
        let location = (view.string as NSString).range(of: "Élodie").location
        let font = try XCTUnwrap(
            storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let regular = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: regular).contains(.boldFontMask))
    }

    @MainActor
    func testHTMLTextIsEscapedAndPlainClipboardContainsNoMarkers() throws {
        let content = try XCTUnwrap(FormattedInsertion.boldText(from: "<note> **A & B**"))
        let html = try XCTUnwrap(String(data: content.html, encoding: .utf8))
        XCTAssertTrue(html.contains("&lt;note&gt; <strong>A &amp; B</strong>"))
        XCTAssertEqual(content.plainText, "<note> A & B")
    }

    @MainActor
    func testCodeEditorsKeepMarkdownAndOtherAppsReceiveRichFormats() {
        for bundle in [
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
            "com.apple.Terminal",
        ] {
            XCTAssertFalse(
                FormattedInsertion.supportsRichText(
                    bundleIdentifier: bundle, developerProfile: false))
        }
        XCTAssertTrue(
            FormattedInsertion.supportsRichText(
                bundleIdentifier: "com.apple.Notes", developerProfile: false))
        XCTAssertFalse(
            FormattedInsertion.supportsRichText(bundleIdentifier: nil, developerProfile: true))
        XCTAssertNil(FormattedInsertion.boldText(from: "Un texte sans gras"))
    }
}
