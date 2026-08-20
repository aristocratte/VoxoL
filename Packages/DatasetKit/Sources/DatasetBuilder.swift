import CryptoKit
import FidelityKit
import Foundation
import PersonalizationKit
import TextProcessingKit

/// One reviewed cleanup pair in VoxoL's durable source format.
public struct CleanupDatasetExample: Codable, Equatable, Sendable {
    /// Stable source identifier used for deterministic splitting.
    public let id: String
    /// `fr` or `en`.
    public let language: String
    /// One `WritingProfile` raw value.
    public let profile: String
    /// Coarse app category, never a private bundle identifier.
    public let appCategory: String
    /// Bounded text immediately before the cursor.
    public let beforeCursor: String
    /// Bounded text immediately after the cursor.
    public let afterCursor: String
    /// Explicit dictionary terms available to cleanup.
    public let dictionary: [String]
    /// Values that must survive byte-for-byte.
    public let protectedTokens: [String]
    /// Verbatim source transcript.
    public let rawTranscript: String
    /// Human-approved faithful output.
    public let targetText: String
    /// Labeled cleanup operations represented by the pair.
    public let operations: [String]
    /// Provenance such as `human` or `synthetic-reviewed`.
    public let source: String
    /// Whether a human approved this pair for training.
    public let approved: Bool
    /// Optional explicit `train`, `validation` or `test` assignment.
    public let split: String?
    /// Source-level group that must never cross explicit splits.
    public let splitGroup: String?
    /// Cleanup contract: nil or `faithful`, or `rewrite`.
    ///
    /// The contract shapes everything downstream — which system instruction
    /// the pair trains, and which fidelity rules its target must satisfy to
    /// enter the dataset at all. Faithful validation silently rejected every
    /// teacher output that dropped a discourse word, which is how a corpus
    /// meant to teach rewriting taught timidity instead.
    public let mode: String?

    enum CodingKeys: String, CodingKey {
        case id, language, profile, dictionary, operations, source, approved, split
        case mode
        case appCategory = "app_category"
        case beforeCursor = "before_cursor"
        case afterCursor = "after_cursor"
        case protectedTokens = "protected_tokens"
        case rawTranscript = "raw_transcript"
        case targetText = "target_text"
        case splitGroup = "split_group"
    }

    /// Creates one reviewed source pair.
    public init(
        id: String,
        language: String,
        profile: String,
        appCategory: String,
        beforeCursor: String = "",
        afterCursor: String = "",
        dictionary: [String] = [],
        protectedTokens: [String] = [],
        rawTranscript: String,
        targetText: String,
        operations: [String] = [],
        source: String,
        approved: Bool,
        split: String? = nil,
        splitGroup: String? = nil,
        mode: String? = nil
    ) {
        self.id = id
        self.language = language
        self.profile = profile
        self.appCategory = appCategory
        self.beforeCursor = beforeCursor
        self.afterCursor = afterCursor
        self.dictionary = dictionary
        self.protectedTokens = protectedTokens
        self.rawTranscript = rawTranscript
        self.targetText = targetText
        self.operations = operations
        self.source = source
        self.approved = approved
        self.split = split
        self.splitGroup = splitGroup
        self.mode = mode
    }
}

/// One MLX LM chat message.
public struct TrainingMessage: Codable, Equatable, Sendable {
    /// Chat role.
    public let role: String
    /// Message content.
    public let content: String
}

/// A chat record accepted by MLX LM's JSONL loader.
public struct TrainingRecord: Codable, Equatable, Sendable {
    /// System, user and assistant messages in order.
    public let messages: [TrainingMessage]
}

/// Deterministic 80/10/10 output plus rejected source identifiers.
public struct DatasetBuildResult: Equatable, Sendable {
    /// Training records.
    public let train: [TrainingRecord]
    /// Validation records.
    public let validation: [TrainingRecord]
    /// Held-out test records.
    public let test: [TrainingRecord]
    /// IDs excluded by approval, validation or deduplication.
    public let rejectedIDs: [String]
}

/// One held-out prediction paired with its human-approved reference.
public struct CleanupEvaluationExample: Codable, Equatable, Sendable {
    /// Stable example identifier.
    public let id: String
    /// Human-approved output.
    public let expectedText: String
    /// Output produced by the runtime under evaluation.
    public let actualText: String
    /// Values that must be preserved byte-for-byte.
    public let protectedTokens: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case expectedText = "expected_text"
        case actualText = "actual_text"
        case protectedTokens = "protected_tokens"
    }

    /// Creates one held-out evaluation pair.
    public init(
        id: String,
        expectedText: String,
        actualText: String,
        protectedTokens: [String] = []
    ) {
        self.id = id
        self.expectedText = expectedText
        self.actualText = actualText
        self.protectedTokens = protectedTokens
    }
}

/// Aggregate, content-free cleanup quality metrics.
public struct CleanupEvaluationResult: Codable, Equatable, Sendable {
    /// Number of evaluated examples.
    public let exampleCount: Int
    /// Fraction whose output exactly matches the approved target.
    public let exactMatchRate: Double
    /// Character edit distance divided by the longer text length.
    public let meanNormalizedEditDistance: Double
    /// Fraction of protected-token occurrences retained exactly.
    public let protectedTokenRecall: Double
    /// Fraction of output words that do not occur in the approved target.
    public let unexpectedWordRate: Double
}

/// Computes deterministic held-out metrics without retaining example content in the report.
public enum CleanupEvaluator {
    /// Evaluates already-generated predictions against approved targets.
    public static func evaluate(_ examples: [CleanupEvaluationExample]) -> CleanupEvaluationResult {
        guard !examples.isEmpty else {
            return CleanupEvaluationResult(
                exampleCount: 0,
                exactMatchRate: 0,
                meanNormalizedEditDistance: 0,
                protectedTokenRecall: 1,
                unexpectedWordRate: 0
            )
        }

        var exactMatches = 0
        var normalizedDistances = 0.0
        var protectedTotal = 0
        var protectedRetained = 0
        var outputWordTotal = 0
        var unexpectedWordTotal = 0

        for example in examples {
            exactMatches += example.expectedText == example.actualText ? 1 : 0
            let denominator = max(1, example.expectedText.count, example.actualText.count)
            normalizedDistances +=
                Double(
                    editDistance(example.expectedText, example.actualText)
                ) / Double(denominator)

            for token in example.protectedTokens {
                protectedTotal += 1
                protectedRetained += example.actualText.contains(token) ? 1 : 0
            }

            let expectedWords = wordCounts(example.expectedText)
            var remaining = expectedWords
            for word in words(example.actualText) {
                outputWordTotal += 1
                if let count = remaining[word], count > 0 {
                    remaining[word] = count - 1
                } else {
                    unexpectedWordTotal += 1
                }
            }
        }

        return CleanupEvaluationResult(
            exampleCount: examples.count,
            exactMatchRate: Double(exactMatches) / Double(examples.count),
            meanNormalizedEditDistance: normalizedDistances / Double(examples.count),
            protectedTokenRecall: protectedTotal == 0
                ? 1 : Double(protectedRetained) / Double(protectedTotal),
            unexpectedWordRate: outputWordTotal == 0
                ? 0 : Double(unexpectedWordTotal) / Double(outputWordTotal)
        )
    }
}

/// Validates, deduplicates and converts reviewed pairs into MLX LM chat splits.
public enum DatasetBuilder {
    /// Recreates the exact deterministic preparation used by the production polisher.
    public static func prepare(
        _ example: CleanupDatasetExample,
        fastPathEnabled: Bool = false
    ) -> DeterministicPreparation {
        preparation(for: example, fastPathEnabled: fastPathEnabled)
    }

    /// Builds stable splits without allowing a protected value to disappear.
    public static func build(_ examples: [CleanupDatasetExample]) -> DatasetBuildResult {
        var train: [TrainingRecord] = []
        var validation: [TrainingRecord] = []
        var test: [TrainingRecord] = []
        var rejected: [String] = []
        var contentKeys = Set<String>()
        var splitsByGroup: [String: Set<String>] = [:]
        for example in examples {
            guard let group = example.splitGroup, let split = example.split else {
                continue
            }
            splitsByGroup[group, default: []].insert(split)
        }
        let conflictingGroups = Set(
            splitsByGroup.compactMap { group, splits in
                splits.count > 1 ? group : nil
            }
        )

        for example in examples.sorted(by: { $0.id < $1.id }) {
            guard isValid(example),
                example.splitGroup.map({ !conflictingGroups.contains($0) }) ?? true
            else {
                rejected.append(example.id)
                continue
            }
            let key =
                example.language + "\u{1F}" + example.rawTranscript + "\u{1F}"
                + example.targetText
            guard contentKeys.insert(key).inserted else {
                rejected.append(example.id)
                continue
            }
            let record = trainingRecord(for: example)
            switch assignedSplit(for: example) {
            case "train":
                train.append(record)
            case "validation":
                validation.append(record)
            case "test":
                test.append(record)
            default:
                preconditionFailure("Validated examples always have a supported split")
            }
        }
        return DatasetBuildResult(
            train: train,
            validation: validation,
            test: test,
            rejectedIDs: rejected
        )
    }
}

private extension DatasetBuilder {
    static func isValid(_ example: CleanupDatasetExample) -> Bool {
        guard example.approved, !example.id.isEmpty, !example.rawTranscript.isEmpty,
            !example.targetText.isEmpty,
            ["fr", "en"].contains(example.language),
            WritingProfile(rawValue: example.profile) != nil,
            example.split.map({ ["train", "validation", "test"].contains($0) }) ?? true
        else {
            return false
        }
        guard example.targetText.count <= Int(Double(example.rawTranscript.count) * 1.5) + 32 else {
            return false
        }
        guard
            example.protectedTokens.allSatisfy(example.rawTranscript.contains),
            example.protectedTokens.allSatisfy(example.targetText.contains)
        else {
            return false
        }
        let preparation = preparation(for: example)
        guard let target = protectedTarget(for: preparation, target: example.targetText) else {
            return false
        }
        return FidelityValidator.validate(candidate: target, against: preparation)
            .usedModelOutput
    }

    static func trainingRecord(for example: CleanupDatasetExample) -> TrainingRecord {
        let preparation = preparation(for: example)
        let prompt = PolishingPromptBuilder.build(from: preparation)
        guard let protectedTarget = protectedTarget(for: preparation, target: example.targetText)
        else {
            preconditionFailure("Validated examples always have a protected target")
        }
        return TrainingRecord(
            messages: [
                TrainingMessage(role: "system", content: prompt.system),
                TrainingMessage(role: "user", content: prompt.user),
                TrainingMessage(role: "assistant", content: protectedTarget),
            ]
        )
    }

    static func preparation(
        for example: CleanupDatasetExample,
        fastPathEnabled: Bool = false
    ) -> DeterministicPreparation {
        let language: TextLanguage = example.language == "fr" ? .french : .english
        let profile = WritingProfile(rawValue: example.profile) ?? .automatic
        let protectedDictionary = Array(
            Set(example.dictionary + example.protectedTokens)
        ).sorted()
        let personalization = PersonalizationSnapshot(
            dictionary: protectedDictionary.map { DictionaryEntry(canonical: $0) }
        )
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: example.rawTranscript,
                preferredLanguage: language,
                context: TextProcessingContext(
                    applicationName: example.appCategory,
                    beforeCursor: example.beforeCursor,
                    afterCursor: example.afterCursor
                ),
                preferences: TextProcessingPreferences(
                    cleanupMode: example.mode == "rewrite" ? .rewrite : .faithful,
                    fastPathEnabled: fastPathEnabled,
                    profile: profile
                ),
                personalization: personalization
            )
        )
        return preparation
    }

    static func protectedTarget(
        for preparation: DeterministicPreparation,
        target: String
    ) -> String? {
        guard !target.contains("VOXOLP") else {
            return nil
        }
        let source = target as NSString
        var searchLocation = 0
        var replacements = [(NSRange, String)]()
        for token in preparation.protectedTokens {
            let escaped = NSRegularExpression.escapedPattern(for: token.value)
            let requiresBoundaries: Bool
            switch token.kind {
            case .code, .url, .email, .path:
                requiresBoundaries = false
            case .commandFlag, .dateOrTime, .number, .dictionaryTerm, .negation:
                requiresBoundaries = true
            }
            let pattern =
                requiresBoundaries
                ? "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
                : escaped
            guard
                let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else {
                return nil
            }
            let searchRange = NSRange(
                location: searchLocation,
                length: source.length - searchLocation
            )
            guard let match = regex.firstMatch(in: target, range: searchRange) else {
                return nil
            }
            replacements.append((match.range, token.placeholder))
            searchLocation = NSMaxRange(match.range)
        }

        let result = NSMutableString(string: target)
        for (range, placeholder) in replacements.reversed() {
            result.replaceCharacters(in: range, with: placeholder)
        }
        return String(result)
    }

    static func assignedSplit(for example: CleanupDatasetExample) -> String {
        if let split = example.split {
            return split
        }
        switch bucket(for: example.id) {
        case 0..<80:
            return "train"
        case 80..<90:
            return "validation"
        default:
            return "test"
        }
    }

    static func bucket(for identifier: String) -> Int {
        let digest = SHA256.hash(data: Data(identifier.utf8))
        let value = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(value % 100)
    }
}

private extension CleanupEvaluator {
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static func wordCounts(_ text: String) -> [String: Int] {
        words(text).reduce(into: [:]) { counts, word in
            counts[word, default: 0] += 1
        }
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let source = Array(lhs)
        let target = Array(rhs)
        var previous = Array(0...target.count)
        for (sourceIndex, sourceCharacter) in source.enumerated() {
            var current = [sourceIndex + 1]
            current.reserveCapacity(target.count + 1)
            for (targetIndex, targetCharacter) in target.enumerated() {
                current.append(
                    min(
                        current[targetIndex] + 1,
                        previous[targetIndex + 1] + 1,
                        previous[targetIndex] + (sourceCharacter == targetCharacter ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return previous[target.count]
    }
}
