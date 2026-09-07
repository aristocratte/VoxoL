import Foundation
import TextProcessingKit

/// Exact generation inputs, not a fuzzy match on the visible transcript.
struct PolishingRequestKey: Hashable, Sendable {
    // Swift String equality folds canonically equivalent Unicode. Tokenizers
    // need not: byte-exact keys avoid reusing a result for a different token input.
    let system: Data
    let user: Data
    let maximumOutputTokens: Int

    init(_ prompt: PolishingPrompt) {
        system = Data(prompt.system.utf8)
        user = Data(prompt.user.utf8)
        maximumOutputTokens = prompt.maximumOutputTokens
    }

    var byteCount: Int { system.count + user.count + 64 }
}

/// Actor-owned, bounded, in-memory results for one active dictation only.
/// No embeddings, approximate lookup, persisted content or cross-session reuse.
struct SessionPolishingCache {
    private enum Entry {
        case generated(QwenPolisherResult)
        case terminalFailure(QwenPolisherError)

        var outputByteCount: Int {
            if case .generated(let result) = self { return result.text.utf8.count }
            return 0
        }
    }

    private(set) var sessionID: UUID?
    private(set) var byteCount = 0
    private var entries = [PolishingRequestKey: Entry]()
    private var insertionOrder = [PolishingRequestKey]()
    let maximumEntries: Int
    let maximumBytes: Int

    init(maximumEntries: Int = 96, maximumBytes: Int = 1_048_576) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
    }

    mutating func begin(_ id: UUID) {
        guard sessionID != id else { return }
        removeAll()
        sessionID = id
    }

    mutating func end(_ id: UUID) {
        guard sessionID == id else { return }
        removeAll()
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
        byteCount = 0
        sessionID = nil
    }

    func result(for key: PolishingRequestKey, session id: UUID?) -> QwenPolisherResult? {
        guard let id, sessionID == id else { return nil }
        if case .generated(let result) = entries[key] { return result }
        return nil
    }

    func terminalFailure(for key: PolishingRequestKey, session id: UUID?) -> QwenPolisherError? {
        guard let id, sessionID == id else { return nil }
        if case .terminalFailure(let error) = entries[key] { return error }
        return nil
    }

    mutating func store(
        _ result: QwenPolisherResult, for key: PolishingRequestKey, session id: UUID?
    ) {
        storeEntry(.generated(result), for: key, session: id)
    }

    /// A completed greedy decode with empty output or a hard output ceiling is
    /// deterministic under an unchanged prompt/model. Keep its failure status,
    /// never a fake successful result. Resource/time/cancellation failures must
    /// remain retryable and are deliberately excluded.
    mutating func storeTerminalFailure(
        _ error: QwenPolisherError, for key: PolishingRequestKey, session id: UUID?
    ) {
        guard error == .emptyOutput || error == .tokenLimitReached else { return }
        storeEntry(.terminalFailure(error), for: key, session: id)
    }

    private mutating func storeEntry(
        _ entry: Entry, for key: PolishingRequestKey, session id: UUID?
    ) {
        guard let id, sessionID == id, entries[key] == nil, maximumEntries > 0 else { return }
        let bytes = key.byteCount + entry.outputByteCount + 128
        guard bytes <= maximumBytes else { return }
        while entries.count >= maximumEntries || byteCount + bytes > maximumBytes {
            let oldest = insertionOrder.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                byteCount -= oldest.byteCount + removed.outputByteCount + 128
            }
        }
        entries[key] = entry
        insertionOrder.append(key)
        byteCount += bytes
    }
}
