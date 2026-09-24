import Foundation

/// Bounded dictation commands. Descriptions of commands and ambiguous targets stay literal.
public enum SpokenFormatting {
    /// Converted text and the explicit formatting intent carried to insertion.
    public struct Result: Equatable, Sendable {
        /// Text after recognized commands, with bold represented as Markdown.
        public let text: String
        /// Whether at least one unambiguous command was applied.
        public let applied: Bool
        /// Whether an applied command requested bold text.
        public let hasBold: Bool
    }

    /// Applies supported commands while preserving quoted, ambiguous and unknown wording.
    public static func apply(to input: String, language: TextLanguage) -> Result {
        var text = input
        var literals: [String] = []
        // Never interpret commands in quoted speech or code. Restore literal Markdown too.
        let literalPattern = #"```[\s\S]*?```|`[^`\n]+`|«[^»]*»|"[^"\n]+"|\*\*[^*\n]+\*\*"#
        text = replacing(literalPattern, in: text) { match, source in
            literals.append((source as NSString).substring(with: match.range))
            return "\u{E000}\(literals.count - 1)\u{E001}"
        }
        var applied = false
        var hasBold = false
        let french = language == .french

        // A named target must already occur exactly once in this dictation. No screen edits.
        let targetPattern =
            french
            ? #"(?iu)[.!,; ]*\bmets?\s+le\s+mot\s+([\p{L}\p{N}'’\-]+)\s+(en gras|entre parenthèses)[.! ]*$"#
            : #"(?iu)[.!,; ]*\bput\s+the\s+word\s+([\p{L}\p{N}'’\-]+)\s+(in bold|in parentheses)[.! ]*$"#
        if let expression = try? RegularExpressionCache.shared.expression(pattern: targetPattern),
            let command = expression.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text))
        {
            let source = text as NSString
            let word = source.substring(with: command.range(at: 1))
            let style = source.substring(with: command.range(at: 2)).lowercased()
            let prefix = source.substring(to: command.range.location)
            let matches =
                (try? RegularExpressionCache.shared.expression(
                    pattern:
                        "(?iu)(?<![\\p{L}\\p{N}_])\(NSRegularExpression.escapedPattern(for: word))(?![\\p{L}\\p{N}_])"
                ))?.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) ?? []
            if matches.count == 1, let target = matches.first {
                let original = (prefix as NSString).substring(with: target.range)
                let bold = style.contains("gras") || style.contains("bold")
                let replacement = bold ? "**\(original)**" : "(\(original))"
                let separator = source.substring(with: command.range).prefix {
                    ".!,; ".contains($0)
                }
                .trimmingCharacters(in: .whitespaces)
                text =
                    (prefix as NSString).replacingCharacters(in: target.range, with: replacement)
                    + separator
                applied = true
                hasBold = bold
            }
        }

        let pairs: [(String, String, String, Bool)] =
            french
            ? [
                (
                    #"(?:ouvre|ouvrez) (?:la |une )?parenthèse"#,
                    #"(?:ferme|fermez) (?:la |une )?parenthèse"#, "parentheses", false
                ),
                (#"début (?:du |de )?gras"#, #"fin (?:du |de )?gras"#, "bold", true),
            ]
            : [
                (#"open parenthesis"#, #"close parenthesis"#, "parentheses", false),
                (#"(?:start|begin) bold"#, #"end bold"#, "bold", true),
            ]
        for (open, close, _, bold) in pairs {
            let pattern = "(?iu)\\b\(open)\\s*[,.:]?\\s+([^\\n]{1,240}?)\\s*[,.:]?\\s+\(close)\\b"
            text = replacing(pattern, in: text) { match, source in
                guard !isMention(before: match.range.location, in: source) else { return nil }
                let body = (source as NSString).substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.contains("\u{E000}") else { return nil }
                guard
                    body.range(of: "(?iu)\\b(?:\(open)|\(close))\\b", options: .regularExpression)
                        == nil
                else {
                    return nil
                }
                applied = true
                hasBold = hasBold || bold
                return bold ? "**\(body)**" : "(\(body))"
            }
        }

        let commands: [(String, String)] =
            french
            ? [
                (#"nouveau paragraphe"#, "\n\n"), (#"(?:à la ligne|nouvelle ligne)"#, "\n"),
                (#"point d['’]interrogation"#, " ?"), (#"point d['’]exclamation"#, " !"),
                (#"point final"#, "."),
                (#"(?:ajoute|mets|insère) une virgule"#, ","),
                (#"(?:ajoute|mets|insère) (?:un )?point-virgule"#, " ;"),
                (#"(?:ajoute|mets|insère) (?:les )?deux[ -]points"#, " :"),
            ]
            : [
                (#"new paragraph"#, "\n\n"), (#"new line"#, "\n"),
                (#"question mark"#, "?"), (#"exclamation (?:mark|point)"#, "!"),
                (#"full stop"#, "."),
                (#"(?:add|insert) (?:a )?comma"#, ","),
                (#"(?:add|insert) (?:a )?semicolon"#, ";"),
                (#"(?:add|insert) (?:a )?colon"#, ":"),
            ]
        for (phrase, replacement) in commands {
            let prefix =
                french
                ? #"(?:(?:ajoute|mets|insère) (?:un |une )?)?"#
                : #"(?:(?:add|insert) (?:a |an )?)?"#
            text = replacing("(?iu)\\b\(prefix)\(phrase)\\b[.,!?]?", in: text) { match, source in
                guard !isMention(before: match.range.location, in: source) else { return nil }
                applied = true
                return replacement
            }
        }
        let emojis: [(String, String)] =
            french
            ? [
                ("cœur rouge|coeur rouge|cœur|coeur", "❤️"),
                ("pouce (?:en l’air|en l'air|levé)", "👍"), ("sourire|souriant", "🙂"),
                ("clin d['’]œil", "😉"),
            ]
            : [("red heart|heart", "❤️"), ("thumbs up", "👍"), ("smile|smiling", "🙂"), ("wink", "😉")]
        for (name, symbol) in emojis {
            let pattern =
                french
                ? "(?iu)\\b(?:ajoute(?:z)? un [ée]moji|[ée]moji) (?:\(name))\\b"
                : "(?iu)\\b(?:add (?:a |an )?)?(?:\(name)) emoji\\b"
            text = replacing(pattern, in: text) { match, source in
                guard !isMention(before: match.range.location, in: source) else { return nil }
                applied = true
                return symbol
            }
        }
        if applied {
            text = text.replacingOccurrences(
                of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(
                of: #" +([,.])"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(
                of: #"[.,] *(?=[?!])"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\.{2,}"#, with: ".", options: .regularExpression)
            text = text.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (index, literal) in literals.enumerated() {
            text = text.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: literal)
        }
        return Result(text: text, applied: applied, hasBold: hasBold)
    }

    private static func isMention(before offset: Int, in source: String) -> Bool {
        let prefix = (source as NSString).substring(to: offset)
        // Articles and metalinguistic verbs make this a description, not a command.
        let pattern =
            #"(?iu)\b(?:un|une|le|la|les|des|du|de|ce|cet|cette|a|an|the|this|that|dit|dis|dire|écrit|écrire|commande|expression|say|says|said|write|called)[\s,.:;]*$"#
        return prefix.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replacing(
        _ pattern: String, in input: String,
        transform: (NSTextCheckingResult, String) -> String?
    ) -> String {
        guard let regex = try? RegularExpressionCache.shared.expression(pattern: pattern) else {
            return input
        }
        var result = input
        for match in regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
            .reversed()
        {
            if let replacement = transform(match, input), let range = Range(match.range, in: result)
            {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }
}
