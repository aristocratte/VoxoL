import Foundation

/// Boosts a user's vocabulary only where the decoder is already spelling it.
///
/// The first attempt at this boosted every subword piece of every term, at all
/// times. Measured on FLEURS English with sixty terms, that made the benchmark
/// *worse*: 5.04% to 5.71%, and worse even on the clips that contained the
/// terms. The reason is visible as soon as the terms are tokenised —
/// `humpback` is `▁h` + `ump` + `b` + `ack`, and three of those four pieces
/// appear inside thousands of unrelated words. Adding four logits to `ack`
/// everywhere corrupts far more words than the one it was meant to rescue.
///
/// This applies the boost along a trie instead. A piece is encouraged only when
/// it continues a term the decoder has already started, so `ump` is boosted
/// after `▁h` and nowhere else. The entry pieces carry a much smaller boost
/// than the continuations: getting a term started is the acoustic model's job
/// when the user really said it, and holding the term together afterwards is
/// where a generic model needs the help.
public struct ParakeetContextualBias: Sendable {
    /// One node of the vocabulary trie, keyed by token id.
    fileprivate final class Node: @unchecked Sendable {
        var children: [Int: Node] = [:]
        var isTerminal = false
    }

    private let root: Node
    private let entryBoost: Float
    private let continuationBoost: Float

    /// A term must survive its own first piece before the boost is worth much,
    /// and entry pieces are the common ones, so they get a fraction.
    public static let defaultEntryBoost: Float = 1
    /// Continuations are where a term falls apart into other words.
    public static let defaultContinuationBoost: Float = 6

    /// Builds the trie from already-tokenised terms.
    public init(
        termPieces: [[Int]],
        entryBoost: Float = defaultEntryBoost,
        continuationBoost: Float = defaultContinuationBoost
    ) {
        let root = Node()
        for pieces in termPieces where !pieces.isEmpty {
            var node = root
            for piece in pieces {
                if let next = node.children[piece] {
                    node = next
                } else {
                    let next = Node()
                    node.children[piece] = next
                    node = next
                }
            }
            node.isTerminal = true
        }
        self.root = root
        self.entryBoost = entryBoost
        self.continuationBoost = continuationBoost
    }

    /// True when there is no vocabulary, so the decoder can skip the work.
    public var isEmpty: Bool { root.children.isEmpty }

    /// Tracks how far into each term the decoder currently is.
    ///
    /// A value type so the decoder can hold one per hypothesis if it ever grows
    /// a beam, and so resetting between utterances cannot be forgotten.
    public struct State: Sendable {
        fileprivate var active: [Node]

        fileprivate init(root: Node) {
            self.active = [root]
        }
    }

    /// A state positioned at the start of every term.
    public func initialState() -> State { State(root: root) }

    /// Offsets to add for the next token given how far terms have progressed.
    ///
    /// Returns nil when nothing applies, so the common case costs no allocation
    /// and the decoder's argmax stays a plain scan.
    public func offsets(for state: State) -> [Int: Float]? {
        guard !isEmpty else { return nil }
        var result = [Int: Float]()
        for node in state.active {
            // The root's children are entry pieces; anything deeper is a
            // continuation of a term already under way.
            let boost = node === root ? entryBoost : continuationBoost
            for (piece, _) in node.children {
                result[piece] = max(result[piece] ?? 0, boost)
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Advances the state after `tokenID` was emitted.
    ///
    /// The root stays active so a term can begin at any point, and a partial
    /// match that the token does not continue is dropped rather than kept
    /// alive — a stale match would boost pieces of a word nobody is saying.
    public func advanced(_ state: State, emitting tokenID: Int) -> State {
        var next = State(root: root)
        var nodes = [root]
        for node in state.active {
            if let child = node.children[tokenID] {
                nodes.append(child)
            }
        }
        next.active = nodes
        return next
    }
}
