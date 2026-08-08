// Adapted for VoxoL from parakeet-coreml-swift commit 75aec2a1c991319657ff4dec5f602c12da6c5012.
// Changes are documented in Packages/ParakeetCore/NOTICE.md.
import Foundation

/// Minimal detokenizer for Parakeet TDT's BPE/SentencePiece vocab.
///
/// Reads the ``vocab`` map out of a HuggingFace ``tokenizer.json`` (which is
/// keyed on the BPE piece string and values are integer IDs). At decode time
/// we map IDs back to pieces, replace the SentencePiece whitespace marker
/// ``▁`` (U+2581) with a real space, and concatenate.
///
/// Encoding isn't implemented; we only ever use this to turn the decoder's
/// argmax stream into human-readable text.
final class Tokenizer {
    let idToPiece: [String]  // idToPiece[id] == piece
    let specialIDs: Set<Int>  // ids to skip when ``skipSpecial`` is true

    /// SentencePiece whitespace marker.
    static let metaSpace: Character = "\u{2581}"

    /// The subword string an id spells, for tools that need to map tokens back
    /// onto words — per-word confidence, contextual bias diagnostics.
    public func piece(for id: Int) -> String? {
        guard idToPiece.indices.contains(id), !specialIDs.contains(id) else {
            return nil
        }
        return idToPiece[id]
    }

    init(tokenizerJSONURL url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ParakeetError.tokenizerLoadFailed(url: url, underlying: error)
        }

        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParakeetError.tokenizerLoadFailed(url: url, underlying: error)
        }

        guard let root = obj as? [String: Any],
            let model = root["model"] as? [String: Any],
            let vocab = model["vocab"] as? [String: Any]
        else {
            let e = NSError(
                domain: "ParakeetTokenizer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing model.vocab in tokenizer.json"]
            )
            throw ParakeetError.tokenizerLoadFailed(url: url, underlying: e)
        }

        // Added tokens cover IDs outside the main vocab (blank, <pad>, etc.).
        let addedTokens = (root["added_tokens"] as? [[String: Any]]) ?? []

        // Collect (piece, id) pairs.
        var pairs: [(String, Int)] = []
        pairs.reserveCapacity(vocab.count + addedTokens.count)
        for (piece, any) in vocab {
            if let n = any as? Int {
                pairs.append((piece, n))
            } else if let n = any as? NSNumber {
                pairs.append((piece, n.intValue))
            }
        }
        // Specials that extend the range (e.g. blank at id 8192).
        for tok in addedTokens {
            guard let id = tok["id"] as? Int ?? (tok["id"] as? NSNumber)?.intValue,
                let content = tok["content"] as? String
            else { continue }
            pairs.append((content, id))
        }

        let maxID = pairs.map(\.1).max() ?? -1
        var pieces = [String](repeating: "", count: maxID + 1)
        for (p, i) in pairs where i >= 0 && i <= maxID {
            pieces[i] = p
        }
        self.idToPiece = pieces

        // Heuristic: anything in angle-brackets (``<unk>``, ``<|pnc|>``,
        // ``<blank>`` ...) is a control token and suppressed by default.
        var specials = Set<Int>()
        for (i, p) in pieces.enumerated() where p.hasPrefix("<") && p.hasSuffix(">") {
            specials.insert(i)
        }
        // Also honour explicit `special: true` flags on added tokens.
        for tok in addedTokens {
            guard let id = tok["id"] as? Int ?? (tok["id"] as? NSNumber)?.intValue
            else { continue }
            if (tok["special"] as? Bool) == true {
                specials.insert(id)
            }
        }
        self.specialIDs = specials
    }

    /// Piece string to id, built lazily because only vocabulary biasing needs it.
    private lazy var pieceToID: [String: Int] = {
        var map = [String: Int](minimumCapacity: idToPiece.count)
        for (id, piece) in idToPiece.enumerated() where !piece.isEmpty {
            // Earlier ids win so a duplicate piece resolves deterministically.
            if map[piece] == nil { map[piece] = id }
        }
        return map
    }()

    /// Segment a word into the vocabulary pieces the decoder would emit for it.
    ///
    /// This is a greedy longest-match walk, not the full BPE merge sequence, so
    /// it is not a faithful round-trip of the training-time encoder. That is
    /// deliberate and sufficient: the result feeds a logit bias, where the
    /// question is only "which pieces must become more likely for this word to
    /// appear", and greedy segmentation names them. Returns nil when the word
    /// cannot be covered, so a caller never boosts a partial spelling.
    func pieces(forWord word: String) -> [Int]? {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        // SentencePiece marks a word start; without it the boost would only
        // apply mid-word.
        let target = Array(String(Tokenizer.metaSpace) + normalized)
        var ids = [Int]()
        var index = 0
        while index < target.count {
            var matched = false
            var length = target.count - index
            while length > 0 {
                let candidate = String(target[index..<(index + length)])
                if let id = pieceToID[candidate], !specialIDs.contains(id) {
                    ids.append(id)
                    index += length
                    matched = true
                    break
                }
                length -= 1
            }
            if !matched { return nil }
        }
        return ids.isEmpty ? nil : ids
    }

    /// Translate token IDs into a string. Repeated lexical pieces are kept
    /// because TDT can emit the same subword twice legitimately. Consecutive
    /// sentence-punctuation pieces are collapsed to avoid zero-duration
    /// punctuation loops such as `"........"`.
    func decode(_ ids: [Int], skipSpecial: Bool = true) -> String {
        var chars = [Character]()
        chars.reserveCapacity(ids.count * 3)
        var previousPunctuationID: Int?
        for id in ids {
            guard id >= 0, id < idToPiece.count else { continue }
            if skipSpecial && specialIDs.contains(id) { continue }
            let piece = idToPiece[id]
            let isSentencePunctuation = Self.sentencePunctuationPieces.contains(piece)
            if isSentencePunctuation && id == previousPunctuationID { continue }
            previousPunctuationID = isSentencePunctuation ? id : nil
            for ch in piece {
                chars.append(ch == Tokenizer.metaSpace ? " " : ch)
            }
        }
        // SentencePiece inserts a leading ``▁`` on the first real word.
        var text = String(chars)
        if text.hasPrefix(" ") { text.removeFirst() }
        return text
    }

    private static let sentencePunctuationPieces: Set<String> = [
        ".", ",", "!", "?", ";", ":",
    ]
}
