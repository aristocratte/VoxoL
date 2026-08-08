import FidelityKit
import Foundation
import ParakeetCore
import PersonalizationKit
import QwenPolisher
import TextProcessingKit

@main
private enum ReferenceEvalCLI {
    static func main() async throws {
        if CommandLine.arguments.contains("--merge-polisher") {
            try mergePolisherOutput(arguments: CommandLine.arguments)
            return
        }
        let arguments = try Arguments(CommandLine.arguments)
        try FileManager.default.createDirectory(
            at: arguments.outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: arguments.outputDirectory.path
        )

        let records = try loadRecords(from: arguments.recordsURL)
            .filter { $0.audio != nil }
        guard !records.isEmpty else {
            throw EvaluationError.noAudioRecords
        }

        writeProgress("phase=parakeet records=\(records.count)")
        let loadStarted = ContinuousClock.now
        let transcriber = try ParakeetTranscriber(
            modelsRoot: arguments.asrModelRoot,
            computeUnits: arguments.computeUnits,
            segmentation: arguments.segmentation,
            retryConfiguration: arguments.retryConfiguration
        )
        let asrLoadMilliseconds = loadStarted.duration(to: .now).milliseconds
        var parakeetResults = [ParakeetResult]()
        parakeetResults.reserveCapacity(records.count)

        for (index, record) in records.enumerated() {
            let result = evaluateParakeet(
                record,
                recordsDirectory: arguments.recordsURL.deletingLastPathComponent(),
                transcriber: transcriber
            )
            parakeetResults.append(result)
            writeProgress(
                "phase=parakeet processed=\(index + 1)/\(records.count) "
                    + "success=\(result.error == nil) inference_ms=\(result.inferenceMilliseconds)"
            )
        }
        try writeJSONLines(
            parakeetResults,
            to: arguments.outputDirectory.appendingPathComponent("parakeet-results.jsonl")
        )
        if arguments.parakeetOnly {
            writeProgress("complete phase=parakeet records=\(records.count)")
            return
        }

        writeProgress("phase=qwen records=\(parakeetResults.count)")
        guard let qwenModelRoot = arguments.qwenModelRoot else {
            throw EvaluationError.invalidArguments
        }
        let qwen = QwenPolisherRuntime(modelRoot: qwenModelRoot)
        let warmupStarted = ContinuousClock.now
        try await qwen.warmUp()
        let qwenWarmupMilliseconds = warmupStarted.duration(to: .now).milliseconds
        var pipelineResults = [PipelineResult]()
        pipelineResults.reserveCapacity(parakeetResults.count)

        for (index, asrResult) in parakeetResults.enumerated() {
            let result = await evaluatePipeline(asrResult, runtime: qwen)
            pipelineResults.append(result)
            writeProgress(
                "phase=qwen processed=\(index + 1)/\(parakeetResults.count) "
                    + "route=\(result.route) inference_ms=\(result.qwenMilliseconds)"
            )
        }
        try writeJSONLines(
            pipelineResults,
            to: arguments.outputDirectory.appendingPathComponent("pipeline-results.jsonl")
        )

        let report = buildReport(
            sourceCount: records.count,
            asrLoadMilliseconds: asrLoadMilliseconds,
            qwenWarmupMilliseconds: qwenWarmupMilliseconds,
            results: pipelineResults
        )
        try writeJSON(
            report,
            to: arguments.outputDirectory.appendingPathComponent("report.json")
        )
        writeProgress(
            "complete records=\(records.count) asr_failures=\(report.asrFailureCount) "
                + "qwen_acceptances=\(report.overall.qwenAcceptedCount)"
        )
    }
}

private struct Arguments {
    let recordsURL: URL
    let asrModelRoot: URL
    let qwenModelRoot: URL?
    let outputDirectory: URL
    let computeUnits: ParakeetComputeUnits
    let segmentation: ParakeetSegmentationConfiguration
    let retryConfiguration: ParakeetRetryConfiguration?
    let parakeetOnly: Bool

    init(_ arguments: [String]) throws {
        guard
            let records = Self.value(after: "--records", in: arguments),
            let asrModel = Self.value(after: "--asr-model", in: arguments),
            let output = Self.value(after: "--output", in: arguments)
        else {
            throw EvaluationError.invalidArguments
        }
        parakeetOnly = arguments.contains("--parakeet-only")
        let qwenModel = Self.value(after: "--qwen-model", in: arguments)
        guard parakeetOnly || qwenModel != nil else {
            throw EvaluationError.invalidArguments
        }
        let requestedComputeUnits = Self.value(after: "--compute-units", in: arguments) ?? "all"
        guard let computeUnits = ParakeetComputeUnits(rawValue: requestedComputeUnits) else {
            throw EvaluationError.invalidArguments
        }
        let productionSegmentation = ParakeetSegmentationConfiguration.production
        let maximumSegmentSeconds =
            Self.value(after: "--segment-seconds", in: arguments).flatMap(Double.init)
            ?? productionSegmentation.maximumSegmentDurationSeconds
        let overlapSeconds =
            Self.value(after: "--overlap-seconds", in: arguments).flatMap(Double.init)
            ?? productionSegmentation.overlapDurationSeconds
        let segmentationThresholdSeconds =
            Self.value(after: "--segmentation-threshold-seconds", in: arguments)
            .flatMap(Double.init)
            ?? (Self.value(after: "--segment-seconds", in: arguments) == nil
                ? productionSegmentation.segmentationThresholdDurationSeconds
                : maximumSegmentSeconds)
        guard
            maximumSegmentSeconds.isFinite,
            maximumSegmentSeconds > 0,
            overlapSeconds.isFinite,
            overlapSeconds >= 0,
            overlapSeconds < maximumSegmentSeconds,
            segmentationThresholdSeconds.isFinite,
            segmentationThresholdSeconds >= maximumSegmentSeconds
        else {
            throw EvaluationError.invalidArguments
        }
        recordsURL = URL(fileURLWithPath: records)
        asrModelRoot = URL(fileURLWithPath: asrModel, isDirectory: true)
        qwenModelRoot = qwenModel.map { URL(fileURLWithPath: $0, isDirectory: true) }
        outputDirectory = URL(fileURLWithPath: output, isDirectory: true)
        self.computeUnits = computeUnits
        segmentation = ParakeetSegmentationConfiguration(
            maximumSegmentDurationSeconds: maximumSegmentSeconds,
            overlapDurationSeconds: overlapSeconds,
            segmentationThresholdDurationSeconds: segmentationThresholdSeconds
        )
        retryConfiguration =
            arguments.contains("--disable-confidence-retry")
            ? nil : .production
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }
}

private enum EvaluationError: LocalizedError {
    case invalidArguments
    case noAudioRecords
    case unsafeAudioPath

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            """
            Usage: voxol-reference-eval --records <records.jsonl> \
            --asr-model <directory> [--qwen-model <directory>] --output <directory> \
            [--compute-units ane|gpu|cpu|all] [--segment-seconds <seconds>] \
            [--overlap-seconds <seconds>] [--segmentation-threshold-seconds <seconds>] \
            [--disable-confidence-retry] [--parakeet-only]

            Merge: voxol-reference-eval --merge-polisher \
            --parakeet-results <jsonl> --polisher-output <json> --output <directory>
            """
        case .noAudioRecords:
            "The reference file contains no audio records."
        case .unsafeAudioPath:
            "A reference audio path resolves outside the records directory."
        }
    }
}

private struct SourceRecord: Decodable {
    let id: String
    let language: String?
    let detectedLanguage: String?
    let app: String?
    let audio: SourceAudio?
    let texts: SourceTexts

    enum CodingKeys: String, CodingKey {
        case id, language, app, audio, texts
        case detectedLanguage = "detected_language"
    }

    var referenceLanguage: String {
        nonEmpty(detectedLanguage) ?? nonEmpty(language) ?? "unknown"
    }

    var referenceRawText: String {
        nonEmpty(texts.asr) ?? ""
    }

    var referenceFinalText: String {
        nonEmpty(texts.pasted)
            ?? nonEmpty(texts.serverFinalized)
            ?? nonEmpty(texts.formatted)
            ?? ""
    }
}

private struct SourceAudio: Decodable {
    let path: String
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case path
        case durationSeconds = "duration_s"
    }
}

private struct SourceTexts: Decodable {
    let asr: String?
    let formatted: String?
    let serverFinalized: String?
    let pasted: String?

    enum CodingKeys: String, CodingKey {
        case asr, formatted, pasted
        case serverFinalized = "server_finalized"
    }
}

private struct TextComparison: Codable {
    let exactMatch: Bool
    let wordNormalizedExactMatch: Bool
    let normalizedEditDistance: Double
    let wordErrorRate: Double
}

private struct ParakeetResult: Codable {
    let id: String
    let language: String
    let appCategory: String
    let audioPath: String
    let audioDurationSeconds: Double
    let referenceRawText: String
    let referenceFinalText: String
    let parakeetText: String
    let inferenceMilliseconds: Int
    let realtimeFactor: Double
    let confidence: TranscriptionConfidence?
    let inferenceAttemptCount: Int
    let usedFallbackSegmentation: Bool
    let versusWisprASR: TextComparison?
    let versusWisprFinal: TextComparison?
    let features: [String]
    let error: String?
}

private struct PipelineResult: Codable {
    let id: String
    let language: String
    let appCategory: String
    let audioDurationSeconds: Double
    let referenceRawText: String
    let referenceFinalText: String
    let parakeetText: String
    let deterministicText: String
    let qwenCandidateText: String?
    let pipelineText: String
    let processingLanguage: String?
    let profile: String?
    let route: String
    let rejectionReason: String?
    let failure: String?
    let asrMilliseconds: Int
    let qwenMilliseconds: Int
    let promptTokens: Int
    let outputTokens: Int
    let protectedTokenCount: Int
    let parakeetVersusWisprASR: TextComparison?
    let parakeetVersusWisprFinal: TextComparison?
    let deterministicVersusWisprFinal: TextComparison?
    let pipelineVersusWisprFinal: TextComparison?
    let features: [String]
}

private struct EvaluationReport: Codable {
    let schemaVersion: Int
    let generatedAtUTC: String
    let referenceCaveat: String
    let sourceRecordCount: Int
    let completedRecordCount: Int
    let asrFailureCount: Int
    let asrLoadMilliseconds: Int
    let qwenWarmupMilliseconds: Int
    let overall: GroupSummary
    let byLanguage: [String: GroupSummary]
    let byDuration: [String: GroupSummary]
    let byFeature: [String: GroupSummary]
    let rejectionReasons: [String: Int]
    let failures: [String: Int]
    let worstParakeetVersusWisprASR: [ScoredIdentifier]
    let worstPipelineRegressions: [ScoredIdentifier]
}

private struct GroupSummary: Codable {
    let recordCount: Int
    let audioDurationSeconds: Double
    let parakeetMeanMilliseconds: Double
    let parakeetP50Milliseconds: Int
    let parakeetP95Milliseconds: Int
    let parakeetMeanRealtimeFactor: Double
    let qwenAttemptedCount: Int
    let qwenAcceptedCount: Int
    let qwenAcceptanceRate: Double
    let qwenMeanMilliseconds: Double
    let qwenP50Milliseconds: Int
    let qwenP95Milliseconds: Int
    let wisprASRVersusWisprFinalMeanWER: Double?
    let wisprASRVersusWisprFinalMeanEditDistance: Double?
    let parakeetVersusWisprASRMeanWER: Double?
    let parakeetVersusWisprFinalMeanWER: Double?
    let parakeetVersusWisprFinalMeanEditDistance: Double?
    let deterministicVersusWisprFinalMeanEditDistance: Double?
    let pipelineVersusWisprFinalMeanWER: Double?
    let pipelineVersusWisprFinalMeanEditDistance: Double?
    let pipelineExactMatchRate: Double?
    let pipelineWordNormalizedExactMatchRate: Double?
    let pipelineImprovedCount: Int
    let pipelineUnchangedCount: Int
    let pipelineWorsenedCount: Int
    let acceptedQwenWorsenedCount: Int
    let qwenImprovedOverDeterministicCount: Int
    let qwenUnchangedOverDeterministicCount: Int
    let qwenWorsenedOverDeterministicCount: Int
    let referenceNumberTokenCount: Int
    let parakeetNumberTokenRecall: Double?
    let pipelineNumberTokenRecall: Double?
}

private struct ScoredIdentifier: Codable {
    let id: String
    let score: Double
}

private struct PolisherSuiteOutput: Decodable {
    let warmupDurationMilliseconds: Int
    let results: [PolisherSuiteResult]
}

private struct PolisherSuiteResult: Decodable {
    let id: String
    let candidate: String
    let normalized: String
    let finalText: String
    let accepted: Bool
    let rejection: String?
    let failure: String?
    let durationMilliseconds: Int
    let promptTokens: Int
    let outputTokens: Int
    let processingLanguage: String
    let profile: String
    let protectedTokenCount: Int
}

private func loadRecords(from url: URL) throws -> [SourceRecord] {
    let decoder = JSONDecoder()
    return try String(contentsOf: url, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { try decoder.decode(SourceRecord.self, from: Data($0.utf8)) }
}

private func mergePolisherOutput(arguments: [String]) throws {
    guard
        let parakeetPath = argumentValue(after: "--parakeet-results", in: arguments),
        let polisherPath = argumentValue(after: "--polisher-output", in: arguments),
        let outputPath = argumentValue(after: "--output", in: arguments)
    else {
        throw EvaluationError.invalidArguments
    }
    let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(
        at: outputDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: outputDirectory.path
    )

    let decoder = JSONDecoder()
    let parakeetResults = try String(
        contentsOf: URL(fileURLWithPath: parakeetPath),
        encoding: .utf8
    )
    .split(whereSeparator: \.isNewline)
    .map { try decoder.decode(ParakeetResult.self, from: Data($0.utf8)) }
    let polisherOutput = try decoder.decode(
        PolisherSuiteOutput.self,
        from: Data(contentsOf: URL(fileURLWithPath: polisherPath))
    )
    let polisherByID = Dictionary(
        uniqueKeysWithValues: polisherOutput.results.map { ($0.id, $0) }
    )
    let results = parakeetResults.map { asr -> PipelineResult in
        guard let polished = polisherByID[asr.id] else {
            return pipelineFailure(asr, failure: "missingPolisherResult")
        }
        return PipelineResult(
            id: asr.id,
            language: asr.language,
            appCategory: asr.appCategory,
            audioDurationSeconds: asr.audioDurationSeconds,
            referenceRawText: asr.referenceRawText,
            referenceFinalText: asr.referenceFinalText,
            parakeetText: asr.parakeetText,
            deterministicText: polished.normalized,
            qwenCandidateText: nonEmpty(polished.candidate),
            pipelineText: polished.finalText,
            processingLanguage: polished.processingLanguage,
            profile: polished.profile,
            route: polished.accepted ? "qwen" : "deterministicFallback",
            rejectionReason: polished.rejection,
            failure: polished.failure,
            asrMilliseconds: asr.inferenceMilliseconds,
            qwenMilliseconds: polished.durationMilliseconds,
            promptTokens: polished.promptTokens,
            outputTokens: polished.outputTokens,
            protectedTokenCount: polished.protectedTokenCount,
            parakeetVersusWisprASR: asr.versusWisprASR,
            parakeetVersusWisprFinal: asr.versusWisprFinal,
            deterministicVersusWisprFinal: comparison(
                output: polished.normalized,
                reference: asr.referenceFinalText
            ),
            pipelineVersusWisprFinal: comparison(
                output: polished.finalText,
                reference: asr.referenceFinalText
            ),
            features: features(
                raw: asr.referenceRawText,
                final: asr.referenceFinalText
            )
        )
    }
    try writeJSONLines(
        results,
        to: outputDirectory.appendingPathComponent("pipeline-results.jsonl")
    )
    try writeJSON(
        buildReport(
            sourceCount: parakeetResults.count,
            asrLoadMilliseconds: 0,
            qwenWarmupMilliseconds: polisherOutput.warmupDurationMilliseconds,
            results: results
        ),
        to: outputDirectory.appendingPathComponent("report.json")
    )
    writeProgress("complete phase=merge records=\(results.count)")
}

private func argumentValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
    else {
        return nil
    }
    return arguments[index + 1]
}

private func evaluateParakeet(
    _ record: SourceRecord,
    recordsDirectory: URL,
    transcriber: ParakeetTranscriber
) -> ParakeetResult {
    let relativePath = record.audio?.path ?? ""
    let base = recordsDirectory.standardizedFileURL
    let audioURL = base.appendingPathComponent(relativePath).standardizedFileURL
    guard audioURL.path.hasPrefix(base.path + "/") else {
        return failedParakeetResult(
            record, path: relativePath, error: EvaluationError.unsafeAudioPath)
    }

    do {
        let transcription = try transcriber.transcribe(audioURL: audioURL)
        return ParakeetResult(
            id: record.id,
            language: record.referenceLanguage,
            appCategory: appContext(for: record.app).category,
            audioPath: relativePath,
            audioDurationSeconds: transcription.audioDurationSeconds,
            referenceRawText: record.referenceRawText,
            referenceFinalText: record.referenceFinalText,
            parakeetText: transcription.text,
            inferenceMilliseconds: Int(transcription.inferenceDurationSeconds * 1_000),
            realtimeFactor: transcription.rtfx,
            confidence: transcription.confidence,
            inferenceAttemptCount: transcription.inferenceAttemptCount,
            usedFallbackSegmentation:
                transcription.usedFallbackSegmentation,
            versusWisprASR: comparison(
                output: transcription.text,
                reference: record.referenceRawText
            ),
            versusWisprFinal: comparison(
                output: transcription.text,
                reference: record.referenceFinalText
            ),
            features: features(
                raw: record.referenceRawText,
                final: record.referenceFinalText
            ),
            error: nil
        )
    } catch {
        return failedParakeetResult(record, path: relativePath, error: error)
    }
}

private func failedParakeetResult(
    _ record: SourceRecord,
    path: String,
    error: Error
) -> ParakeetResult {
    ParakeetResult(
        id: record.id,
        language: record.referenceLanguage,
        appCategory: appContext(for: record.app).category,
        audioPath: path,
        audioDurationSeconds: record.audio?.durationSeconds ?? 0,
        referenceRawText: record.referenceRawText,
        referenceFinalText: record.referenceFinalText,
        parakeetText: "",
        inferenceMilliseconds: 0,
        realtimeFactor: 0,
        confidence: nil,
        inferenceAttemptCount: 0,
        usedFallbackSegmentation: false,
        versusWisprASR: nil,
        versusWisprFinal: nil,
        features: features(raw: record.referenceRawText, final: record.referenceFinalText),
        error: String(describing: type(of: error))
    )
}

private func evaluatePipeline(
    _ asr: ParakeetResult,
    runtime: QwenPolisherRuntime
) async -> PipelineResult {
    guard asr.error == nil, !asr.parakeetText.isEmpty else {
        return pipelineFailure(asr, failure: "asrUnavailable")
    }

    let context = appContext(forCategory: asr.appCategory)
    let preferredLanguage = TextLanguage(rawValue: asr.language)
    let preparation = DeterministicTextProcessor.prepare(
        TextProcessingRequest(
            rawTranscript: asr.parakeetText,
            preferredLanguage: preferredLanguage,
            context: TextProcessingContext(
                applicationName: context.applicationName
            ),
            preferences: TextProcessingPreferences(
                fastPathEnabled: false,
                profile: context.profile
            )
        )
    )
    let started = ContinuousClock.now
    do {
        let generated = try await runtime.polish(
            preparation,
            timeout: generationTimeout(for: preparation)
        )
        let decision = FidelityValidator.validate(
            candidate: generated.text,
            against: preparation
        )
        return PipelineResult(
            id: asr.id,
            language: asr.language,
            appCategory: asr.appCategory,
            audioDurationSeconds: asr.audioDurationSeconds,
            referenceRawText: asr.referenceRawText,
            referenceFinalText: asr.referenceFinalText,
            parakeetText: asr.parakeetText,
            deterministicText: preparation.normalizedText,
            qwenCandidateText: generated.text,
            pipelineText: decision.text,
            processingLanguage: preparation.language.rawValue,
            profile: preparation.profile.rawValue,
            route: decision.usedModelOutput ? "qwen" : "deterministicFallback",
            rejectionReason: decision.rejectionReason?.rawValue,
            failure: nil,
            asrMilliseconds: asr.inferenceMilliseconds,
            qwenMilliseconds: Int(generated.durationSeconds * 1_000),
            promptTokens: generated.promptTokenCount,
            outputTokens: generated.outputTokenCount,
            protectedTokenCount: preparation.protectedTokens.count,
            parakeetVersusWisprASR: asr.versusWisprASR,
            parakeetVersusWisprFinal: asr.versusWisprFinal,
            deterministicVersusWisprFinal: comparison(
                output: preparation.normalizedText,
                reference: asr.referenceFinalText
            ),
            pipelineVersusWisprFinal: comparison(
                output: decision.text,
                reference: asr.referenceFinalText
            ),
            features: asr.features
        )
    } catch {
        return PipelineResult(
            id: asr.id,
            language: asr.language,
            appCategory: asr.appCategory,
            audioDurationSeconds: asr.audioDurationSeconds,
            referenceRawText: asr.referenceRawText,
            referenceFinalText: asr.referenceFinalText,
            parakeetText: asr.parakeetText,
            deterministicText: preparation.normalizedText,
            qwenCandidateText: nil,
            pipelineText: preparation.normalizedText,
            processingLanguage: preparation.language.rawValue,
            profile: preparation.profile.rawValue,
            route: "deterministicFallback",
            rejectionReason: nil,
            failure: String(describing: type(of: error)),
            asrMilliseconds: asr.inferenceMilliseconds,
            qwenMilliseconds: started.duration(to: .now).milliseconds,
            promptTokens: 0,
            outputTokens: 0,
            protectedTokenCount: preparation.protectedTokens.count,
            parakeetVersusWisprASR: asr.versusWisprASR,
            parakeetVersusWisprFinal: asr.versusWisprFinal,
            deterministicVersusWisprFinal: comparison(
                output: preparation.normalizedText,
                reference: asr.referenceFinalText
            ),
            pipelineVersusWisprFinal: comparison(
                output: preparation.normalizedText,
                reference: asr.referenceFinalText
            ),
            features: asr.features
        )
    }
}

private func pipelineFailure(_ asr: ParakeetResult, failure: String) -> PipelineResult {
    PipelineResult(
        id: asr.id,
        language: asr.language,
        appCategory: asr.appCategory,
        audioDurationSeconds: asr.audioDurationSeconds,
        referenceRawText: asr.referenceRawText,
        referenceFinalText: asr.referenceFinalText,
        parakeetText: asr.parakeetText,
        deterministicText: "",
        qwenCandidateText: nil,
        pipelineText: "",
        processingLanguage: nil,
        profile: nil,
        route: "unavailable",
        rejectionReason: nil,
        failure: failure,
        asrMilliseconds: asr.inferenceMilliseconds,
        qwenMilliseconds: 0,
        promptTokens: 0,
        outputTokens: 0,
        protectedTokenCount: 0,
        parakeetVersusWisprASR: asr.versusWisprASR,
        parakeetVersusWisprFinal: asr.versusWisprFinal,
        deterministicVersusWisprFinal: nil,
        pipelineVersusWisprFinal: nil,
        features: asr.features
    )
}

private func buildReport(
    sourceCount: Int,
    asrLoadMilliseconds: Int,
    qwenWarmupMilliseconds: Int,
    results: [PipelineResult]
) -> EvaluationReport {
    let completed = results.filter { $0.parakeetVersusWisprFinal != nil }
    let languages = Dictionary(grouping: completed, by: \.language)
    let durations = Dictionary(grouping: completed) { durationBucket($0.audioDurationSeconds) }
    let allFeatures = Set(completed.flatMap(\.features))
    let features = Dictionary(
        uniqueKeysWithValues: allFeatures.sorted().map { feature in
            (feature, summarize(completed.filter { $0.features.contains(feature) }))
        }
    )
    let rejectionReasons = counts(
        completed.compactMap(\.rejectionReason)
    )
    let failures = counts(
        results.compactMap(\.failure)
    )
    let worstASR = completed.compactMap { result -> ScoredIdentifier? in
        guard let score = result.parakeetVersusWisprASR?.wordErrorRate else {
            return nil
        }
        return ScoredIdentifier(id: result.id, score: score)
    }
    .sorted { $0.score > $1.score }
    .prefix(12)
    let regressions = completed.compactMap { result -> ScoredIdentifier? in
        guard
            let raw = result.parakeetVersusWisprFinal?.normalizedEditDistance,
            let pipeline = result.pipelineVersusWisprFinal?.normalizedEditDistance,
            pipeline > raw
        else {
            return nil
        }
        return ScoredIdentifier(id: result.id, score: pipeline - raw)
    }
    .sorted { $0.score > $1.score }
    .prefix(12)

    return EvaluationReport(
        schemaVersion: 1,
        generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
        referenceCaveat:
            "Wispr Flow ASR and pasted AI output are teacher references, not human-reviewed truth.",
        sourceRecordCount: sourceCount,
        completedRecordCount: completed.count,
        asrFailureCount: results.count - completed.count,
        asrLoadMilliseconds: asrLoadMilliseconds,
        qwenWarmupMilliseconds: qwenWarmupMilliseconds,
        overall: summarize(completed),
        byLanguage: languages.mapValues(summarize),
        byDuration: durations.mapValues(summarize),
        byFeature: features,
        rejectionReasons: rejectionReasons,
        failures: failures,
        worstParakeetVersusWisprASR: Array(worstASR),
        worstPipelineRegressions: Array(regressions)
    )
}

private func summarize(_ results: [PipelineResult]) -> GroupSummary {
    let asrDurations = results.map(\.asrMilliseconds).filter { $0 > 0 }.sorted()
    let qwenResults = results.filter { $0.qwenMilliseconds > 0 }
    let qwenDurations = qwenResults.map(\.qwenMilliseconds).sorted()
    let qwenAccepted = qwenResults.count { $0.route == "qwen" }
    let wisprComparisons = results.compactMap {
        comparison(output: $0.referenceRawText, reference: $0.referenceFinalText)
    }
    let rawASRComparisons = results.compactMap(\.parakeetVersusWisprASR)
    let rawFinalComparisons = results.compactMap(\.parakeetVersusWisprFinal)
    let deterministicComparisons = results.compactMap(\.deterministicVersusWisprFinal)
    let pipelineComparisons = results.compactMap(\.pipelineVersusWisprFinal)
    var improved = 0
    var unchanged = 0
    var worsened = 0
    var acceptedAndWorsened = 0
    var qwenImprovedOverDeterministic = 0
    var qwenUnchangedOverDeterministic = 0
    var qwenWorsenedOverDeterministic = 0
    var numberTokenTotal = 0
    var parakeetNumbersRetained = 0
    var pipelineNumbersRetained = 0

    for result in results {
        if let raw = result.parakeetVersusWisprFinal?.normalizedEditDistance,
            let pipeline = result.pipelineVersusWisprFinal?.normalizedEditDistance
        {
            if pipeline + 0.000_001 < raw {
                improved += 1
            } else if pipeline > raw + 0.000_001 {
                worsened += 1
                acceptedAndWorsened += result.route == "qwen" ? 1 : 0
            } else {
                unchanged += 1
            }
        }
        if result.route == "qwen",
            let deterministic = result.deterministicVersusWisprFinal?.normalizedEditDistance,
            let pipeline = result.pipelineVersusWisprFinal?.normalizedEditDistance
        {
            if pipeline + 0.000_001 < deterministic {
                qwenImprovedOverDeterministic += 1
            } else if pipeline > deterministic + 0.000_001 {
                qwenWorsenedOverDeterministic += 1
            } else {
                qwenUnchangedOverDeterministic += 1
            }
        }
        let referenceNumbers = numberTokens(in: result.referenceFinalText)
        numberTokenTotal += referenceNumbers.count
        parakeetNumbersRetained += referenceNumbers.count {
            result.parakeetText.contains($0)
        }
        pipelineNumbersRetained += referenceNumbers.count {
            result.pipelineText.contains($0)
        }
    }

    return GroupSummary(
        recordCount: results.count,
        audioDurationSeconds: results.map(\.audioDurationSeconds).reduce(0, +),
        parakeetMeanMilliseconds: mean(asrDurations),
        parakeetP50Milliseconds: percentile(0.50, values: asrDurations),
        parakeetP95Milliseconds: percentile(0.95, values: asrDurations),
        parakeetMeanRealtimeFactor: mean(
            results.map {
                $0.asrMilliseconds > 0
                    ? $0.audioDurationSeconds / (Double($0.asrMilliseconds) / 1_000)
                    : 0
            }.filter { $0 > 0 }),
        qwenAttemptedCount: qwenResults.count,
        qwenAcceptedCount: qwenAccepted,
        qwenAcceptanceRate: ratio(qwenAccepted, qwenResults.count),
        qwenMeanMilliseconds: mean(qwenDurations),
        qwenP50Milliseconds: percentile(0.50, values: qwenDurations),
        qwenP95Milliseconds: percentile(0.95, values: qwenDurations),
        wisprASRVersusWisprFinalMeanWER: meanOptional(
            wisprComparisons.map(\.wordErrorRate)
        ),
        wisprASRVersusWisprFinalMeanEditDistance: meanOptional(
            wisprComparisons.map(\.normalizedEditDistance)
        ),
        parakeetVersusWisprASRMeanWER: meanOptional(
            rawASRComparisons.map(\.wordErrorRate)
        ),
        parakeetVersusWisprFinalMeanWER: meanOptional(
            rawFinalComparisons.map(\.wordErrorRate)
        ),
        parakeetVersusWisprFinalMeanEditDistance: meanOptional(
            rawFinalComparisons.map(\.normalizedEditDistance)
        ),
        deterministicVersusWisprFinalMeanEditDistance: meanOptional(
            deterministicComparisons.map(\.normalizedEditDistance)
        ),
        pipelineVersusWisprFinalMeanWER: meanOptional(
            pipelineComparisons.map(\.wordErrorRate)
        ),
        pipelineVersusWisprFinalMeanEditDistance: meanOptional(
            pipelineComparisons.map(\.normalizedEditDistance)
        ),
        pipelineExactMatchRate: meanOptional(
            pipelineComparisons.map { $0.exactMatch ? 1 : 0 }
        ),
        pipelineWordNormalizedExactMatchRate: meanOptional(
            pipelineComparisons.map { $0.wordNormalizedExactMatch ? 1 : 0 }
        ),
        pipelineImprovedCount: improved,
        pipelineUnchangedCount: unchanged,
        pipelineWorsenedCount: worsened,
        acceptedQwenWorsenedCount: acceptedAndWorsened,
        qwenImprovedOverDeterministicCount: qwenImprovedOverDeterministic,
        qwenUnchangedOverDeterministicCount: qwenUnchangedOverDeterministic,
        qwenWorsenedOverDeterministicCount: qwenWorsenedOverDeterministic,
        referenceNumberTokenCount: numberTokenTotal,
        parakeetNumberTokenRecall: numberTokenTotal > 0
            ? Double(parakeetNumbersRetained) / Double(numberTokenTotal) : nil,
        pipelineNumberTokenRecall: numberTokenTotal > 0
            ? Double(pipelineNumbersRetained) / Double(numberTokenTotal) : nil
    )
}

private func comparison(output: String, reference: String) -> TextComparison? {
    guard !reference.isEmpty else {
        return nil
    }
    let outputSurface = normalizedWhitespace(output)
    let referenceSurface = normalizedWhitespace(reference)
    let outputWords = words(in: output)
    let referenceWords = words(in: reference)
    return TextComparison(
        exactMatch: outputSurface == referenceSurface,
        wordNormalizedExactMatch: outputWords == referenceWords,
        normalizedEditDistance: normalizedDistance(
            Array(outputSurface),
            Array(referenceSurface)
        ),
        wordErrorRate: normalizedDistance(outputWords, referenceWords)
    )
}

private func normalizedDistance<T: Equatable>(_ output: [T], _ reference: [T]) -> Double {
    let denominator = max(1, output.count, reference.count)
    return Double(editDistance(output, reference)) / Double(denominator)
}

private func editDistance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
    var previous = Array(0...rhs.count)
    for (lhsIndex, lhsValue) in lhs.enumerated() {
        var current = [lhsIndex + 1]
        current.reserveCapacity(rhs.count + 1)
        for (rhsIndex, rhsValue) in rhs.enumerated() {
            current.append(
                min(
                    current[rhsIndex] + 1,
                    previous[rhsIndex + 1] + 1,
                    previous[rhsIndex] + (lhsValue == rhsValue ? 0 : 1)
                )
            )
        }
        previous = current
    }
    return previous[rhs.count]
}

private func words(in text: String) -> [String] {
    text.precomposedStringWithCanonicalMapping.lowercased()
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
}

private func normalizedWhitespace(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

private func numberTokens(in text: String) -> [String] {
    regexMatches(#"\p{N}+(?:[.,:]\p{N}+)*"#, in: text)
}

private func features(raw: String, final: String) -> [String] {
    let combined = raw + " " + final
    let lower = combined.lowercased()
    var result = [String]()
    if !numberTokens(in: combined).isEmpty {
        result.append("number")
    }
    if lower.contains("http") || lower.contains(".com") || lower.contains("--")
        || lower.contains("npm ") || lower.contains("git ") || lower.contains("swift")
        || lower.contains("json") || lower.contains("/src") || lower.contains("code review")
    {
        result.append("developer")
    }
    if raw.contains("\n") || final.contains("\n")
        || !regexMatches(#"(?m)^\s*(?:[-•*]|\d+[.)])\s+"#, in: raw).isEmpty
        || !regexMatches(#"(?m)^\s*(?:[-•*]|\d+[.)])\s+"#, in: final).isEmpty
    {
        result.append("list")
    }
    if final.contains("?") {
        result.append("question")
    }
    let correctionMarkers = [
        "pardon", "enfin", "plutôt", "je veux dire", "non ", "sorry", "rather", "i mean",
    ]
    if correctionMarkers.contains(where: lower.contains) {
        result.append("self_correction")
    }
    return result
}

private struct AppContext {
    let category: String
    let applicationName: String
    let profile: WritingProfile
}

private func appContext(for app: String?) -> AppContext {
    let value = app?.lowercased() ?? ""
    if value.contains("codex") || value.contains("browser") || value.contains("dia") {
        return AppContext(category: "prompt", applicationName: "Codex", profile: .prompt)
    }
    if value.contains("notes") || value.contains("linear") || value.contains("open-design")
        || value.contains("timenear")
    {
        return AppContext(category: "document", applicationName: "Notes", profile: .document)
    }
    if value.contains("wispr") {
        return AppContext(category: "chat", applicationName: "Wispr Flow", profile: .chat)
    }
    return AppContext(category: "unknown", applicationName: "Unknown", profile: .automatic)
}

private func appContext(forCategory category: String) -> AppContext {
    switch category {
    case "prompt":
        AppContext(category: category, applicationName: "Codex", profile: .prompt)
    case "document":
        AppContext(category: category, applicationName: "Notes", profile: .document)
    case "chat":
        AppContext(category: category, applicationName: "Wispr Flow", profile: .chat)
    default:
        AppContext(category: "unknown", applicationName: "Unknown", profile: .automatic)
    }
}

private func generationTimeout(for preparation: DeterministicPreparation) -> Duration {
    let wordCount = preparation.promptText.split { !$0.isLetter && !$0.isNumber }.count
    if wordCount <= 12 {
        return .milliseconds(2_500)
    }
    if wordCount <= 40 {
        return .milliseconds(4_500)
    }
    return .seconds(6)
}

private func durationBucket(_ duration: Double) -> String {
    switch duration {
    case ..<5:
        "under_5s"
    case ..<15:
        "5_to_15s"
    case ..<30:
        "15_to_30s"
    default:
        "30s_and_over"
    }
}

private func counts(_ values: [String]) -> [String: Int] {
    values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
}

private func ratio(_ numerator: Int, _ denominator: Int) -> Double {
    denominator == 0 ? 0 : Double(numerator) / Double(denominator)
}

private func mean(_ values: [Int]) -> Double {
    values.isEmpty ? 0 : Double(values.reduce(0, +)) / Double(values.count)
}

private func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

private func meanOptional(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : mean(values)
}

private func percentile(_ requested: Double, values: [Int]) -> Int {
    guard !values.isEmpty else {
        return 0
    }
    let index = Int((Double(values.count - 1) * requested).rounded())
    return values[index]
}

private func regexMatches(_ pattern: String, in input: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    return regex.matches(in: input, range: range).compactMap { match in
        Range(match.range, in: input).map { String(input[$0]) }
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else {
        return nil
    }
    return value
}

private func writeJSONLines<T: Encodable>(_ values: [T], to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let lines = try values.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
    )
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: url.path
    )
}

private func writeProgress(_ value: String) {
    FileHandle.standardError.write(Data((value + "\n").utf8))
}

private extension Duration {
    var milliseconds: Int {
        let components = components
        let value =
            Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return Int(value)
    }
}
