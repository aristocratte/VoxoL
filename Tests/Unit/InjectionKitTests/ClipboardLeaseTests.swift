import AppKit
import InjectionKit
import XCTest

/// The destination reads the clipboard when it handles the paste, not when the keystroke is
/// posted, so a busy Electron window must still find the dictation there.
@MainActor
final class ClipboardLeaseTests: XCTestCase {
    private let hold: Duration = .milliseconds(120)

    private func board(holding text: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("VoxoL.tests.\(UUID())"))
        board.clearContents()
        board.setString(text, forType: .string)
        return board
    }

    private func borrow(_ lease: ClipboardLease, _ board: NSPasteboard, _ text: String) {
        XCTAssertTrue(lease.borrow { board.setString(text, forType: .string) })
    }

    func testDictationStaysAvailableUntilTheHoldEnds() async throws {
        let board = board(holding: "original")
        let lease = ClipboardLease(pasteboard: board, holdDuration: hold)
        borrow(lease, board, "dictée")
        lease.scheduleReturn()

        XCTAssertEqual(board.string(forType: .string), "dictée")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(board.string(forType: .string), "dictée")
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testASecondDictationNeverSavesTheFirstAsTheOriginal() async throws {
        let board = board(holding: "original")
        let lease = ClipboardLease(pasteboard: board, holdDuration: hold)
        borrow(lease, board, "première")
        lease.scheduleReturn()
        borrow(lease, board, "seconde")
        lease.scheduleReturn()

        XCTAssertEqual(board.string(forType: .string), "seconde")
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testAnOwnerCopyDuringTheHoldIsKept() async throws {
        let board = board(holding: "original")
        let lease = ClipboardLease(pasteboard: board, holdDuration: hold)
        borrow(lease, board, "dictée")
        lease.scheduleReturn()
        board.clearContents()
        board.setString("copié à la main", forType: .string)

        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(board.string(forType: .string), "copié à la main")

        borrow(lease, board, "suivante")
        lease.scheduleReturn()
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(board.string(forType: .string), "copié à la main")
    }

    func testAnUnconfirmedPasteLeavesTheDictationOnTheClipboard() async throws {
        let board = board(holding: "original")
        let lease = ClipboardLease(pasteboard: board, holdDuration: hold)
        borrow(lease, board, "dictée")
        lease.scheduleReturn()
        lease.keep()

        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(board.string(forType: .string), "dictée")
    }

    func testAFailedWriteGivesTheClipboardBack() {
        let board = board(holding: "original")
        let lease = ClipboardLease(pasteboard: board, holdDuration: hold)

        XCTAssertFalse(lease.borrow { false })
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testManualPasteCopyIsHiddenFromClipboardManagers() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("VoxoL.tests.\(UUID())"))
        defer { board.releaseGlobally() }

        try TextInjector(pasteboard: board).copyForManualPaste("dictée privée")

        XCTAssertEqual(board.string(forType: .string), "dictée privée")
        let types = board.pasteboardItems?.first?.types.map(\.rawValue) ?? []
        XCTAssertTrue(types.contains("org.nspasteboard.TransientType"))
        XCTAssertTrue(types.contains("org.nspasteboard.ConcealedType"))
    }

    func testPasteVerdictNeedsBothReadings() {
        XCTAssertNil(InsertionVerificationPolicy.pasteLanded(before: nil, after: "texte"))
        XCTAssertNil(InsertionVerificationPolicy.pasteLanded(before: "texte", after: nil))
        XCTAssertEqual(InsertionVerificationPolicy.pasteLanded(before: "a", after: "a b"), true)
        XCTAssertEqual(InsertionVerificationPolicy.pasteLanded(before: "a", after: "a"), false)
    }
}
