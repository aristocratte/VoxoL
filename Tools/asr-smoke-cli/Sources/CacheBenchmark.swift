import AVFoundation
import CryptoKit
import Foundation
import ParakeetCore

/// A file-replay microbenchmark, not a microphone or destination-insertion test.
enum CacheBenchmark {
    static func run(_ arguments: [String]) async throws {
        guard arguments.count >= 4, arguments[0] == "--model-root",
            arguments[2] == "--manifest"
        else { throw Failure.usage }
        let manifestURL = URL(fileURLWithPath: arguments[3])
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: manifestURL))
        guard (2...40).contains(manifest.repetitions), !manifest.samples.isEmpty else {
            throw Failure.usage
        }
        let previewMode =
            ProcessInfo.processInfo.environment["VOXOL_ASR_CACHE_BENCHMARK_PREVIEW"] == "1"
        let productionSegmentation = ParakeetSegmentationConfiguration.production
        let thresholdEnvironmentKey =
            "VOXOL_ASR_CACHE_BENCHMARK_SEGMENTATION_THRESHOLD_SECONDS"
        let thresholdSeconds =
            Double(ProcessInfo.processInfo.environment[thresholdEnvironmentKey] ?? "")
            ?? productionSegmentation.segmentationThresholdDurationSeconds
        guard
            thresholdSeconds.isFinite,
            thresholdSeconds >= productionSegmentation.maximumSegmentDurationSeconds
        else { throw Failure.usage }
        let segmentation = ParakeetSegmentationConfiguration(
            maximumSegmentDurationSeconds: productionSegmentation.maximumSegmentDurationSeconds,
            overlapDurationSeconds: productionSegmentation.overlapDurationSeconds,
            segmentationThresholdDurationSeconds: thresholdSeconds
        )
        let decoderWorkersEnvironmentKey = "VOXOL_ASR_CACHE_BENCHMARK_DECODER_WORKERS"
        let decoderWorkers = ProcessInfo.processInfo.environment[decoderWorkersEnvironmentKey]
            .flatMap(Int.init)
        guard decoderWorkers == nil || (1...8).contains(decoderWorkers!) else {
            throw Failure.usage
        }
        let computeUnitsEnvironmentKey = "VOXOL_ASR_CACHE_BENCHMARK_COMPUTE_UNITS"
        let requestedComputeUnits =
            ProcessInfo.processInfo.environment[computeUnitsEnvironmentKey] ?? "all"
        guard let computeUnits = ParakeetComputeUnits(rawValue: requestedComputeUnits) else {
            throw Failure.usage
        }
        let referenceOnly =
            ProcessInfo.processInfo.environment["VOXOL_ASR_CACHE_BENCHMARK_REFERENCE_ONLY"] == "1"
        let emitReferenceText =
            referenceOnly
            || ProcessInfo.processInfo.environment["VOXOL_ASR_CACHE_BENCHMARK_EMIT_REFERENCE_TEXT"]
                == "1"
        let runtime = ParakeetRuntime(
            modelRoot: URL(fileURLWithPath: arguments[1]),
            computeUnits: computeUnits,
            decoderWorkers: decoderWorkers,
            segmentation: segmentation
        )
        let clock = ContinuousClock()
        let loadStart = clock.now
        try await runtime.prepare()
        let maximumWaveformSampleCount = await runtime.maximumWaveformSampleCount
        let vocabularyEnvironmentKey = "VOXOL_ASR_CACHE_BENCHMARK_VOCABULARY"
        var vocabularyPath = ""
        var vocabularySHA256 = ""
        var vocabularyCount = 0
        if let path = ProcessInfo.processInfo.environment[vocabularyEnvironmentKey] {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw Failure.invalidVocabulary(path)
            }
            let terms = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !terms.isEmpty else { throw Failure.invalidVocabulary(path) }
            await runtime.applyDecodingBias(vocabulary: terms, languageCode: nil)
            vocabularyPath = url.standardizedFileURL.path
            vocabularySHA256 = digest(data)
            vocabularyCount = terms.count
        }
        emit([
            "type": "load", "scope": "asr-model-prepare",
            "milliseconds": milliseconds(loadStart.duration(to: clock.now)),
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "computeUnits": requestedComputeUnits,
            "maximumWaveformSampleCount": maximumWaveformSampleCount ?? 0,
            "maximumSegmentSeconds": segmentation.maximumSegmentDurationSeconds,
            "overlapSeconds": segmentation.overlapDurationSeconds,
            "segmentationThresholdSeconds": segmentation.segmentationThresholdDurationSeconds,
            "decoderWorkers": decoderWorkers ?? 0,
            "contextualVocabularyPath": vocabularyPath,
            "contextualVocabularySHA256": vocabularySHA256,
            "contextualVocabularyTerms": vocabularyCount,
        ])
        var failures = 0
        for sample in manifest.samples {
            let audioURL = URL(fileURLWithPath: sample.path)
            let bytes = try Data(contentsOf: audioURL)
            guard digest(bytes) == sample.sha256 else { throw Failure.audioChanged(sample.id) }
            let file = try AVAudioFile(
                forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.processingFormat.sampleRate == 16_000,
                file.processingFormat.channelCount == 1, file.length > 0,
                file.length <= AVAudioFramePosition(UInt32.max),
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else { throw Failure.invalidAudio(sample.id) }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?.pointee else {
                throw Failure.invalidAudio(sample.id)
            }
            let loaded = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let maximumSeconds = sample.maximumSeconds ?? Double(loaded.count) / 16_000
            guard maximumSeconds.isFinite, maximumSeconds >= 0.1 else { throw Failure.usage }
            let audio = Array(
                loaded.prefix(Int(min(maximumSeconds * 16_000, Double(loaded.count)))))
            let session = UUID()
            let reference = try await runtime.transcribe(samples: audio)
            let referenceHash = digest(Data(reference.text.utf8))
            let referenceEvidenceHash = try evidenceDigest(reference)
            if emitReferenceText {
                emit([
                    "type": "reference", "id": sample.id,
                    "sourceGroup": sample.sourceGroup, "language": sample.language,
                    "audioSHA256": sample.sha256,
                    "audioSeconds": Double(audio.count) / 16_000,
                    "text": reference.text,
                    "textSHA256": referenceHash,
                    "evidenceSHA256": referenceEvidenceHash,
                    "attempts": reference.inferenceAttemptCount,
                    "fallback": reference.usedFallbackSegmentation,
                ])
            }
            if referenceOnly { continue }
            await runtime.beginDictationSession(session)
            if let prefixes = sample.primePrefixSeconds {
                for seconds in prefixes {
                    guard seconds.isFinite, seconds >= 0.1,
                        seconds * 16_000 < Double(audio.count)
                    else { throw Failure.usage }
                    let count = Int(seconds * 16_000)
                    FileHandle.standardError.write(Data("prefix_start samples=\(count)\n".utf8))
                    let started = clock.now
                    let result = try await transcribe(
                        runtime: runtime,
                        samples: Array(audio.prefix(count)),
                        sessionID: session,
                        previewMode: previewMode
                    )
                    let wallMilliseconds = milliseconds(started.duration(to: clock.now))
                    emit([
                        "type": "prefix", "id": sample.id, "samples": count,
                        "wallMilliseconds": wallMilliseconds,
                        "reusedEncoderChunks": result.timing.reusedEncoderChunks,
                        "attempts": result.inferenceAttemptCount,
                        "textSHA256": digest(Data(result.text.utf8)),
                        "evidenceSHA256": try evidenceDigest(result),
                    ])
                }
            } else {
                _ = try await transcribe(
                    runtime: runtime,
                    samples: audio,
                    sessionID: session,
                    previewMode: previewMode
                )
            }
            // Alternate warm misses and exact hits; priming is never a timed observation.
            for repetition in 0..<manifest.repetitions {
                let modes = repetition.isMultiple(of: 2) ? [false, true] : [true, false]
                for cached in modes {
                    if sample.primePrefixSeconds != nil {
                        FileHandle.standardError.write(
                            Data("final_start cached=\(cached) repetition=\(repetition)\n".utf8))
                    }
                    let started = clock.now
                    do {
                        let result = try await transcribe(
                            runtime: runtime,
                            samples: audio,
                            sessionID: cached ? session : nil,
                            previewMode: previewMode
                        )
                        let wallMilliseconds = milliseconds(started.duration(to: clock.now))
                        let hash = digest(Data(result.text.utf8))
                        let evidenceHash = try evidenceDigest(result)
                        let exact =
                            hash == referenceHash
                            && (previewMode || evidenceHash == referenceEvidenceHash)
                        if !exact { failures += 1 }
                        let observation: [String: Any] = [
                            "type": "observation", "id": sample.id,
                            "sourceGroup": sample.sourceGroup, "language": sample.language,
                            "repetition": repetition, "cached": cached,
                            "scope": previewMode
                                ? "warm-file-asr-preview" : "warm-file-asr-only",
                            "audioSHA256": sample.sha256,
                            "audioSeconds": Double(audio.count) / 16_000,
                            "status": exact ? "ok" : "output-mismatch", "textSHA256": hash,
                            "referenceTextSHA256": referenceHash,
                            "evidenceSHA256": evidenceHash,
                            "referenceEvidenceSHA256": referenceEvidenceHash,
                            "wallMilliseconds": wallMilliseconds,
                            "inferenceMilliseconds": result.inferenceDurationSeconds * 1_000,
                            "melMilliseconds": result.timing.melExtract * 1_000,
                            "encoderMilliseconds": result.timing.encoder * 1_000,
                            "decoderMilliseconds": result.timing.decoderLoop * 1_000,
                            "reusedEncoderChunks": result.timing.reusedEncoderChunks,
                            "attempts": result.inferenceAttemptCount,
                            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                        ]
                        emit(observation)
                    } catch {
                        failures += 1
                        emit([
                            "type": "observation", "id": sample.id,
                            "repetition": repetition, "cached": cached, "status": "failed",
                            "wallMilliseconds": milliseconds(started.duration(to: clock.now)),
                            "errorType": String(describing: type(of: error)),
                        ])
                    }
                }
            }
            await runtime.endDictationSession(session)
        }
        if failures > 0 { throw Failure.observationsFailed(failures) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func transcribe(
        runtime: ParakeetRuntime,
        samples: [Float],
        sessionID: UUID?,
        previewMode: Bool
    ) async throws -> Transcription {
        if previewMode {
            return try await runtime.transcribePreview(samples: samples, sessionID: sessionID)
        }
        return try await runtime.transcribe(samples: samples, sessionID: sessionID)
    }

    /// Compare every downstream decoder signal, excluding measurements and cache hits.
    private static func evidenceDigest(_ result: Transcription) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let confidence = try encoder.encode(result.confidence)
        let fields: [String: Any] = [
            "text": result.text, "tokenIds": result.tokenIds,
            "frames": result.frameIndices, "durations": result.durations,
            "marginBits": result.tokenLogitMargins.map(\.bitPattern),
            "boundaries": result.chunkBoundaryFrames,
            "confidence": confidence.base64EncodedString(),
            "attempts": result.inferenceAttemptCount, "fallback": result.usedFallbackSegmentation,
        ]
        return digest(try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }

    private static func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    private struct Manifest: Decodable {
        let repetitions: Int
        let samples: [Sample]
    }

    private struct Sample: Decodable {
        let id: String
        let path: String
        let sha256: String
        let sourceGroup: String
        let language: String
        let maximumSeconds: Double?
        let primePrefixSeconds: [Double]?
    }

    private enum Failure: Error {
        case usage
        case audioChanged(String)
        case invalidAudio(String)
        case invalidVocabulary(String)
        case observationsFailed(Int)
    }
}
