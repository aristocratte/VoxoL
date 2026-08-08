import Foundation

/// Rewrites spoken numbers as digits.
///
/// The recogniser emits what it hears: dictating "B450" produces
/// "B quatre cent cinquante", and "trente-deux giga" produces
/// "trente-deux giga". Nothing downstream turned those back into digits, so a
/// model number came out as prose in the middle of a technical sentence.
///
/// Deliberately deterministic rather than left to the language model. A model
/// number is exactly the kind of token a user notices instantly and cannot
/// tolerate being wrong, and a rule that always fires beats one that usually
/// does. It also runs on the fast path, where the polisher never executes.
///
/// The conversion is conservative in one specific way: French `un`/`une` and
/// English `a`/`an` are articles far more often than they are counts, so a lone
/// one is left alone. `un chipset` must not become `1 chipset`.
public enum SpokenNumberFormatter {
    /// Words worth less than one hundred, which accumulate additively.
    private static let frenchUnits: [String: Int] = [
        "zéro": 0, "zero": 0,
        "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5,
        "six": 6, "sept": 7, "huit": 8, "neuf": 9, "dix": 10, "onze": 11,
        "douze": 12, "treize": 13, "quatorze": 14, "quinze": 15, "seize": 16,
        "vingt": 20, "vingts": 20, "trente": 30, "quarante": 40,
        "cinquante": 50, "soixante": 60,
    ]

    private static let englishUnits: [String: Int] = [
        "zero": 0, "oh": 0,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Words that multiply what precedes them.
    private static let scales: [String: Int] = [
        "cent": 100, "cents": 100, "hundred": 100,
        "mille": 1_000, "milles": 1_000, "thousand": 1_000,
        "million": 1_000_000, "millions": 1_000_000,
        "milliard": 1_000_000_000, "milliards": 1_000_000_000,
        "billion": 1_000_000_000, "billions": 1_000_000_000,
    ]

    /// Joiners that may sit inside a spoken number without ending it.
    private static let connectors: Set<String> = ["et", "and"]

    /// Ordinals, which turn the number before them into something this does not
    /// know how to write. "twenty fourth" is not 20 followed by a word.
    private static let englishOrdinals: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh",
        "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth",
        "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth",
        "nineteenth", "twentieth", "thirtieth", "fortieth", "fiftieth",
        "sixtieth", "seventieth", "eightieth", "ninetieth", "hundredth",
        "thousandth",
    ]

    private static func isOrdinal(_ word: String, language: TextLanguage) -> Bool {
        switch language {
        case .english:
            return englishOrdinals.contains(word)
        case .french:
            // French ordinals are regular: deuxième, trentième, centième.
            return word.hasSuffix("ieme") || word == "premier" || word == "premiere"
        }
    }

    /// Above this, a spoken sequence is more plausibly several numbers read in
    /// a row — a phone number, a reference — than one quantity, and joining
    /// them would invent a value nobody said.
    private static let maximumValue = 999_999_999_999

    /// Rewrites every spoken number in `input` as digits.
    public static func applyingDigits(
        to input: String,
        language: TextLanguage
    ) -> String {
        let units = language == .french ? frenchUnits : englishUnits
        let pieces = tokenize(input)
        var output = ""
        var index = 0

        while index < pieces.count {
            let piece = pieces[index]
            guard piece.isWord else {
                output += piece.text
                index += 1
                continue
            }
            let (value, consumed, spelledOne) = number(
                startingAt: index,
                in: pieces,
                units: units,
                language: language
            )
            guard let value, consumed > 0, !spelledOne else {
                // A refused run is emitted whole. Restarting one word later
                // would re-parse its tail: "twenty twenty six" became
                // "twenty 26", which is worse than leaving it spoken.
                let span = max(consumed, 1)
                for offset in index..<min(index + span, pieces.count) {
                    output += pieces[offset].text
                }
                index += span
                continue
            }
            if let joined = joiningLetterPrefix(in: output) {
                // "B 450" is a chipset written wrong; "B450" is the part the
                // user asked for. Only mid-sentence, so an English sentence
                // opening with "A 5 star rating" keeps its space.
                output = joined
            }
            output += String(value)
            index += consumed
        }
        return output
    }

    /// Reads one spoken number starting at `start`.
    ///
    /// Returns the value, how many pieces it spans including the separators
    /// inside it, and whether the whole thing was a bare one — the caller
    /// leaves that as a word.
    private static func number(
        startingAt start: Int,
        in pieces: [Piece],
        units: [String: Int],
        language: TextLanguage
    ) -> (value: Int?, consumed: Int, spelledOne: Bool) {
        var total = 0
        var current = 0
        var matched = false
        var wordCount = 0
        var index = start
        var lastWordEnd = start
        var previousUnit: Int?

        while index < pieces.count {
            let piece = pieces[index]
            if !piece.isWord {
                // A separator only continues a number if a number word follows;
                // otherwise the number ended before it.
                if piece.isNumberSeparator, hasNumberWord(after: index, in: pieces, units: units) {
                    index += 1
                    continue
                }
                break
            }
            let word = piece.folded
            if connectors.contains(word) {
                if hasNumberWord(after: index, in: pieces, units: units) {
                    index += 1
                    continue
                }
                break
            }
            // "quatre-vingt" is four twenties, not four then twenty.
            if word == "quatre", isTwenty(after: index, in: pieces) {
                current += 80
                matched = true
                wordCount += 2
                index = skipToWord(after: index, in: pieces) + 1
                lastWordEnd = index
                continue
            }
            if isGroupPronoun(endingAt: index, in: pieces) {
                // "tous les trois" counts the speakers, not a quantity of
                // things: writing it "tous les 3" is wrong in a way a reader
                // notices immediately.
                return (nil, endOfRun(from: start, in: pieces, units: units) - start, false)
            }
            if isOrdinal(word, language: language) {
                // "twenty fourth" is an ordinal this cannot spell as digits;
                // converting only its first half would produce "20 fourth".
                return (nil, 0, false)
            }
            if let unit = units[word] {
                // A well-formed cardinal descends: vingt-trois, twenty three.
                // "twenty twenty six" does not, and it is a spoken year, not
                // 20 + 20 + 6. Refuse the whole run rather than invent 46.
                if let previous = previousUnit, unit >= previous, unit > 0 {
                    return (nil, endOfRun(from: start, in: pieces, units: units) - start, false)
                }
                previousUnit = unit
                current += unit
                matched = true
                wordCount += 1
                index += 1
                lastWordEnd = index
                continue
            }
            if let scale = scales[word] {
                if scale >= 1_000 {
                    total += max(current, 1) * scale
                    current = 0
                } else {
                    current = max(current, 1) * scale
                }
                previousUnit = nil
                matched = true
                wordCount += 1
                index += 1
                lastWordEnd = index
                continue
            }
            break
        }

        guard matched else { return (nil, 0, false) }
        let next = skipToWord(after: lastWordEnd - 1, in: pieces)
        if next < pieces.count, isOrdinal(pieces[next].folded, language: language) {
            return (nil, 0, false)
        }
        // A bare hyphen at either edge of the run means the number word is
        // half of a compound name, not a quantity: Trois-Rivières, Deux-Sèvres,
        // Sept-Îles. Interior hyphens of a real number were consumed by the
        // run itself, so a boundary hyphen always leads into a non-number word.
        if lastWordEnd < pieces.count, isBareHyphen(pieces[lastWordEnd]) {
            return (nil, 0, false)
        }
        if start > 0, isBareHyphen(pieces[start - 1]) {
            return (nil, 0, false)
        }
        let value = total + current
        guard value <= maximumValue else { return (nil, 0, false) }
        // A single word meaning one is almost always an article.
        let spelledOne = value == 1 && wordCount == 1
        return (value, lastWordEnd - start, spelledOne)
    }

    /// Drops the space in `… B 450` so a model number reads as one token.
    ///
    /// Returns nil unless `output` ends with a single capital letter followed by
    /// one space, and that letter is not opening a sentence — a capital at the
    /// start is ordinary prose, not a part number.
    private static func joiningLetterPrefix(in output: String) -> String? {
        guard output.hasSuffix(" ") else { return nil }
        let withoutSpace = String(output.dropLast())
        guard let letter = withoutSpace.last, letter.isLetter, letter.isUppercase
        else { return nil }
        let beforeLetter = withoutSpace.dropLast()
        guard let preceding = beforeLetter.last else { return nil }
        guard preceding == " " else { return nil }
        let earlier = beforeLetter.dropLast().trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let sentenceEnd = earlier.last else { return nil }
        guard !".!?:;".contains(sentenceEnd) else { return nil }
        return withoutSpace
    }

    /// True when the number completes `tous les …` or `toutes les …`.
    private static func isGroupPronoun(endingAt index: Int, in pieces: [Piece]) -> Bool {
        var words = [String]()
        var cursor = index - 1
        while cursor >= 0, words.count < 2 {
            if pieces[cursor].isWord { words.append(pieces[cursor].folded) }
            cursor -= 1
        }
        guard words.count == 2, words[0] == "les" else { return false }
        return words[1] == "tous" || words[1] == "toutes"
    }

    /// Index just past the last contiguous number word starting at `start`.
    private static func endOfRun(
        from start: Int,
        in pieces: [Piece],
        units: [String: Int]
    ) -> Int {
        var index = start
        var lastWordEnd = start
        while index < pieces.count {
            let piece = pieces[index]
            if !piece.isWord {
                guard piece.isNumberSeparator else { break }
                index += 1
                continue
            }
            let word = piece.folded
            guard units[word] != nil || scales[word] != nil || connectors.contains(word)
            else { break }
            index += 1
            lastWordEnd = index
        }
        return lastWordEnd
    }

    /// A separator that is only hyphens, with no spaces: the glue of a
    /// compound name rather than a pause between numbers.
    private static func isBareHyphen(_ piece: Piece) -> Bool {
        !piece.isWord && !piece.text.isEmpty
            && piece.text.allSatisfy { $0 == "-" || $0 == "\u{2011}" }
    }

    private static func isTwenty(after index: Int, in pieces: [Piece]) -> Bool {
        let next = skipToWord(after: index, in: pieces)
        guard next < pieces.count else { return false }
        return pieces[next].folded == "vingt" || pieces[next].folded == "vingts"
    }

    private static func skipToWord(after index: Int, in pieces: [Piece]) -> Int {
        var cursor = index + 1
        while cursor < pieces.count, !pieces[cursor].isWord {
            guard pieces[cursor].isNumberSeparator else { return pieces.count }
            cursor += 1
        }
        return cursor
    }

    private static func hasNumberWord(
        after index: Int,
        in pieces: [Piece],
        units: [String: Int]
    ) -> Bool {
        // A connector is transparent: "vingt et un" and "three hundred and
        // fifty thousand" are single numbers, and stopping at the joiner split
        // them into two.
        var cursor = index
        for _ in 0..<2 {
            let next = skipToWord(after: cursor, in: pieces)
            guard next < pieces.count else { return false }
            let word = pieces[next].folded
            if units[word] != nil || scales[word] != nil { return true }
            guard connectors.contains(word) else { return false }
            cursor = next
        }
        return false
    }

    // MARK: - Tokenising

    private struct Piece {
        let text: String
        let isWord: Bool
        let folded: String
        /// A space or hyphen, either of which can sit inside a spoken number.
        var isNumberSeparator: Bool {
            !isWord && text.allSatisfy { $0 == " " || $0 == "-" || $0 == "\u{2011}" }
        }
    }

    private static func tokenize(_ input: String) -> [Piece] {
        var pieces = [Piece]()
        var current = ""
        var currentIsWord: Bool?

        for character in input {
            let isWord = character.isLetter
            if currentIsWord == nil {
                currentIsWord = isWord
            }
            if isWord != currentIsWord {
                pieces.append(piece(current, isWord: currentIsWord ?? false))
                current = ""
                currentIsWord = isWord
            }
            current.append(character)
        }
        if !current.isEmpty {
            pieces.append(piece(current, isWord: currentIsWord ?? false))
        }
        return pieces
    }

    private static func piece(_ text: String, isWord: Bool) -> Piece {
        Piece(
            text: text,
            isWord: isWord,
            folded: isWord
                ? text.folding(options: [.diacriticInsensitive], locale: nil)
                    .lowercased()
                : text
        )
    }
}
