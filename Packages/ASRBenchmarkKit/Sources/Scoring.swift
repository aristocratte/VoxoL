// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
import Foundation

public struct ASRBenchmarkConfidenceSignals: Codable, Equatable, Sendable {
    public let emittedTokenCount: Int
    public let meanTokenLogitMargin: Double
    public let lowerDecileTokenLogitMargin: Double
    public let meanDurationLogitMargin: Double
    public let lowerDecileDurationLogitMargin: Double
    public let blankDecisionRatio: Double
    public let maximumFramesWithoutEmission: Int
    public let minimumOverlapTokenAgreement: Double?
    public let inferenceAttemptCount: Int
    public let usedFallbackSegmentation: Bool

    public init(
        emittedTokenCount: Int,
        meanTokenLogitMargin: Double,
        lowerDecileTokenLogitMargin: Double,
        meanDurationLogitMargin: Double,
        lowerDecileDurationLogitMargin: Double,
        blankDecisionRatio: Double,
        maximumFramesWithoutEmission: Int,
        minimumOverlapTokenAgreement: Double?,
        inferenceAttemptCount: Int,
        usedFallbackSegmentation: Bool
    ) {
        self.emittedTokenCount = emittedTokenCount
        self.meanTokenLogitMargin = meanTokenLogitMargin
        self.lowerDecileTokenLogitMargin = lowerDecileTokenLogitMargin
        self.meanDurationLogitMargin = meanDurationLogitMargin
        self.lowerDecileDurationLogitMargin = lowerDecileDurationLogitMargin
        self.blankDecisionRatio = blankDecisionRatio
        self.maximumFramesWithoutEmission = maximumFramesWithoutEmission
        self.minimumOverlapTokenAgreement = minimumOverlapTokenAgreement
        self.inferenceAttemptCount = inferenceAttemptCount
        self.usedFallbackSegmentation = usedFallbackSegmentation
    }
}

public struct ASRBenchmarkPrediction: Codable, Equatable, Sendable {
    public let id: String
    public let rawText: String
    public let finalText: String
    public let languageDrift: Bool?
    public let inferenceMilliseconds: Double?
    public let releaseToInsertionMilliseconds: Double?
    public let confidence: ASRBenchmarkConfidenceSignals?

    public init(
        id: String,
        rawText: String,
        finalText: String? = nil,
        languageDrift: Bool? = nil,
        inferenceMilliseconds: Double? = nil,
        releaseToInsertionMilliseconds: Double? = nil,
        confidence: ASRBenchmarkConfidenceSignals? = nil
    ) {
        self.id = id
        self.rawText = rawText
        self.finalText = finalText ?? rawText
        self.languageDrift = languageDrift
        self.inferenceMilliseconds = inferenceMilliseconds
        self.releaseToInsertionMilliseconds = releaseToInsertionMilliseconds
        self.confidence = confidence
    }
}

public struct ASREditCounts: Codable, Equatable, Sendable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceUnitCount: Int

    public init(
        substitutions: Int = 0,
        deletions: Int = 0,
        insertions: Int = 0,
        referenceUnitCount: Int = 0
    ) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceUnitCount = referenceUnitCount
    }

    public var errorRate: Double {
        referenceUnitCount > 0
            ? Double(substitutions + deletions + insertions)
                / Double(referenceUnitCount)
            : 0
    }

    mutating func add(_ other: ASREditCounts) {
        substitutions += other.substitutions
        deletions += other.deletions
        insertions += other.insertions
        referenceUnitCount += other.referenceUnitCount
    }
}

public struct ASRBenchmarkSliceScore: Codable, Equatable, Sendable {
    public let itemCount: Int
    public let wordErrors: ASREditCounts
    public let characterErrors: ASREditCounts
    public let macroWER: Double
    public let exactMatchRate: Double
    public let criticalSpanErrorRate: Double
    public let languageDriftAssessedItemCount: Int
    public let languageDriftRate: Double?
}

public struct ASRBenchmarkLatencyDistribution: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let minimumMilliseconds: Double
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let p99Milliseconds: Double
    public let maximumMilliseconds: Double
}

public struct ASRBenchmarkLatencyReport: Codable, Equatable, Sendable {
    public let inference: ASRBenchmarkLatencyDistribution?
    public let releaseToInsertion: ASRBenchmarkLatencyDistribution?
}

public struct ASRBenchmarkScoreReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let benchmarkID: String
    public let manifestSHA256: String
    public let rawVerbatim: ASRBenchmarkSliceScore
    public let finalClean: ASRBenchmarkSliceScore
    public let rawByLanguage: [String: ASRBenchmarkSliceScore]
    public let finalByLanguage: [String: ASRBenchmarkSliceScore]
    public let rawByTag: [String: ASRBenchmarkSliceScore]
    public let rawByMicrophone: [String: ASRBenchmarkSliceScore]
    public let rawByEnvironment: [String: ASRBenchmarkSliceScore]
    public let latency: ASRBenchmarkLatencyReport
}

/// One item's own error counts, for interval estimates over a benchmark.
///
/// The aggregate report answers "how good is this system". Deciding whether one
/// system is really ahead of another needs the per-item errors behind that
/// aggregate, so a paired bootstrap can say how much of the gap is sampling
/// noise. Recomputing them outside this type would introduce a second
/// normaliser, and two normalisers eventually disagree.
public struct ASRBenchmarkItemScore: Codable, Equatable, Sendable {
    public let id: String
    public let language: String
    public let rawWordErrors: ASREditCounts
    public let finalWordErrors: ASREditCounts
    public let rawExact: Bool
    public let inferenceMilliseconds: Double?
}

public enum ASRBenchmarkScoringError: Error, Equatable, LocalizedError, Sendable {
    case missingPrediction(String)
    case duplicatePrediction(String)
    case unknownPrediction(String)

    public var errorDescription: String? {
        switch self {
        case .missingPrediction(let identifier):
            "Missing prediction for benchmark item: \(identifier)"
        case .duplicatePrediction(let identifier):
            "Duplicate prediction for benchmark item: \(identifier)"
        case .unknownPrediction(let identifier):
            "Prediction does not exist in the benchmark: \(identifier)"
        }
    }
}

public enum ASRBenchmarkScorer {
    public static func score(
        manifest: ASRBenchmarkManifest,
        predictions: [ASRBenchmarkPrediction]
    ) throws -> ASRBenchmarkScoreReport {
        try manifest.validate(requireFrozen: true)
        var predictionsByID = [String: ASRBenchmarkPrediction]()
        let itemIDs = Set(manifest.items.map(\.id))
        for prediction in predictions {
            guard itemIDs.contains(prediction.id) else {
                throw ASRBenchmarkScoringError.unknownPrediction(prediction.id)
            }
            guard predictionsByID[prediction.id] == nil else {
                throw ASRBenchmarkScoringError.duplicatePrediction(prediction.id)
            }
            predictionsByID[prediction.id] = prediction
        }

        var rawItems = [ItemScore]()
        var finalItems = [ItemScore]()
        var rawByLanguage = [ASRBenchmarkLanguage: [ItemScore]]()
        var finalByLanguage = [ASRBenchmarkLanguage: [ItemScore]]()
        var rawByTag = [String: [ItemScore]]()
        var rawByMicrophone = [String: [ItemScore]]()
        var rawByEnvironment = [String: [ItemScore]]()
        for item in manifest.items {
            guard let prediction = predictionsByID[item.id] else {
                throw ASRBenchmarkScoringError.missingPrediction(item.id)
            }
            let raw = itemScore(
                reference: item.reference.verbatim,
                hypothesis: prediction.rawText,
                criticalSpans: item.reference.criticalSpans,
                languageDrift: prediction.languageDrift
            )
            rawItems.append(raw)
            rawByLanguage[item.language, default: []].append(raw)
            rawByMicrophone[item.microphone, default: []].append(raw)
            rawByEnvironment[item.environment, default: []].append(raw)
            for tag in Set(item.tags) {
                rawByTag[tag, default: []].append(raw)
            }
            let final = itemScore(
                reference: item.reference.clean,
                hypothesis: prediction.finalText,
                criticalSpans: item.reference.criticalSpans,
                languageDrift: prediction.languageDrift
            )
            finalItems.append(final)
            finalByLanguage[item.language, default: []].append(final)
        }

        return ASRBenchmarkScoreReport(
            schemaVersion: 2,
            benchmarkID: manifest.benchmarkID,
            manifestSHA256: try manifest.digest(),
            rawVerbatim: aggregate(rawItems),
            finalClean: aggregate(finalItems),
            rawByLanguage: Dictionary(
                uniqueKeysWithValues: rawByLanguage.map {
                    ($0.key.rawValue, aggregate($0.value))
                }
            ),
            finalByLanguage: Dictionary(
                uniqueKeysWithValues: finalByLanguage.map {
                    ($0.key.rawValue, aggregate($0.value))
                }
            ),
            rawByTag: aggregate(rawByTag),
            rawByMicrophone: aggregate(rawByMicrophone),
            rawByEnvironment: aggregate(rawByEnvironment),
            latency: ASRBenchmarkLatencyReport(
                inference: latencyDistribution(
                    predictions.compactMap(\.inferenceMilliseconds)
                ),
                releaseToInsertion: latencyDistribution(
                    predictions.compactMap(\.releaseToInsertionMilliseconds)
                )
            )
        )
    }

    /// Per-item error counts, in manifest order.
    ///
    /// Shares `itemScore` with `score`, so a per-item row and the aggregate it
    /// belongs to can never be computed by different rules.
    public static func scoreItems(
        manifest: ASRBenchmarkManifest,
        predictions: [ASRBenchmarkPrediction]
    ) throws -> [ASRBenchmarkItemScore] {
        try manifest.validate(requireFrozen: true)
        var predictionsByID = [String: ASRBenchmarkPrediction]()
        for prediction in predictions {
            predictionsByID[prediction.id] = prediction
        }
        return try manifest.items.map { item in
            guard let prediction = predictionsByID[item.id] else {
                throw ASRBenchmarkScoringError.missingPrediction(item.id)
            }
            let raw = itemScore(
                reference: item.reference.verbatim,
                hypothesis: prediction.rawText,
                criticalSpans: item.reference.criticalSpans,
                languageDrift: prediction.languageDrift
            )
            let final = itemScore(
                reference: item.reference.clean,
                hypothesis: prediction.finalText,
                criticalSpans: item.reference.criticalSpans,
                languageDrift: prediction.languageDrift
            )
            return ASRBenchmarkItemScore(
                id: item.id,
                language: item.language.rawValue,
                rawWordErrors: raw.wordErrors,
                finalWordErrors: final.wordErrors,
                rawExact: raw.exact,
                inferenceMilliseconds: prediction.inferenceMilliseconds
            )
        }
    }

    public static func normalize(_ text: String) -> String {
        let canonical = text
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        var scalars = String.UnicodeScalarView()
        var previousWasSpace = true
        for scalar in canonical.unicodeScalars {
            let keep =
                CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "'"
            if keep {
                scalars.append(scalar)
                previousWasSpace = false
            } else if !previousWasSpace {
                scalars.append(" ")
                previousWasSpace = true
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}

private struct ItemScore {
    let wordErrors: ASREditCounts
    let characterErrors: ASREditCounts
    let exact: Bool
    let criticalSpanCount: Int
    let criticalSpanErrorCount: Int
    let languageDrift: Bool?
}

private struct EditCell {
    var cost: Int
    var substitutions: Int
    var deletions: Int
    var insertions: Int
}

private extension ASRBenchmarkScorer {
    static func itemScore(
        reference: String,
        hypothesis: String,
        criticalSpans: [ASRCriticalSpan],
        languageDrift: Bool?
    ) -> ItemScore {
        let normalizedReference = normalize(reference)
        let normalizedHypothesis = normalize(hypothesis)
        let referenceWords = normalizedReference.split(separator: " ").map(String.init)
        let hypothesisWords = normalizedHypothesis.split(separator: " ").map(String.init)
        let wordErrors = editCounts(referenceWords, hypothesisWords)
        let characterErrors = editCounts(
            Array(normalizedReference),
            Array(normalizedHypothesis)
        )
        let criticalSpanErrors = criticalSpans.filter { span in
            let alternatives = [span.expected] + span.acceptedAlternatives
            return !alternatives.contains {
                contains(
                    normalizedPhrase: normalize($0),
                    in: normalizedHypothesis
                )
            }
        }.count
        return ItemScore(
            wordErrors: wordErrors,
            characterErrors: characterErrors,
            exact: normalizedReference == normalizedHypothesis,
            criticalSpanCount: criticalSpans.count,
            criticalSpanErrorCount: criticalSpanErrors,
            languageDrift: languageDrift
        )
    }

    static func aggregate(_ scores: [ItemScore]) -> ASRBenchmarkSliceScore {
        var wordErrors = ASREditCounts()
        var characterErrors = ASREditCounts()
        var macroWER = 0.0
        var exactCount = 0
        var criticalSpanCount = 0
        var criticalSpanErrorCount = 0
        var languageDriftValues = [Bool]()
        for score in scores {
            wordErrors.add(score.wordErrors)
            characterErrors.add(score.characterErrors)
            macroWER += score.wordErrors.errorRate
            exactCount += score.exact ? 1 : 0
            criticalSpanCount += score.criticalSpanCount
            criticalSpanErrorCount += score.criticalSpanErrorCount
            if let languageDrift = score.languageDrift {
                languageDriftValues.append(languageDrift)
            }
        }
        return ASRBenchmarkSliceScore(
            itemCount: scores.count,
            wordErrors: wordErrors,
            characterErrors: characterErrors,
            macroWER: scores.isEmpty ? 0 : macroWER / Double(scores.count),
            exactMatchRate: scores.isEmpty ? 0 : Double(exactCount) / Double(scores.count),
            criticalSpanErrorRate:
                criticalSpanCount > 0
                ? Double(criticalSpanErrorCount) / Double(criticalSpanCount)
                : 0,
            languageDriftAssessedItemCount: languageDriftValues.count,
            languageDriftRate:
                languageDriftValues.isEmpty
                ? nil
                : Double(languageDriftValues.filter { $0 }.count)
                    / Double(languageDriftValues.count)
        )
    }

    static func aggregate(
        _ groups: [String: [ItemScore]]
    ) -> [String: ASRBenchmarkSliceScore] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0.key, aggregate($0.value)) })
    }

    static func latencyDistribution(
        _ samples: [Double]
    ) -> ASRBenchmarkLatencyDistribution? {
        let sorted = samples.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else {
            return nil
        }
        return ASRBenchmarkLatencyDistribution(
            sampleCount: sorted.count,
            minimumMilliseconds: sorted[0],
            p50Milliseconds: percentile(0.50, in: sorted),
            p95Milliseconds: percentile(0.95, in: sorted),
            p99Milliseconds: percentile(0.99, in: sorted),
            maximumMilliseconds: sorted[sorted.count - 1]
        )
    }

    static func percentile(_ fraction: Double, in sorted: [Double]) -> Double {
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else {
            return sorted[lower]
        }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    static func contains(normalizedPhrase: String, in text: String) -> Bool {
        let needle = normalizedPhrase.split(separator: " ")
        let haystack = text.split(separator: " ")
        guard !needle.isEmpty, needle.count <= haystack.count else {
            return false
        }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    static func editCounts<Element: Equatable>(
        _ reference: [Element],
        _ hypothesis: [Element]
    ) -> ASREditCounts {
        var previous = (0...hypothesis.count).map {
            EditCell(cost: $0, substitutions: 0, deletions: 0, insertions: $0)
        }
        for referenceIndex in reference.indices {
            var current = [
                EditCell(
                    cost: referenceIndex + 1,
                    substitutions: 0,
                    deletions: referenceIndex + 1,
                    insertions: 0
                )
            ]
            for hypothesisIndex in hypothesis.indices {
                if reference[referenceIndex] == hypothesis[hypothesisIndex] {
                    current.append(previous[hypothesisIndex])
                    continue
                }
                var substitution = previous[hypothesisIndex]
                substitution.cost += 1
                substitution.substitutions += 1
                var deletion = previous[hypothesisIndex + 1]
                deletion.cost += 1
                deletion.deletions += 1
                var insertion = current[hypothesisIndex]
                insertion.cost += 1
                insertion.insertions += 1
                let candidates = [substitution, deletion, insertion]
                current.append(
                    candidates.min {
                        ($0.cost, $0.substitutions, $0.deletions, $0.insertions)
                            < ($1.cost, $1.substitutions, $1.deletions, $1.insertions)
                    } ?? substitution
                )
            }
            previous = current
        }
        let final = previous[hypothesis.count]
        return ASREditCounts(
            substitutions: final.substitutions,
            deletions: final.deletions,
            insertions: final.insertions,
            referenceUnitCount: reference.count
        )
    }
}
