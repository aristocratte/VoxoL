import AppKit
import Foundation

/// Rich representations of the same text. Plain fields always receive the readable text.
public struct RichInsertionText: Equatable, Sendable {
    /// Text for controls that only support plain paste.
    public let plainText: String
    /// Native macOS attributed text representation.
    public let rtf: Data
    /// Escaped markup for rich web editors.
    public let html: Data
}

/// Converts explicitly requested bold into macOS pasteboard formats.
@MainActor
public enum FormattedInsertion {
    /// Keeps source editors and terminals on literal Markdown.
    public static func supportsRichText(bundleIdentifier: String?, developerProfile: Bool) -> Bool {
        guard !developerProfile else { return false }
        let bundle = bundleIdentifier?.lowercased() ?? ""
        let plainEditors = [
            "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.xcode",
            "com.sublimetext.", "com.jetbrains.", "com.apple.terminal", "com.googlecode.iterm2",
            "dev.zed.", "com.exafunction.windsurf", "com.mitchellh.ghostty",
        ]
        return !plainEditors.contains { bundle.hasPrefix($0) }
    }

    /// This deliberately handles only bold markers emitted by dictation commands.
    public static func boldText(from markdown: String) -> RichInsertionText? {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"```[\s\S]*?```|`[^`\n]+`|«[^»]*»|"[^"\n]+"|\*\*([^*\n]+)\*\*"#
            )
        else {
            return nil
        }
        let range = NSRange(markdown.startIndex..., in: markdown)
        let matches = regex.matches(in: markdown, range: range).filter {
            $0.range(at: 1).location != NSNotFound
        }
        guard !matches.isEmpty else { return nil }
        let source = markdown as NSString
        let attributed = NSMutableAttributedString(string: "")
        let regularFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let boldFont = NSFontManager.shared.convert(regularFont, toHaveTrait: .boldFontMask)
        var html = "<div style=\"white-space:pre-wrap\">"
        var cursor = 0
        for match in matches {
            let before = source.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor))
            let word = source.substring(with: match.range(at: 1))
            attributed.append(NSAttributedString(string: before, attributes: [.font: regularFont]))
            attributed.append(NSAttributedString(string: word, attributes: [.font: boldFont]))
            html += escapeHTML(before) + "<strong>" + escapeHTML(word) + "</strong>"
            cursor = NSMaxRange(match.range)
        }
        let after = source.substring(from: cursor)
        attributed.append(NSAttributedString(string: after, attributes: [.font: regularFont]))
        html += escapeHTML(after) + "</div>"
        guard
            let rtf = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
        else { return nil }
        return RichInsertionText(plainText: attributed.string, rtf: rtf, html: Data(html.utf8))
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
