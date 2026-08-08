import XCTest

@testable import ContextKit

final class ContextKitTests: XCTestCase {
    func testContextWindowIsBoundedAroundSelection() {
        let text =
            String(repeating: "a", count: 700) + "SELECT" + String(repeating: "b", count: 500)
        let start = text.index(text.startIndex, offsetBy: 700)
        let end = text.index(start, offsetBy: 6)

        let result = ContextWindow.project(text: text, selection: start..<end)

        XCTAssertEqual(result.selected, "SELECT")
        XCTAssertEqual(result.before.count, 500)
        XCTAssertEqual(result.after.count, 300)
    }

    func testSecureTextFieldPolicyBlocksEitherRoleOrSubrole() {
        XCTAssertTrue(ContextSecurityPolicy.isSecure(role: "AXSecureTextField", subrole: nil))
        XCTAssertTrue(
            ContextSecurityPolicy.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertFalse(ContextSecurityPolicy.isSecure(role: "AXTextArea", subrole: nil))
    }
}
