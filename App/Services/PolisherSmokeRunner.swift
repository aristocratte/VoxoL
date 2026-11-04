import AppKit
import ApplicationServices
import Darwin
import CryptoKit
import FidelityKit
import Foundation
import PersonalizationKit
import QwenPolisher
import TextProcessingKit

enum PolisherSmokeRunner {
    static let argument = "--polisher-smoke"

    static func runAndExit(arguments: [String]) async -> Never {
        let exitCode = await run(arguments: arguments)
        fflush(stdout)
        fflush(stderr)
        Darwin.exit(exitCode)
    }
}

private extension PolisherSmokeRunner {
    @MainActor
    static func runAudioReplay(
        audioURL: URL, modelRoot: URL, asrRoot: URL,
        maximumSeconds: Double, realtime: Bool, rewrite: Bool, observeDelivery: Bool
    ) async throws -> Int32 {
        let loaded = try AudioLoader.loadMono16k(at: audioURL)
        let samples = Array(loaded.prefix(Int(maximumSeconds * 16_000)))
        let audioSeconds = Double(samples.count) / 16_000
        guard audioSeconds >= 0.1 else {
            throw NSError(
                domain: "VoxoLReplay", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Replay needs at least 100 milliseconds of audio."
                ])
        }
        let deliveryProbe = observeDelivery ? try OwnedTextEditProbe() : nil
        defer { deliveryProbe?.close() }
        let asr = ParakeetRuntime(modelRoot: asrRoot, computeUnits: .all)
        let processor = DictationTextProcessor(modelRoot: modelRoot)
        let loadStarted = ContinuousClock.now
        try await asr.prepare()
        let asrPrepared = ContinuousClock.now
        _ = try await asr.transcribe(samples: Array(samples.prefix(40_000)))
        let asrWarmed = ContinuousClock.now
        try await processor.warmUp()
        let polisherWarmed = ContinuousClock.now
        let template = TextProcessingRequest(
            rawTranscript: "",
            fallbackLanguage: .french,
            preferences: TextProcessingPreferences(
                cleanupMode: rewrite ? .rewrite : .faithful, fastPathEnabled: true
            )
        )
        let baseline = try await audioReplayPass(
            samples: samples, asr: asr, processor: processor, template: template,
            deliveryProbe: deliveryProbe, sourceAudioURL: audioURL
        )
        let session = UUID()
        await processor.beginPrefetchSession(session)
        await asr.beginDictationSession(session)
        let playbackStarted = ContinuousClock.now
        let playbackDeadline = playbackStarted.advanced(by: .seconds(audioSeconds))
        let previews = Task.detached(priority: .userInitiated) {
            var metrics = AudioReplayPreviewMetrics()
            var nextPreviewSeconds = 20.0
            while nextPreviewSeconds < audioSeconds - (realtime ? 0 : 4) {
                var attemptStarted = false
                var pendingASRStart: ContinuousClock.Instant?
                var pendingCleanupStart: ContinuousClock.Instant?
                defer {
                    let stopped = ContinuousClock.now
                    if let pendingASRStart {
                        metrics.recordASRAttempt(
                            from: pendingASRStart, to: stopped, deadline: playbackDeadline)
                    }
                    if let pendingCleanupStart {
                        metrics.recordCleanupAttempt(
                            from: pendingCleanupStart, to: stopped, deadline: playbackDeadline)
                    }
                }
                do {
                    if realtime {
                        try await Task.sleep(
                            until: playbackStarted.advanced(by: .seconds(nextPreviewSeconds)),
                            clock: .continuous
                        )
                    }
                    try Task.checkCancellation()
                    let atSeconds =
                        realtime
                        ? Double(playbackStarted.duration(to: .now).milliseconds) / 1_000
                        : nextPreviewSeconds
                    guard atSeconds < audioSeconds else { break }
                    let available = Array(samples.prefix(Int(atSeconds * 16_000)))
                    attemptStarted = true
                    metrics.attemptedPreviewCount += 1
                    metrics.asrAttemptCount += 1
                    let asrStart = ContinuousClock.now
                    pendingASRStart = asrStart
                    let partial = try await asr.transcribePreview(
                        samples: available, sessionID: session)
                    let asrFinished = ContinuousClock.now
                    let asrMilliseconds = asrStart.duration(to: asrFinished).milliseconds
                    metrics.recordASRAttempt(
                        from: asrStart, to: asrFinished, deadline: playbackDeadline)
                    pendingASRStart = nil
                    try Task.checkCancellation()
                    // Match the app: next acoustic preview is four seconds after
                    // this ASR completion, while text cleanup uses that interval.
                    nextPreviewSeconds =
                        realtime
                        ? Double(playbackStarted.duration(to: .now).milliseconds) / 1_000 + 4
                        : nextPreviewSeconds + 4
                    var request = template
                    request.rawTranscript = partial.text.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    metrics.cleanupAttemptCount += 1
                    let cleanupStarted = ContinuousClock.now
                    pendingCleanupStart = cleanupStarted
                    let cleanup = await processor.prefetch(request, sessionID: session)
                    metrics.recordCleanupAttempt(
                        from: cleanupStarted, to: .now, deadline: playbackDeadline)
                    pendingCleanupStart = nil
                    try Task.checkCancellation()
                    metrics.previewCount += 1
                    metrics.reusedEncoderChunks += partial.timing.reusedEncoderChunks
                    metrics.asrMilliseconds += asrMilliseconds
                    metrics.cleanupMilliseconds += Int(cleanup.durationSeconds * 1_000)
                    metrics.generatedCalls += cleanup.generatedCallCount
                    metrics.reusedCalls += cleanup.reusedCallCount
                    metrics.generatedTokens += cleanup.generatedOutputTokenCount
                    metrics.cleanupFailedCalls += cleanup.failedCallCount
                    FileHandle.standardError.write(
                        Data(
                            "audio_preview at_s=\(Int(atSeconds)) asr_ms=\(asrMilliseconds) generated=\(cleanup.generatedCallCount) reused=\(cleanup.reusedCallCount)\n"
                                .utf8
                        ))
                } catch is CancellationError {
                    if attemptStarted {
                        metrics.cancelledPreviewCount += 1
                    } else {
                        metrics.cancelledWaitCount += 1
                    }
                    break
                } catch {
                    metrics.failures += 1
                    break
                }
            }
            return metrics
        }
        let anticipated: AudioReplayPass
        do {
            if realtime {
                try await Task.sleep(
                    until: playbackDeadline, tolerance: .zero, clock: .continuous
                )
                previews.cancel()
            } else {
                _ = await previews.value
            }
            anticipated = try await audioReplayPass(
                samples: samples, asr: asr, processor: processor,
                template: template, pendingPrefetch: previews, sessionID: session,
                deliveryProbe: deliveryProbe, scheduledRelease: realtime ? playbackDeadline : nil
            )
        } catch {
            previews.cancel()
            _ = await previews.value
            await processor.endPrefetchSession(session)
            await asr.endDictationSession(session)
            throw error
        }
        let previewMetrics = await previews.value
        await processor.endPrefetchSession(session)
        await asr.endDictationSession(session)
        let freshControl = try await audioReplayPass(
            samples: samples, asr: asr, processor: processor, template: template,
            deliveryProbe: deliveryProbe, sourceAudioURL: audioURL
        )
        let report = AudioReplayReport(
            replayKind: realtime ? "real-time-audio-prefixes" : "accelerated-audio-prefixes",
            afterStopTimerOrigin: realtime ? "scheduled-audio-end" : "final-pass-entry",
            stopSleepTolerance: realtime ? "zero" : "not-used",
            audioSeconds: audioSeconds,
            mode: rewrite ? "rewrite" : "faithful",
            baseline: baseline,
            anticipated: anticipated,
            freshControl: freshControl,
            previews: previewMetrics,
            identicalASR: baseline.rawTextSHA256 == anticipated.rawTextSHA256
                && anticipated.rawTextSHA256 == freshControl.rawTextSHA256,
            identicalFinalText: baseline.finalTextSHA256 == anticipated.finalTextSHA256
                && anticipated.finalTextSHA256 == freshControl.finalTextSHA256,
            sourceAudioSeconds: Double(loaded.count) / 16_000,
            croppedToRequestedDuration: samples.count != loaded.count,
            asrPreparationMilliseconds: loadStarted.duration(to: asrPrepared).milliseconds,
            asrWarmupMilliseconds: asrPrepared.duration(to: asrWarmed).milliseconds,
            polisherLoadAndWarmupMilliseconds: asrWarmed.duration(to: polisherWarmed).milliseconds,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
        return report.identicalASR && report.identicalFinalText
            && anticipated.failure == nil && baseline.failure == nil && freshControl.failure == nil
            && (!observeDelivery
                || [baseline, anticipated, freshControl].allSatisfy {
                    $0.delivery?.observed == true
                })
            ? 0 : 1
    }

    @MainActor
    static func audioReplayPass(
        samples: [Float], asr: ParakeetRuntime,
        processor: DictationTextProcessor, template: TextProcessingRequest,
        pendingPrefetch: Task<AudioReplayPreviewMetrics, Never>? = nil,
        sessionID: UUID? = nil,
        deliveryProbe: OwnedTextEditProbe? = nil,
        sourceAudioURL: URL? = nil,
        scheduledRelease: ContinuousClock.Instant? = nil
    ) async throws -> AudioReplayPass {
        let deliveryTarget = try deliveryProbe?.prepareTarget()
        let entered = ContinuousClock.now
        let released = scheduledRelease ?? entered
        // File controls include loading/conversion; the recording replay already
        // has captured PCM. Apply the same explicit duration cap in both paths.
        let inputSamples =
            try sourceAudioURL.map {
                Array(try AudioLoader.loadMono16k(at: $0).prefix(samples.count))
            } ?? samples
        let audioLoaded = ContinuousClock.now
        let transcription = try await asr.transcribe(samples: inputSamples, sessionID: sessionID)
        let asrCompleted = ContinuousClock.now
        _ = await pendingPrefetch?.value
        let ready = ContinuousClock.now
        var request = template
        request.rawTranscript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let preparation = DeterministicTextProcessor.prepare(request)
        let result = await processor.process(preparation, request: request, sessionID: sessionID)
        let finished = ContinuousClock.now
        let delivery: DeliveryProbeResult?
        if let deliveryProbe, let deliveryTarget {
            delivery = await deliveryProbe.deliver(
                result.text, to: deliveryTarget, releasedAt: released)
        } else {
            delivery = nil
        }
        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return AudioReplayPass(
            releaseToTextMilliseconds: released.duration(to: finished).milliseconds,
            releaseDispatchMilliseconds: released.duration(to: entered).milliseconds,
            asrMilliseconds: audioLoaded.duration(to: asrCompleted).milliseconds,
            producerDrainMilliseconds: asrCompleted.duration(to: ready).milliseconds,
            textMilliseconds: ready.duration(to: finished).milliseconds,
            generatedCalls: result.generatedCallCount,
            reusedCalls: result.reusedCallCount,
            generatedOutputTokens: result.generatedOutputTokenCount,
            reusedOutputTokens: result.reusedOutputTokenCount,
            wordCount: request.rawTranscript.split(whereSeparator: \.isWhitespace).count,
            reusedEncoderChunks: transcription.timing.reusedEncoderChunks,
            rawTextSHA256: digest(request.rawTranscript), finalTextSHA256: digest(result.text),
            failure: result.failure?.rawValue,
            inputKind: sourceAudioURL == nil ? "captured-pcm-replay" : "file-load-and-convert",
            audioLoadMilliseconds: entered.duration(to: audioLoaded).milliseconds,
            delivery: delivery
        )
    }

    static func run(arguments: [String]) async -> Int32 {
        if arguments.contains("--insertion-only") {
            return await runInsertionOnly()
        }
        for (flag, range) in [("--prompt-lookup-tokens", 0...16), ("--mlx-cache-mb", 0...16_384)] {
            guard arguments.contains(flag) else { continue }
            guard let value = value(after: flag, in: arguments),
                (flag == "--mlx-cache-mb" && value == "unlimited")
                    || Int(value).map({ range.contains($0) }) == true
            else {
                write("Invalid or missing value for \(flag)\n", to: .standardError)
                return 2
            }
        }
        if arguments.contains("--without-adapter"), arguments.contains("--adapter") {
            write("--without-adapter and --adapter cannot be combined\n", to: .standardError)
            return 2
        }
        guard let modelPath = value(after: "--model", in: arguments) else {
            write("Missing --model path\n", to: .standardError)
            return 2
        }
        if let audioPath = value(after: "--audio-replay", in: arguments) {
            guard !arguments.contains("--without-adapter"),
                !arguments.contains("--adapter"),
                !arguments.contains("--prompt-lookup-tokens"),
                !arguments.contains("--mlx-cache-mb")
            else {
                write(
                    "Audio replay uses the production generation configuration and installed adapter; overrides are not supported.\n",
                    to: .standardError)
                return 2
            }
            guard let asrPath = value(after: "--asr-model", in: arguments) else {
                write("Audio replay requires --asr-model\n", to: .standardError)
                return 2
            }
            let limit = value(after: "--replay-seconds", in: arguments).flatMap(Double.init) ?? 180
            guard limit.isFinite, limit >= 0.1, limit <= 180 else {
                write("--replay-seconds must be in 0.1...180\n", to: .standardError)
                return 2
            }
            do {
                return try await runAudioReplay(
                    audioURL: URL(fileURLWithPath: audioPath),
                    modelRoot: URL(fileURLWithPath: modelPath),
                    asrRoot: URL(fileURLWithPath: asrPath),
                    maximumSeconds: limit,
                    realtime: arguments.contains("--replay-real-time"),
                    rewrite: arguments.contains("--rewrite"),
                    observeDelivery: arguments.contains("--observe-textedit-delivery")
                )
            } catch {
                write("Audio replay failed: \(error)\n", to: .standardError)
                return 1
            }
        }
        if let suitePath = value(after: "--suite", in: arguments) {
            do {
                if arguments.contains("--through-processor") {
                    return try await runSuiteThroughProcessor(
                        modelRoot: URL(fileURLWithPath: modelPath, isDirectory: true),
                        suiteURL: URL(fileURLWithPath: suitePath),
                        adapterRoot: value(after: "--adapter", in: arguments).map {
                            URL(fileURLWithPath: $0, isDirectory: true)
                        },
                        useInstalledAdapter: !arguments.contains("--without-adapter"),
                        generationConfiguration: generationConfiguration(arguments: arguments),
                        prefetchReplay: arguments.contains("--prefetch-replay")
                    )
                }
                return try await runSuite(
                    modelRoot: URL(fileURLWithPath: modelPath, isDirectory: true),
                    adapterRoot: value(after: "--adapter", in: arguments).map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    },
                    suiteURL: URL(fileURLWithPath: suitePath),
                    useInstalledAdapter: !arguments.contains("--without-adapter"),
                    generationConfiguration: generationConfiguration(arguments: arguments)
                )
            } catch {
                write("Polisher suite failed: \(String(describing: error))\n", to: .standardError)
                return 1
            }
        }
        let transcript =
            value(after: "--text", in: arguments)
            ?? "euh envoie le rapport demain matin à VoxoL"
        let modelRoot = URL(fileURLWithPath: modelPath, isDirectory: true)
        do {
            if arguments.contains("--include-candidate") {
                return try await runCandidateSmoke(
                    modelRoot: modelRoot,
                    adapterRoot: value(after: "--adapter", in: arguments).map {
                        URL(fileURLWithPath: $0, isDirectory: true)
                    },
                    transcript: transcript,
                    rewrite: arguments.contains("--rewrite"),
                    useInstalledAdapter: !arguments.contains("--without-adapter"),
                    generationConfiguration: generationConfiguration(arguments: arguments)
                )
            }
            let processor = DictationTextProcessor(
                modelRoot: modelRoot,
                adapterRoot: value(after: "--adapter", in: arguments).map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                },
                useInstalledAdapter: !arguments.contains("--without-adapter"),
                generationConfiguration: generationConfiguration(arguments: arguments)
            )
            try await processor.warmUp()
            let preparation = DeterministicTextProcessor.prepare(
                TextProcessingRequest(
                    rawTranscript: transcript,
                    preferences: TextProcessingPreferences(
                        cleanupMode: arguments.contains("--rewrite") ? .rewrite : .faithful,
                        fastPathEnabled: false
                    ),
                    personalization: PersonalizationSnapshot()
                )
            )
            let result = await processor.process(preparation)
            let payload: [String: Any] = [
                "route": result.route.rawValue,
                "text": result.text,
                "duration_ms": Int(result.polishingDurationSeconds * 1_000),
                "failure": result.failure.map(\.rawValue) as Any? ?? NSNull(),
                "rejection": result.rejectionReason.map(\.rawValue) as Any? ?? NSNull(),
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return result.route == .qwen ? 0 : 1
        } catch {
            write("Polisher smoke failed: \(String(describing: error))\n", to: .standardError)
            return 1
        }
    }

    @MainActor
    static func runInsertionOnly() async -> Int32 {
        do {
            let probe = try OwnedTextEditProbe()
            defer { probe.close() }
            let fixtures = [
                "Le rendez-vous est jeudi à 10 h, pas vendredi.",
                "Please keep the 3 commits, but do not push them.",
                "VoxoL conserve le code user_id et le pull request en anglais.",
            ]
            var results: [DeliveryProbeResult] = []
            for _ in 0..<3 {
                for text in fixtures {
                    let target = try probe.prepareTarget()
                    results.append(await probe.deliver(text, to: target, releasedAt: .now))
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(results))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return results.allSatisfy(\.observed) ? 0 : 1
        } catch {
            write("Insertion probe unavailable: \(error)\n", to: .standardError)
            return 1
        }
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }

    static func generationConfiguration(
        arguments: [String]
    ) -> QwenPolisherGenerationConfiguration {
        let maximumKVCacheSize: Int?
        if let value = value(after: "--max-kv-size", in: arguments) {
            maximumKVCacheSize = value == "none" ? nil : Int(value)
        } else {
            maximumKVCacheSize = nil
        }
        let prefillStepSize =
            value(after: "--prefill-step-size", in: arguments).flatMap(Int.init) ?? 512
        let maximumBufferCacheBytes: Int?
        if let value = value(after: "--mlx-cache-mb", in: arguments) {
            maximumBufferCacheBytes =
                value == "unlimited" ? nil : Int(value).map { $0 * 1_024 * 1_024 }
        } else {
            maximumBufferCacheBytes = QwenPolisherGenerationConfiguration().maximumBufferCacheBytes
        }
        return QwenPolisherGenerationConfiguration(
            maximumKVCacheSize: maximumKVCacheSize,
            prefillStepSize: prefillStepSize,
            usesPromptPrefixCache: !arguments.contains("--no-prompt-prefix-cache"),
            fusesAdapter: !arguments.contains("--no-fuse-adapter"),
            promptLookupTokenCount: value(after: "--prompt-lookup-tokens", in: arguments)
                .flatMap(Int.init),
            maximumBufferCacheBytes: maximumBufferCacheBytes,
            promptStyle: value(after: "--prompt-style", in: arguments)
                .flatMap(PolishingPromptStyle.init(rawValue:)) ?? .production
        )
    }

    static func write(_ value: String, to handle: FileHandle) {
        handle.write(Data(value.utf8))
    }

    static func runCandidateSmoke(
        modelRoot: URL,
        adapterRoot: URL?,
        transcript: String,
        rewrite: Bool,
        useInstalledAdapter: Bool,
        generationConfiguration: QwenPolisherGenerationConfiguration
    ) async throws -> Int32 {
        let preparation = DeterministicTextProcessor.prepare(
            TextProcessingRequest(
                rawTranscript: transcript,
                preferences: TextProcessingPreferences(
                    cleanupMode: rewrite ? .rewrite : .faithful,
                    fastPathEnabled: false
                ),
                personalization: PersonalizationSnapshot()
            )
        )
        let runtime = QwenPolisherRuntime(
            modelRoot: modelRoot,
            adapterRoot: adapterRoot,
            useInstalledAdapter: useInstalledAdapter,
            generationConfiguration: generationConfiguration
        )
        try await runtime.warmUp()
        let generated = try await runtime.polish(preparation, timeout: .seconds(8))
        let decision = FidelityValidator.validateWithRepair(
            candidate: generated.text, against: preparation)
        let payload: [String: Any] = [
            "candidate": generated.text,
            "accepted": decision.usedModelOutput,
            "rejection": decision.rejectionReason.map(\.rawValue) as Any? ?? NSNull(),
            "duration_ms": Int(generated.durationSeconds * 1_000),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return decision.usedModelOutput ? 0 : 1
    }

    static func runSuite(
        modelRoot: URL,
        adapterRoot: URL?,
        suiteURL: URL,
        useInstalledAdapter: Bool,
        generationConfiguration: QwenPolisherGenerationConfiguration
    ) async throws -> Int32 {
        let suite = try JSONDecoder().decode(
            PolisherEvaluationSuite.self,
            from: Data(contentsOf: suiteURL)
        )
        let runtime = QwenPolisherRuntime(
            modelRoot: modelRoot,
            adapterRoot: adapterRoot,
            useInstalledAdapter: useInstalledAdapter,
            generationConfiguration: generationConfiguration
        )
        let warmupStarted = ContinuousClock.now
        try await runtime.warmUp()
        let warmupDurationMilliseconds = warmupStarted.duration(to: .now).milliseconds
        var results = [PolisherEvaluationResult]()
        results.reserveCapacity(suite.cases.count)

        for (index, testCase) in suite.cases.enumerated() {
            let preparation = DeterministicTextProcessor.prepare(
                TextProcessingRequest(
                    rawTranscript: testCase.transcript,
                    preferredLanguage: testCase.language.textLanguage,
                    fallbackLanguage: testCase.fallbackLanguage ?? .english,
                    preferences: TextProcessingPreferences(
                        cleanupMode: testCase.mode ?? .faithful,
                        fastPathEnabled: false,
                        profile: testCase.profile ?? .automatic
                    ),
                    personalization: PersonalizationSnapshot()
                )
            )
            let generationStarted = ContinuousClock.now
            do {
                let timeout = testCase.timeoutMilliseconds.map(Duration.milliseconds) ?? .seconds(8)
                let generated = try await runtime.polish(preparation, timeout: timeout)
                let decision = FidelityValidator.validateWithRepair(
                    candidate: generated.text,
                    against: preparation
                )
                results.append(
                    PolisherEvaluationResult(
                        id: testCase.id,
                        expected: testCase.expected,
                        candidate: generated.text,
                        normalized: preparation.normalizedText,
                        finalText: decision.text,
                        accepted: decision.usedModelOutput,
                        exactMatch: decision.usedModelOutput && decision.text == testCase.expected,
                        pipelineExactMatch: decision.text == testCase.expected,
                        rejection: decision.rejectionReason?.rawValue,
                        failure: nil,
                        durationMilliseconds: Int(generated.durationSeconds * 1_000),
                        promptDurationMilliseconds: Int(
                            generated.promptDurationSeconds * 1_000
                        ),
                        generationDurationMilliseconds: Int(
                            generated.generationDurationSeconds * 1_000
                        ),
                        reusedPromptTokens: generated.reusedPromptTokenCount,
                        promptTokens: generated.promptTokenCount,
                        outputTokens: generated.outputTokenCount,
                        processingLanguage: preparation.language.rawValue,
                        profile: preparation.profile.rawValue,
                        mode: (testCase.mode ?? .faithful).rawValue,
                        protectedTokenCount: preparation.protectedTokens.count,
                        qwenRequested: preparation.shouldUsePolisher,
                        route: decision.usedModelOutput ? "qwen" : "deterministicFallback",
                        polisherOutcome: decision.usedModelOutput
                            ? (decision.text == preparation.normalizedText
                                ? "copiedInput" : "modelOutputUsed")
                            : "validatorRejected",
                        repairedSentenceCount: decision.repairedSentenceCount,
                        v3Status: nil,
                        v3Rejection: nil,
                        v3AcceptedEditCount: nil,
                        v3RejectedEditCount: nil,
                        v3RepairedClauseCount: nil,
                        proposedDraftTokens: generated.proposedDraftTokenCount,
                        acceptedDraftTokens: generated.acceptedDraftTokenCount,
                        draftVerifications: generated.draftVerificationCount,
                        replayedTokens: generated.replayedTokenCount,
                        reusedOutputTokens: generated.reusedOutputTokenCount
                    )
                )
            } catch {
                results.append(
                    PolisherEvaluationResult(
                        id: testCase.id,
                        expected: testCase.expected,
                        candidate: "",
                        normalized: preparation.normalizedText,
                        finalText: preparation.normalizedText,
                        accepted: false,
                        exactMatch: false,
                        pipelineExactMatch: preparation.normalizedText == testCase.expected,
                        rejection: "runtimeError.\(type(of: error))",
                        failure: String(describing: type(of: error)),
                        durationMilliseconds: generationStarted.duration(to: .now).milliseconds,
                        promptDurationMilliseconds: 0,
                        generationDurationMilliseconds: 0,
                        reusedPromptTokens: 0,
                        promptTokens: 0,
                        outputTokens: 0,
                        processingLanguage: preparation.language.rawValue,
                        profile: preparation.profile.rawValue,
                        mode: (testCase.mode ?? .faithful).rawValue,
                        protectedTokenCount: preparation.protectedTokens.count,
                        qwenRequested: preparation.shouldUsePolisher,
                        route: "deterministicFallback",
                        polisherOutcome: "generationError",
                        repairedSentenceCount: 0,
                        v3Status: nil,
                        v3Rejection: nil,
                        v3AcceptedEditCount: nil,
                        v3RejectedEditCount: nil,
                        v3RepairedClauseCount: nil
                    )
                )
            }
            let latest = results[results.count - 1]
            write(
                "polisher_suite processed=\(index + 1)/\(suite.cases.count) "
                    + "accepted=\(latest.accepted) duration_ms=\(latest.durationMilliseconds)\n",
                to: .standardError
            )
        }

        let durations = results.map(\.durationMilliseconds).sorted()
        let payload = PolisherEvaluationOutput(
            schemaVersion: 1,
            promptVersion: generationConfiguration.promptStyle.versionIdentifier,
            modelPath: modelRoot.lastPathComponent,
            caseCount: results.count,
            acceptedCount: results.count(where: \.accepted),
            exactMatchCount: results.count(where: \.exactMatch),
            pipelineExactMatchCount: results.count(where: \.pipelineExactMatch),
            warmupDurationMilliseconds: warmupDurationMilliseconds,
            meanDurationMilliseconds: durations.isEmpty
                ? 0 : durations.reduce(0, +) / durations.count,
            p50DurationMilliseconds: percentile(0.50, values: durations),
            p95DurationMilliseconds: percentile(0.95, values: durations),
            maximumKVCacheSize: generationConfiguration.maximumKVCacheSize,
            prefillStepSize: generationConfiguration.prefillStepSize,
            usesPromptPrefixCache: generationConfiguration.usesPromptPrefixCache,
            results: results,
            promptLookupTokens: generationConfiguration.promptLookupTokenCount,
            mlxMemory: await runtime.memorySnapshot(),
            adapterMode: adapterRoot != nil
                ? "explicit" : (useInstalledAdapter ? "installed" : "none")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(payload))
        FileHandle.standardOutput.write(Data("\n".utf8))
        return results.count == suite.cases.count ? 0 : 1
    }

    /// The same suite through the production path — `DictationTextProcessor`, its timeouts,
    /// its run-of-sentences handling of long transcripts — rather than one bare runtime call.
    /// Token counts are not available on this path and read as zero.
    static func runSuiteThroughProcessor(
        modelRoot: URL, suiteURL: URL, adapterRoot: URL?, useInstalledAdapter: Bool,
        generationConfiguration: QwenPolisherGenerationConfiguration,
        prefetchReplay: Bool
    ) async throws -> Int32 {
        let suite = try JSONDecoder().decode(
            PolisherEvaluationSuite.self,
            from: Data(contentsOf: suiteURL)
        )
        let processor = DictationTextProcessor(
            modelRoot: modelRoot, adapterRoot: adapterRoot,
            useInstalledAdapter: useInstalledAdapter,
            generationConfiguration: generationConfiguration
        )
        let warmupStarted = ContinuousClock.now
        try await processor.warmUp()
        let warmupDurationMilliseconds = warmupStarted.duration(to: .now).milliseconds
        var results = [PolisherEvaluationResult]()
        results.reserveCapacity(suite.cases.count)

        for (index, testCase) in suite.cases.enumerated() {
            let request = TextProcessingRequest(
                rawTranscript: testCase.transcript,
                preferredLanguage: testCase.language.textLanguage,
                fallbackLanguage: testCase.fallbackLanguage ?? .english,
                preferences: TextProcessingPreferences(
                    cleanupMode: testCase.mode ?? .faithful,
                    fastPathEnabled: true,
                    profile: testCase.profile ?? .automatic
                ),
                personalization: PersonalizationSnapshot(),
                featureFlags: TextQualityFeatureFlags(
                    textQualityV3Shadow: true,
                    editGateV3: true
                )
            )
            let preparation = DeterministicTextProcessor.prepare(request)
            let sessionID = UUID()
            var prefetchSeconds: TimeInterval = 0
            var prefetchGeneratedCalls = 0
            if prefetchReplay {
                await processor.beginPrefetchSession(sessionID)
                let words = request.rawTranscript.split(whereSeparator: \.isWhitespace)
                // Explicit text-only replay, not a claim about acoustic preview
                // stability. The separate audio replay measures actual ASR misses.
                for count in stride(from: 90, to: words.count, by: 45) {
                    var partial = request
                    partial.rawTranscript = words.prefix(count).joined(separator: " ")
                    let result = await processor.prefetch(partial, sessionID: sessionID)
                    prefetchSeconds += result.durationSeconds
                    prefetchGeneratedCalls += result.generatedCallCount
                }
            }
            let started = ContinuousClock.now
            let processed = await processor.process(
                preparation, request: request, sessionID: prefetchReplay ? sessionID : nil)
            let duration = started.duration(to: .now).milliseconds
            if prefetchReplay { await processor.endPrefetchSession(sessionID) }
            let accepted = processed.route == .qwen
            results.append(
                PolisherEvaluationResult(
                    id: testCase.id,
                    expected: testCase.expected,
                    candidate: processed.modelCandidate ?? "",
                    normalized: preparation.normalizedText,
                    finalText: processed.text,
                    accepted: accepted,
                    exactMatch: accepted && processed.text == testCase.expected,
                    pipelineExactMatch: processed.text == testCase.expected,
                    rejection: processed.rejectionReason?.rawValue,
                    failure: processed.failure?.rawValue,
                    durationMilliseconds: duration,
                    promptDurationMilliseconds: 0,
                    generationDurationMilliseconds: Int(
                        processed.polishingDurationSeconds * 1_000),
                    reusedPromptTokens: 0,
                    promptTokens: 0,
                    outputTokens: processed.generatedOutputTokenCount,
                    processingLanguage: preparation.language.rawValue,
                    profile: preparation.profile.rawValue,
                    mode: (testCase.mode ?? .faithful).rawValue,
                    protectedTokenCount: preparation.protectedTokens.count,
                    qwenRequested: preparation.shouldUsePolisher,
                    route: processed.route.rawValue,
                    polisherOutcome: processed.polisherOutcome.rawValue,
                    repairedSentenceCount: processed.repairedSentenceCount,
                    v3Status: processed.v3ShadowDecision?.status.rawValue,
                    v3Rejection: processed.v3ShadowDecision?.rejectionReason?.rawValue,
                    v3AcceptedEditCount: processed.v3ShadowDecision?.acceptedEditCount,
                    v3RejectedEditCount: processed.v3ShadowDecision?.rejectedEditCount,
                    v3RepairedClauseCount: processed.v3ShadowDecision?.repairedClauseCount,
                    reusedOutputTokens: processed.reusedOutputTokenCount,
                    generatedCalls: processed.generatedCallCount,
                    reusedCalls: processed.reusedCallCount,
                    prefetchDurationMilliseconds: Int(prefetchSeconds * 1_000),
                    prefetchGeneratedCalls: prefetchGeneratedCalls
                )
            )
            let latest = results[results.count - 1]
            write(
                "polisher_suite processed=\(index + 1)/\(suite.cases.count) "
                    + "route=\(processed.route.rawValue) duration_ms=\(latest.durationMilliseconds)\n",
                to: .standardError
            )
        }

        // Fast-path completions below the millisecond resolution are still
        // observations. Dropping zeros biases every summary toward Qwen calls.
        let durations = results.map(\.durationMilliseconds).sorted()
        let payload = PolisherEvaluationOutput(
            schemaVersion: 1,
            promptVersion: generationConfiguration.promptStyle.versionIdentifier,
            modelPath: modelRoot.lastPathComponent,
            caseCount: results.count,
            acceptedCount: results.count(where: \.accepted),
            exactMatchCount: results.count(where: \.exactMatch),
            pipelineExactMatchCount: results.count(where: \.pipelineExactMatch),
            warmupDurationMilliseconds: warmupDurationMilliseconds,
            meanDurationMilliseconds: durations.isEmpty
                ? 0 : durations.reduce(0, +) / durations.count,
            p50DurationMilliseconds: percentile(0.50, values: durations),
            p95DurationMilliseconds: percentile(0.95, values: durations),
            maximumKVCacheSize: generationConfiguration.maximumKVCacheSize,
            prefillStepSize: generationConfiguration.prefillStepSize,
            usesPromptPrefixCache: generationConfiguration.usesPromptPrefixCache,
            results: results,
            promptLookupTokens: generationConfiguration.promptLookupTokenCount,
            adapterMode: adapterRoot != nil
                ? "explicit" : (useInstalledAdapter ? "installed" : "none"),
            replayKind: prefetchReplay ? "progressive-text-only" : "none"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(payload))
        FileHandle.standardOutput.write(Data("\n".utf8))
        return results.count == suite.cases.count ? 0 : 1
    }

    static func percentile(_ percentile: Double, values: [Int]) -> Int {
        guard !values.isEmpty else {
            return 0
        }
        let index = Int((Double(values.count - 1) * percentile).rounded())
        return values[index]
    }
}

private struct AudioReplayPreviewMetrics: Codable, Sendable {
    // Attempt wall times include cancelled work; token counters below retain
    // their legacy meaning and cover completed previews only.
    var attemptedPreviewCount = 0
    var cancelledPreviewCount = 0
    var cancelledWaitCount = 0
    var asrAttemptCount = 0
    var cleanupAttemptCount = 0
    var asrAttemptMilliseconds = 0
    var cleanupAttemptMilliseconds = 0
    var asrAttemptAfterStopMilliseconds = 0
    var cleanupAttemptAfterStopMilliseconds = 0

    mutating func recordASRAttempt(
        from start: ContinuousClock.Instant, to end: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant
    ) {
        asrAttemptMilliseconds += start.duration(to: end).milliseconds
        asrAttemptAfterStopMilliseconds += max(
            0, max(start, deadline).duration(to: end).milliseconds)
    }

    mutating func recordCleanupAttempt(
        from start: ContinuousClock.Instant, to end: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant
    ) {
        cleanupAttemptMilliseconds += start.duration(to: end).milliseconds
        cleanupAttemptAfterStopMilliseconds += max(
            0, max(start, deadline).duration(to: end).milliseconds)
    }

    var previewCount = 0
    var asrMilliseconds = 0
    var cleanupMilliseconds = 0
    var generatedCalls = 0
    var reusedCalls = 0
    var generatedTokens = 0
    var failures = 0
    var cleanupFailedCalls = 0
    var reusedEncoderChunks = 0
}

private struct AudioReplayPass: Codable, Sendable {
    let releaseToTextMilliseconds: Int
    let releaseDispatchMilliseconds: Int
    let asrMilliseconds: Int
    let producerDrainMilliseconds: Int
    let textMilliseconds: Int
    let generatedCalls: Int
    let reusedCalls: Int
    let generatedOutputTokens: Int
    let reusedOutputTokens: Int
    let wordCount: Int
    let reusedEncoderChunks: Int
    let rawTextSHA256: String
    let finalTextSHA256: String
    let failure: String?
    let inputKind: String
    let audioLoadMilliseconds: Int
    let delivery: DeliveryProbeResult?
}

private struct AudioReplayReport: Codable, Sendable {
    let schemaVersion = 6
    let replayKind: String
    let afterStopTimerOrigin: String
    let stopSleepTolerance: String
    let previewWorkClock =
        "API wall times for all started calls, including cancelled calls; after-stop overlap split separately; token counts cover completed previews"
    let audioSeconds: Double
    let mode: String
    let baseline: AudioReplayPass
    let anticipated: AudioReplayPass
    let freshControl: AudioReplayPass
    let previews: AudioReplayPreviewMetrics
    let identicalASR: Bool
    let identicalFinalText: Bool
    let sourceAudioSeconds: Double
    let croppedToRequestedDuration: Bool
    let asrPreparationMilliseconds: Int
    let asrWarmupMilliseconds: Int
    let polisherLoadAndWarmupMilliseconds: Int
    let thermalState: Int
    let lowPowerMode: Bool
}

private struct DeliveryProbeResult: Codable, Sendable {
    let endpoint = "TextEdit AX value observed; not a compositor frame timestamp"
    let scope = "diagnostic only; no live microphone or global dictation shortcut"
    let observed: Bool
    let releaseToObservedTextMilliseconds: Int?
    let lastAbsentMilliseconds: Int?
    let releaseToDeliveryReturnMilliseconds: Int
    let insertionMethod: String?
    let failure: String?
}

/// Explicit opt-in diagnostic. It never quits VoxoL, edits an existing document,
/// changes privacy permissions, or closes whatever happens to be in front.
@MainActor
private final class OwnedTextEditProbe {
    private let injector = TextInjector()
    private let documentID: String

    init() throws {
        guard AXIsProcessTrusted() else {
            throw TextInjectionError.accessibilityPermissionMissing
        }
        documentID = try Self.script(
            """
            tell application "TextEdit"
                set probeDocument to make new document with properties {text:""}
                activate
                return id of probeDocument as text
            end tell
            """)
        guard !documentID.isEmpty,
            documentID.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) })
        else {
            throw TextInjectionError.focusedElementUnavailable
        }
    }

    func close() {
        _ = try? Self.script(
            "tell application \"TextEdit\" to close document id \(documentID) saving no")
    }

    func prepareTarget() throws -> TextInsertionTarget {
        let frontID = try Self.script(
            "tell application \"TextEdit\" to return id of front document as text")
        guard frontID == documentID,
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit"
        else { throw TextInjectionError.focusedElementUnavailable }
        _ = try Self.script(
            "tell application \"TextEdit\" to set text of document id \(documentID) to \"\"")
        let target = try injector.captureTarget()
        guard injector.currentText(of: target) == "" else {
            throw TextInjectionError.focusedElementUnavailable
        }
        return target
    }

    func deliver(
        _ text: String, to target: TextInsertionTarget, releasedAt: ContinuousClock.Instant
    ) async -> DeliveryProbeResult {
        let observer = Task { @MainActor [injector] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var lastAbsent: Int?
            while ContinuousClock.now < deadline, !Task.isCancelled {
                let value = injector.currentText(of: target)
                let elapsed = releasedAt.duration(to: .now).milliseconds
                if !text.isEmpty, value == text {
                    return (observed: elapsed as Int?, lastAbsent: lastAbsent)
                }
                if value != nil { lastAbsent = elapsed }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return (observed: nil as Int?, lastAbsent: lastAbsent)
        }
        await Task.yield()
        var method: TextInsertionMethod?
        var failure: String?
        do {
            method = try await injector.insert(text, target: target)
        } catch {
            failure = String(describing: error)
            observer.cancel()
        }
        let returned = releasedAt.duration(to: .now).milliseconds
        let observation = await observer.value
        return DeliveryProbeResult(
            observed: failure == nil && observation.observed != nil,
            releaseToObservedTextMilliseconds: observation.observed,
            lastAbsentMilliseconds: observation.lastAbsent,
            releaseToDeliveryReturnMilliseconds: returned,
            insertionMethod: method.map { String(describing: $0) },
            failure: failure ?? (observation.observed == nil ? "visibilityNotObserved" : nil)
        )
    }

    private static func script(_ source: String) throws -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            throw NSError(domain: "VoxoLTextEditProbe", code: 1, userInfo: error as? [String: Any])
        }
        guard let result else { throw TextInjectionError.focusedElementUnavailable }
        return result.stringValue ?? ""
    }
}

private struct PolisherEvaluationSuite: Decodable {
    let cases: [PolisherEvaluationCase]
}

private struct PolisherEvaluationCase: Decodable {
    enum Language: String, Decodable {
        case french = "fr"
        case english = "en"
        case automatic = "auto"
        case spanish = "es"

        var textLanguage: TextLanguage? {
            switch self {
            case .french:
                .french
            case .english:
                .english
            case .automatic, .spanish:
                nil
            }
        }
    }

    let id: String
    let language: Language
    let transcript: String
    let expected: String
    let profile: WritingProfile?
    let fallbackLanguage: TextLanguage?
    /// Which contract the expected text was written under. Absent means the faithful one.
    let mode: CleanupMode?
    let timeoutMilliseconds: Int?
}

private struct PolisherEvaluationResult: Encodable {
    let id: String
    let expected: String
    let candidate: String
    let normalized: String
    let finalText: String
    let accepted: Bool
    let exactMatch: Bool
    let pipelineExactMatch: Bool
    let rejection: String?
    let failure: String?
    let durationMilliseconds: Int
    let promptDurationMilliseconds: Int
    let generationDurationMilliseconds: Int
    let reusedPromptTokens: Int
    let promptTokens: Int
    let outputTokens: Int
    let processingLanguage: String
    let profile: String
    let mode: String
    let protectedTokenCount: Int
    let qwenRequested: Bool
    let route: String
    let polisherOutcome: String
    let repairedSentenceCount: Int
    let v3Status: String?
    let v3Rejection: String?
    let v3AcceptedEditCount: Int?
    let v3RejectedEditCount: Int?
    let v3RepairedClauseCount: Int?
    var proposedDraftTokens: Int? = nil
    var acceptedDraftTokens: Int? = nil
    var draftVerifications: Int? = nil
    var replayedTokens: Int? = nil
    var reusedOutputTokens: Int? = nil
    var generatedCalls: Int? = nil
    var reusedCalls: Int? = nil
    var prefetchDurationMilliseconds: Int? = nil
    var prefetchGeneratedCalls: Int? = nil
}

private struct PolisherEvaluationOutput: Encodable {
    let schemaVersion: Int
    let promptVersion: String
    let modelPath: String
    let caseCount: Int
    let acceptedCount: Int
    let exactMatchCount: Int
    let pipelineExactMatchCount: Int
    let warmupDurationMilliseconds: Int
    let meanDurationMilliseconds: Int
    let p50DurationMilliseconds: Int
    let p95DurationMilliseconds: Int
    let maximumKVCacheSize: Int?
    let prefillStepSize: Int
    let usesPromptPrefixCache: Bool
    let results: [PolisherEvaluationResult]
    var promptLookupTokens: Int? = nil
    var mlxMemory: QwenPolisherMemorySnapshot? = nil
    var adapterMode: String? = nil
    var replayKind: String? = nil
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
