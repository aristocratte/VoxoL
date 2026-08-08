import AVFAudio
import Foundation
import Speech

struct AppleDictationResult: Sendable {
    let text: String
    let inferenceDurationSeconds: TimeInterval
}

enum AppleDictationError: Error, LocalizedError {
    case unavailable
    case unsupportedLocale
    case assetsUnavailable
    case unsupportedAudioFormat
    case invalidAudioBuffer

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Language-locked dictation requires macOS 26 or later."
        case .unsupportedLocale:
            "The selected dictation language is unavailable on this Mac."
        case .assetsUnavailable:
            "The selected language model could not be prepared."
        case .unsupportedAudioFormat:
            "The selected language model does not accept 16 kHz audio."
        case .invalidAudioBuffer:
            "The captured audio could not be prepared for transcription."
        }
    }
}

/// Locale-locked, on-device transcription used when the user chooses French or English.
actor AppleDictationRuntime {
    private static let sampleRate = 16_000.0
    private static let chunkSize = 4_096

    private var preparedLocaleIdentifiers = Set<String>()
    private var preparationTasks: [String: Task<Void, Error>] = [:]

    func prepare(localeIdentifier: String) async throws {
        guard #available(macOS 26.0, *) else {
            throw AppleDictationError.unavailable
        }
        guard !preparedLocaleIdentifiers.contains(localeIdentifier) else {
            return
        }
        if let task = preparationTasks[localeIdentifier] {
            try await task.value
            return
        }

        let task = Task {
            try await Self.prepareLocale(localeIdentifier: localeIdentifier)
        }
        preparationTasks[localeIdentifier] = task
        do {
            try await task.value
            preparationTasks[localeIdentifier] = nil
            preparedLocaleIdentifiers.insert(localeIdentifier)
        } catch {
            preparationTasks[localeIdentifier] = nil
            throw error
        }
    }

    func transcribe(
        samples: [Float],
        localeIdentifier: String,
        contextualStrings: [String] = []
    ) async throws -> AppleDictationResult {
        guard #available(macOS 26.0, *) else {
            throw AppleDictationError.unavailable
        }
        try Task.checkCancellation()
        try await prepare(localeIdentifier: localeIdentifier)

        let (transcriber, format) = try await Self.configuredTranscriber(
            localeIdentifier: localeIdentifier
        )
        let inputs = try Self.analyzerInputs(samples: samples, format: format)
        let analyzer = Self.makeAnalyzer(transcriber: transcriber)
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(contextualStrings.prefix(64))
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)

        let results = Task { () throws -> String in
            var transcript = ""
            for try await result in transcriber.results {
                transcript += String(result.text.characters)
            }
            return transcript
        }
        let inputSequence = AsyncStream<AnalyzerInput> { continuation in
            for input in inputs {
                continuation.yield(input)
            }
            continuation.finish()
        }

        let startedAt = Date()
        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(inputSequence) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let transcript = try await results.value
            preparedLocaleIdentifiers.insert(localeIdentifier)
            return AppleDictationResult(
                text: transcript,
                inferenceDurationSeconds: Date().timeIntervalSince(startedAt)
            )
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

@available(macOS 26.0, *)
private extension AppleDictationRuntime {
    static func prepareLocale(localeIdentifier: String) async throws {
        let (transcriber, format) = try await configuredTranscriber(
            localeIdentifier: localeIdentifier
        )
        let analyzer = makeAnalyzer(transcriber: transcriber)
        try await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
    }

    static func configuredTranscriber(
        localeIdentifier: String
    ) async throws -> (DictationTranscriber, AVAudioFormat) {
        guard
            let locale = await DictationTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: localeIdentifier)
            )
        else {
            throw AppleDictationError.unsupportedLocale
        }

        let transcriber = DictationTranscriber(locale: locale, preset: .shortDictation)
        let modules: [any SpeechModule] = [transcriber]
        if await AssetInventory.status(forModules: modules) != .installed,
            let request = try await AssetInventory.assetInstallationRequest(supporting: modules)
        {
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw AppleDictationError.assetsUnavailable
        }
        guard
            let format = await transcriber.availableCompatibleAudioFormats.first(where: {
                $0.sampleRate == Self.sampleRate
                    && $0.commonFormat == .pcmFormatInt16
                    && $0.channelCount == 1
            })
        else {
            throw AppleDictationError.unsupportedAudioFormat
        }
        return (transcriber, format)
    }

    static func makeAnalyzer(transcriber: DictationTranscriber) -> SpeechAnalyzer {
        SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .processLifetime
            )
        )
    }

    static func analyzerInputs(
        samples: [Float],
        format: AVAudioFormat
    ) throws -> [AnalyzerInput] {
        guard !samples.isEmpty else {
            throw AppleDictationError.invalidAudioBuffer
        }

        var inputs: [AnalyzerInput] = []
        inputs.reserveCapacity((samples.count + Self.chunkSize - 1) / Self.chunkSize)
        var offset = 0
        while offset < samples.count {
            let count = min(Self.chunkSize, samples.count - offset)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(count)
                ),
                let destination = buffer.int16ChannelData?[0]
            else {
                throw AppleDictationError.invalidAudioBuffer
            }

            for index in 0..<count {
                let sample = max(-1, min(1, samples[offset + index]))
                destination[index] = Int16(sample * Float(Int16.max))
            }
            buffer.frameLength = AVAudioFrameCount(count)
            inputs.append(AnalyzerInput(buffer: buffer))
            offset += count
        }
        return inputs
    }
}
