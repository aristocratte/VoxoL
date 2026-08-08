import ASRBenchmarkKit
import AVFoundation
import AudioCaptureKit
import FidelityKit
import Foundation
import ParakeetCore
import QwenPolisher
import TextProcessingKit

@main
struct ASRBenchmarkCLI {
    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            throw CLIError.invalidArguments
        }
        switch command {
        case "validate":
            try validate(arguments)
        case "freeze":
            try freeze(arguments)
        case "score":
            try score(arguments)
        case "run-parakeet":
            try await runParakeet(arguments)
        case "capture":
            try await capture(arguments)
        default:
            throw CLIError.invalidArguments
        }
    }
}

private extension ASRBenchmarkCLI {
    static func validate(_ arguments: [String]) throws {
        let manifest = try loadManifest(requiredValue("--manifest", in: arguments))
        try manifest.validate(requireFrozen: arguments.contains("--require-frozen"))
        if let audioRoot = value("--audio-root", in: arguments) {
            try verifyAudioFiles(
                manifest,
                under: URL(fileURLWithPath: audioRoot, isDirectory: true)
            )
        }
        print(
            "items=\(manifest.items.count) digest=\(try manifest.digest()) frozen=\(manifest.frozenAt != nil)"
        )
    }

    static func freeze(_ arguments: [String]) throws {
        let input = try loadManifest(requiredValue("--manifest", in: arguments))
        let output = URL(fileURLWithPath: try requiredValue("--output", in: arguments))
        try requireAbsent(output)
        try verifyAudioFiles(
            input,
            under: URL(
                fileURLWithPath: try requiredValue("--audio-root", in: arguments),
                isDirectory: true
            )
        )
        let timestamp =
            value("--timestamp", in: arguments)
            ?? ISO8601DateFormatter().string(from: Date())
        let frozen = try input.frozen(at: timestamp)
        try writeJSON(frozen, to: output)
        print(frozen.contentSHA256 ?? "")
    }

    static func score(_ arguments: [String]) throws {
        let manifest = try loadManifest(requiredValue("--manifest", in: arguments))
        let predictions = try loadJSONLines(
            requiredValue("--predictions", in: arguments),
            as: ASRBenchmarkPrediction.self
        )
        let output = URL(fileURLWithPath: try requiredValue("--output", in: arguments))
        try requireAbsent(output)
        let report = try ASRBenchmarkScorer.score(
            manifest: manifest,
            predictions: predictions
        )
        try writeJSON(report, to: output)
        if let perItem = value("--per-item", in: arguments) {
            let destination = URL(fileURLWithPath: perItem)
            try requireAbsent(destination)
            try writeJSONLines(
                ASRBenchmarkScorer.scoreItems(
                    manifest: manifest,
                    predictions: predictions
                ),
                to: destination
            )
        }
        print(output.path)
    }

    /// The text the app would insert, not the recogniser's raw output.
    ///
    /// Mirrors the shipped path: deterministic cleanup always, the polisher
    /// only when that path asks for it. Reproducing the gating rather than
    /// polishing everything matters, because the fast path skips the model on
    /// exactly the longer dictations, and a benchmark that polished them all
    /// would report a product nobody runs.
    static func productText(
        for transcript: String,
        language: ASRBenchmarkLanguage,
        polisher: QwenPolisherRuntime?
    ) async throws -> String {
        guard let polisher else { return transcript }
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: transcript,
                preferredLanguage: textLanguage(for: language)
            )
        )
        guard preparation.shouldUsePolisher else {
            return preparation.normalizedText
        }
        do {
            let polished = try await polisher.polish(preparation)
            // The app never inserts a generation directly: FidelityValidator
            // restores the protected-token placeholders and rejects a drifting
            // rewrite back to the deterministic text. Skipping it here put a
            // literal VOXOLP0 in the measured output.
            return FidelityValidator.validate(
                candidate: polished.text,
                against: preparation
            ).text
        } catch {
            return preparation.normalizedText
        }
    }

    /// Maps a benchmark language onto the two the text pipeline models.
    ///
    /// The pipeline only knows French and English. Everything else is scored
    /// with the English rules, which is wrong in detail but honest: it is what
    /// the shipped app does with a Dutch dictation today.
    static func textLanguage(for language: ASRBenchmarkLanguage) -> TextLanguage {
        language == .french ? .french : .english
    }

    /// Writes one line per clip: each word with its weakest token margin.
    static func appendWordConfidence(
        words: [(word: String, margin: Float)],
        id: String,
        to path: String
    ) {
        let payload: [String: Any] = [
            "id": id,
            "words": words.map { ["word": $0.word, "margin": Double($0.margin)] },
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let line = String(data: data, encoding: .utf8)
        else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? (line + "\n").write(
                toFile: path,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    static func runParakeet(_ arguments: [String]) async throws {
        let manifest = try loadManifest(requiredValue("--manifest", in: arguments))
        try manifest.validate(requireFrozen: true)
        let audioRoot = URL(
            fileURLWithPath: try requiredValue("--audio-root", in: arguments),
            isDirectory: true
        )
        try verifyAudioFiles(manifest, under: audioRoot)
        let modelRoot = URL(
            fileURLWithPath: try requiredValue("--model-root", in: arguments),
            isDirectory: true
        )
        let output = URL(fileURLWithPath: try requiredValue("--output", in: arguments))
        let resume = arguments.contains("--resume")
        let existingPredictions: [ASRBenchmarkPrediction]
        if FileManager.default.fileExists(atPath: output.path) {
            guard resume else {
                throw CLIError.outputExists(output.path)
            }
            existingPredictions = try loadJSONLines(
                output.path,
                as: ASRBenchmarkPrediction.self
            )
        } else {
            existingPredictions = []
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: output.path, contents: nil)
        }
        let existingIDs = Set(existingPredictions.map(\.id))
        guard
            existingIDs.count == existingPredictions.count,
            existingIDs.isSubset(of: Set(manifest.items.map(\.id)))
        else {
            throw CLIError.invalidResumeOutput(output.path)
        }
        let requestedUnits = value("--compute-units", in: arguments) ?? "all"
        guard let computeUnits = ParakeetComputeUnits(rawValue: requestedUnits) else {
            throw CLIError.invalidArguments
        }
        let requestedSplit = value("--split", in: arguments)
            .flatMap(ASRBenchmarkSplit.init(rawValue:))
        if value("--split", in: arguments) != nil, requestedSplit == nil {
            throw CLIError.invalidArguments
        }

        var transcriber = try ParakeetTranscriber(
            modelsRoot: modelRoot,
            computeUnits: computeUnits,
            retryConfiguration: .production,
            sourceCompatibleFeatures:
                arguments.contains("--source-compatible-features")
        )

        // The competitor is told which language the clip is in and VoxoL is not.
        // That is the fair product comparison and a poor component one, so the
        // hint has to be switchable to separate the two.
        if let code = value("--language-code", in: arguments) {
            let penalty = transcriber.decodingBias(
                vocabulary: [String](),
                languageCode: code,
                modelsRoot: modelRoot
            )
            if !penalty.isEmpty {
                transcriber.logitBias = penalty
                print("language hint: \(code)")
            }
        }

        // Personalisation is the one advantage a cloud recogniser cannot copy,
        // and it had never been measured: the decoder's vocabulary boost was
        // wired into the app but no benchmark could switch it on. One term per
        // line, applied to every clip in the run.
        if let vocabularyPath = value("--vocabulary", in: arguments) {
            let terms = try String(contentsOfFile: vocabularyPath, encoding: .utf8)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            transcriber.contextualBias = transcriber.contextualVocabularyBias(
                for: terms,
                entryBoost: value("--vocabulary-entry-boost", in: arguments)
                    .flatMap(Float.init)
                    ?? ParakeetContextualBias.defaultEntryBoost,
                continuationBoost: value(
                    "--vocabulary-continuation-boost",
                    in: arguments
                )
                .flatMap(Float.init)
                ?? ParakeetContextualBias.defaultContinuationBoost
            )
            print("vocabulary: \(terms.count) terms")
        }

        // Without this the benchmark scored the recogniser and called it the
        // product: rawText and finalText were the same string on every clip,
        // so a competitor's edited output had nothing comparable to face.
        let polisher: QwenPolisherRuntime?
        if let root = value("--polisher-root", in: arguments) {
            polisher = QwenPolisherRuntime(
                modelRoot: URL(fileURLWithPath: root, isDirectory: true)
            )
            try await polisher?.prepare()
        } else {
            polisher = nil
        }
        let selectedItems = manifest.items.filter {
            requestedSplit == nil || $0.split == requestedSplit
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let outputHandle = try FileHandle(forWritingTo: output)
        try outputHandle.seekToEnd()
        defer {
            try? outputHandle.close()
        }
        var completedCount = selectedItems.filter { existingIDs.contains($0.id) }.count
        if completedCount > 0 {
            print("Resuming at \(completedCount)/\(selectedItems.count)")
        }
        for item in selectedItems where !existingIDs.contains(item.id) {
            let audioURL = audioRoot.appendingPathComponent(item.audioPath)
            let result = try transcriber.transcribe(audioURL: audioURL)
            let finalText = try await productText(
                for: result.text,
                language: item.language,
                polisher: polisher
            )
            if let path = value("--word-confidence", in: arguments) {
                appendWordConfidence(
                    words: transcriber.wordConfidences(for: result),
                    id: item.id,
                    to: path
                )
            }
            let prediction = ASRBenchmarkPrediction(
                id: item.id,
                rawText: result.text,
                finalText: finalText,
                inferenceMilliseconds: result.inferenceDurationSeconds * 1_000,
                confidence: ASRBenchmarkConfidenceSignals(
                    emittedTokenCount: result.confidence.emittedTokenCount,
                    meanTokenLogitMargin: result.confidence.meanTokenLogitMargin,
                    lowerDecileTokenLogitMargin:
                        result.confidence.lowerDecileTokenLogitMargin,
                    meanDurationLogitMargin: result.confidence.meanDurationLogitMargin,
                    lowerDecileDurationLogitMargin:
                        result.confidence.lowerDecileDurationLogitMargin,
                    blankDecisionRatio: result.confidence.blankDecisionRatio,
                    maximumFramesWithoutEmission:
                        result.confidence.maximumFramesWithoutEmission,
                    minimumOverlapTokenAgreement:
                        result.confidence.minimumOverlapTokenAgreement,
                    inferenceAttemptCount: result.inferenceAttemptCount,
                    usedFallbackSegmentation: result.usedFallbackSegmentation
                )
            )
            var encoded = try encoder.encode(prediction)
            encoded.append(0x0A)
            try outputHandle.write(contentsOf: encoded)
            completedCount += 1
            if completedCount == 1 || completedCount % 50 == 0
                || completedCount == selectedItems.count
            {
                try outputHandle.synchronize()
                print("[\(completedCount)/\(selectedItems.count)] \(item.id)")
            }
        }
        try outputHandle.synchronize()
        print(output.path)
    }

    @MainActor
    static func capture(_ arguments: [String]) async throws {
        let manifest = try loadManifest(requiredValue("--manifest", in: arguments))
        try manifest.validate()
        let audioRoot = URL(
            fileURLWithPath: try requiredValue("--audio-root", in: arguments),
            isDirectory: true
        )
        let requestedID = value("--id", in: arguments)
        let items = manifest.items.filter { requestedID == nil || $0.id == requestedID }
        guard !items.isEmpty else {
            throw CLIError.unknownCaptureItem(requestedID ?? "")
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CLIError.microphonePermissionDenied
        }

        for (offset, item) in items.enumerated() {
            let output = audioRoot.appendingPathComponent(item.audioPath)
            if FileManager.default.fileExists(atPath: output.path) {
                print("[\(offset + 1)/\(items.count)] \(item.id) already exists; skipping.")
                continue
            }
            print("\n[\(offset + 1)/\(items.count)] \(item.id)")
            print(item.reference.verbatim)
            print("\nPress Return to start, then Return again to stop.")
            _ = readLine()

            let capture = AudioCaptureSession(maximumDurationSeconds: 900)
            try capture.start()
            print("Recording…")
            _ = readLine()
            guard let audio = capture.stop(), audio.samples.count >= 1_600 else {
                throw CLIError.captureTooShort(item.id)
            }
            guard audio.droppedSampleCount == 0 else {
                throw CLIError.captureOverflow(item.id)
            }
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeWAV(audio.samples, sampleRate: audio.sampleRate, to: output)
            print(
                String(
                    format: "Saved %.2fs · peak %.1f dBFS · %@",
                    audio.durationSeconds,
                    audio.maximumRootMeanSquare > 0
                        ? 20 * log10(audio.maximumRootMeanSquare)
                        : -80,
                    output.path
                )
            )
        }
    }

    static func loadManifest(_ path: String) throws -> ASRBenchmarkManifest {
        try JSONDecoder().decode(
            ASRBenchmarkManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
    }

    static func loadJSONLines<Value: Decodable>(
        _ path: String,
        as _: Value.Type
    ) throws -> [Value] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let string = String(data: data, encoding: .utf8) else {
            throw CLIError.invalidUTF8(path)
        }
        let decoder = JSONDecoder()
        return try string.split(whereSeparator: \.isNewline).map {
            try decoder.decode(Value.self, from: Data($0.utf8))
        }
    }

    static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func writeJSONLines<Value: Encodable>(
        _ values: [Value],
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try values.reduce(into: Data()) { output, value in
            output.append(try encoder.encode(value))
            output.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }

    static func writeWAV(
        _ samples: [Float],
        sampleRate: Double,
        to output: URL
    ) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let channel = buffer.floatChannelData?[0]
        else {
            throw CLIError.invalidAudioBuffer
        }
        channel.update(from: samples, count: samples.count)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let file = try AVAudioFile(
            forWriting: output,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    static func verifyAudioFiles(
        _ manifest: ASRBenchmarkManifest,
        under audioRoot: URL
    ) throws {
        for item in manifest.items {
            let audioURL = audioRoot.appendingPathComponent(item.audioPath)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw CLIError.missingAudio(item.id)
            }
            let file = try AVAudioFile(forReading: audioURL)
            guard
                file.length >= 1_600,
                file.processingFormat.channelCount == 1,
                abs(file.processingFormat.sampleRate - 16_000) < 0.5
            else {
                throw CLIError.invalidBenchmarkAudio(item.id)
            }
        }
    }

    static func requireAbsent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw CLIError.outputExists(url.path)
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
    }

    static func requiredValue(_ flag: String, in arguments: [String]) throws -> String {
        guard let result = value(flag, in: arguments) else {
            throw CLIError.invalidArguments
        }
        return result
    }

    static func value(_ flag: String, in arguments: [String]) -> String? {
        guard
            let index = arguments.firstIndex(of: flag),
            arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }
}

private enum CLIError: LocalizedError {
    case invalidArguments
    case outputExists(String)
    case invalidResumeOutput(String)
    case invalidUTF8(String)
    case unknownCaptureItem(String)
    case microphonePermissionDenied
    case captureTooShort(String)
    case captureOverflow(String)
    case invalidAudioBuffer
    case missingAudio(String)
    case invalidBenchmarkAudio(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            """
            Usage:
              voxol-asr-benchmark validate --manifest <json> [--require-frozen] \
                [--audio-root <directory>]
              voxol-asr-benchmark freeze --manifest <json> --audio-root <directory> \
                --output <json> [--timestamp <iso8601>]
              voxol-asr-benchmark score --manifest <json> --predictions <jsonl> \
                --output <json> [--per-item <jsonl>]
              voxol-asr-benchmark run-parakeet --manifest <json> --audio-root <directory> \
                --model-root <directory> --output <jsonl> \
                [--polisher-root <directory>] \
                [--compute-units ane|gpu|cpu|all] \
                [--source-compatible-features] \
                [--resume] \
                [--split development|calibration|blind|stress]
              voxol-asr-benchmark capture --manifest <json> --audio-root <directory> \
                [--id <benchmark-item-id>]
            """
        case .outputExists(let path):
            "Refusing to overwrite benchmark output: \(path)"
        case .invalidResumeOutput(let path):
            "Benchmark resume output has duplicate or unknown IDs: \(path)"
        case .invalidUTF8(let path):
            "Benchmark JSONL is not valid UTF-8: \(path)"
        case .unknownCaptureItem(let identifier):
            "The benchmark has no capture item named \(identifier)."
        case .microphonePermissionDenied:
            "Microphone permission was denied for the benchmark recorder."
        case .captureTooShort(let identifier):
            "The recording for \(identifier) is shorter than 100 ms."
        case .captureOverflow(let identifier):
            "The recording for \(identifier) exceeded the bounded capture buffer."
        case .invalidAudioBuffer:
            "The captured samples could not be written as a WAV file."
        case .missingAudio(let identifier):
            "The benchmark audio is missing for \(identifier)."
        case .invalidBenchmarkAudio(let identifier):
            "Benchmark audio for \(identifier) must be mono 16 kHz and at least 100 ms."
        }
    }
}
