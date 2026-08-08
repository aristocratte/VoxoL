import Foundation

/// Per-token logit offsets applied to the decoder's argmax.
///
/// Two product needs turn out to be the same operation with opposite signs:
///
/// - the model picks its language per utterance and emits English function
///   words inside French speech, which a negative offset on those tokens
///   suppresses;
/// - a user's own vocabulary — project names, jargon, client names — is exactly
///   what a generic model gets wrong, and a positive offset on those tokens
///   makes the model produce them.
///
/// The second is the one a cloud competitor cannot match without holding the
/// user's dictionary on its servers. Both share this type so the decoder makes
/// a single pass over the 8,193-wide logit row rather than one per feature.
public struct ParakeetDecodingBias: Sendable, Equatable {
    /// Token id to the logits added to it. Ids absent here are untouched.
    public let offsets: [Int: Float]

    /// Creates a bias from explicit per-token offsets.
    public init(offsets: [Int: Float] = [:]) {
        self.offsets = offsets
    }

    /// True when there is nothing to apply, so the decoder can skip the scan.
    public var isEmpty: Bool { offsets.isEmpty }

    /// Merges two biases, summing offsets that collide.
    ///
    /// A collision is meaningful rather than a conflict: a user who puts an
    /// English term in their dictionary while dictating French should see the
    /// boost and the language penalty net out, not one silently override the
    /// other.
    public func merging(_ other: ParakeetDecodingBias) -> ParakeetDecodingBias {
        ParakeetDecodingBias(offsets: offsets.merging(other.offsets, uniquingKeysWith: +))
    }

    /// Discourages every listed token by `amount` logits.
    public static func discouraging(
        _ tokenIds: some Sequence<Int>,
        by amount: Float
    ) -> ParakeetDecodingBias {
        ParakeetDecodingBias(
            offsets: Dictionary(
                tokenIds.map { ($0, -amount) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// Encourages every listed token by `amount` logits.
    public static func encouraging(
        _ tokenIds: some Sequence<Int>,
        by amount: Float
    ) -> ParakeetDecodingBias {
        ParakeetDecodingBias(
            offsets: Dictionary(
                tokenIds.map { ($0, amount) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }
}

extension ParakeetDecodingBias {
    /// Default logit cost applied to an out-of-language token.
    ///
    /// Swept on the 312 French chunks the 2026-08-03 corpus shows drifting into
    /// English. At 12 logits, 79% of the parasitic English words disappear
    /// (3,296 to 691) and word error on those chunks falls 3.34 points, while
    /// general French audio pays 0.12 points on MediaSpeech FR. The benefit was
    /// still climbing at this value; the cost had flattened.
    public static let defaultLanguagePenaltyAmount: Float = 12

    /// Reads `language-penalty.json` from beside the model.
    ///
    /// Returns nil for any language other than French, which is the point: the
    /// suppressed tokens are English function words, so applying this while
    /// dictating English would suppress most of the transcript. A caller that
    /// cannot name the language — an automatic mode — must pass nil and accept
    /// the drift rather than guess.
    public static func languagePenalty(
        forLanguageCode code: String,
        modelsRoot: URL,
        amount: Float = defaultLanguagePenaltyAmount
    ) -> ParakeetDecodingBias? {
        guard code.lowercased().hasPrefix("fr"), amount > 0 else { return nil }
        guard
            let data = try? Data(
                contentsOf: modelsRoot.appendingPathComponent("language-penalty.json")
            ),
            let payload = try? JSONSerialization.jsonObject(with: data),
            let object = payload as? [String: Any],
            let ids = object["french_suppressed_token_ids"] as? [Int],
            !ids.isEmpty
        else {
            return nil
        }
        return .discouraging(ids, by: amount)
    }
}
