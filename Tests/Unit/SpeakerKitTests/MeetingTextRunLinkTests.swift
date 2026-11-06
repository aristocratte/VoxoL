import Foundation
import Testing
@testable import SpeakerKit

struct MeetingTextRunLinkTests {
    @Test(arguments: [
        "https://voxol.app", "http://voxol.app", "mailto:hello@voxol.app", "HTTPS://voxol.app",
    ])
    func webAndMailLinksBecomeLive(address: String) {
        #expect(MeetingTextRun("lien", link: address).safeURL != nil)
    }

    @Test(arguments: [
        "file:///etc/hosts", "voxol://open", "javascript:alert(1)",
        "x-apple.systempreferences:com.apple.preference.security", "pas un lien", "",
    ])
    func everyOtherLinkStaysText(address: String) {
        #expect(MeetingTextRun("lien", link: address).safeURL == nil)
    }

    @Test func aRunWithoutALinkHasNoURL() {
        #expect(MeetingTextRun("texte").safeURL == nil)
    }
}
