import Foundation

/// Words worth boosting in the decoder, read off the destination context.
///
/// The dictionary fixes the words the user has already taught; this covers the
/// ones on screen right now. Someone answering an email that says "Kubernetes"
/// is about to say "Kubernetes", and the recogniser's best guess for it —
/// absent help — is whatever French phrase sounds closest. The window title,
/// the selection and the text around the cursor are the cheapest honest
/// predictor of the next dictation's rare words.
///
/// Only notable tokens make the list: brands and code identifiers with inner
/// capitals or digits, and capitalised words long enough to be names. Common
/// lowercase words are exactly what the acoustic model already gets right, and
/// boosting them costs accuracy everywhere else — the trie tuning in
/// ParakeetCore was paid for in word-error points, so this list stays short
/// and rare.
public enum ContextVocabulary {
    /// More terms than this dilutes the boost and slows the trie for nothing:
    /// a screen rarely shows more distinct rare words worth saying.
    public static let defaultLimit = 20

    /// How much nearby text is scanned on each side of the cursor. Words
    /// further away than this are the document's past, not its present.
    static let cursorWindow = 240

    /// Extracts boost-worthy terms, most topical first, deduplicated
    /// case-insensitively, capped at `limit`.
    public static func terms(
        from snapshot: ContextSnapshot,
        limit: Int = defaultLimit
    ) -> [String] {
        // Title first: it names what the document is about. The selection is
        // what the user is acting on. Cursor surroundings come last — nearest
        // text, but also the noisiest.
        var sources: [String] = []
        if let windowTitle = snapshot.windowTitle {
            sources.append(windowTitle)
        }
        if let documentURL = snapshot.documentURL {
            sources.append(documentURL.deletingPathExtension().lastPathComponent)
        }
        sources.append(snapshot.selectedText)
        sources.append(String(snapshot.beforeCursor.suffix(cursorWindow)))
        sources.append(String(snapshot.afterCursor.prefix(cursorWindow)))

        var seen = Set<String>()
        var terms: [String] = []
        for source in sources {
            for token in tokens(in: source) where isNotable(token) {
                let key = token.lowercased()
                guard seen.insert(key).inserted else { continue }
                terms.append(token)
                if terms.count == limit {
                    return terms
                }
            }
        }
        return terms
    }

    static func tokens(in text: String) -> [String] {
        text.split { character in
            !character.isLetter && !character.isNumber
                && character != "'" && character != "-" && character != "_"
        }
        .map(String.init)
    }

    /// Whether a token is rare enough that boosting helps more than it hurts.
    static func isNotable(_ token: String) -> Bool {
        guard token.count >= 3 else {
            return false
        }
        let characters = Array(token)
        // Digits inside a word mark versions and models: B450, iPhone15.
        if characters.contains(where: \.isNumber), characters.contains(where: \.isLetter) {
            return true
        }
        // A capital after the first character marks brands and identifiers:
        // VoxoL, GitHub, camelCase. These are the recogniser's worst inputs
        // and the highest-value boosts.
        if characters.dropFirst().contains(where: \.isUppercase) {
            return true
        }
        // A leading capital alone is weaker evidence — every French sentence
        // starts with one — so it needs length to count as a probable name.
        if let first = characters.first, first.isUppercase, token.count >= 4,
            characters.dropFirst().allSatisfy({ !$0.isUppercase })
        {
            return true
        }
        return false
    }
}
