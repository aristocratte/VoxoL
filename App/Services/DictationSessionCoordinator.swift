import AppKit
import ContextKit
import Foundation
import Observation
import PersonalizationKit
import TextProcessingKit
import os

enum DictationRuntimeState: Equatable {
    case waitingForInputMonitoring
    case ready
    case listening
    case speechDetected
    case transcribing
    case polishing
    case inserting
    case captureNeedsModel
    case noSpeech
    case insertionSucceeded(TextInsertionMethod)
    case copiedForManualPaste
    case failed
}

struct AudioCaptureSummary: Equatable {
    let durationSeconds: TimeInterval
    let sampleCount: Int
    let droppedSampleCount: Int
    let speechDetected: Bool
    let maximumRootMeanSquare: Float

    var maximumLevelDBFS: Double {
        guard maximumRootMeanSquare > 0 else {
            return -80
        }
        return max(-80, 20 * log10(Double(maximumRootMeanSquare)))
    }

    var normalizedMaximumLevel: Double {
        min(1, max(0, (maximumLevelDBFS + 60) / 60))
    }
}

enum DictationSessionOutcome: Equatable {
    case captured
    case noSpeech
    case transcribed
    case inserted(TextInsertionMethod)
    case copiedForManualPaste
    case failed
}

enum SpeechRecognitionEngine: String, Equatable {
    case appleFrench
    case appleEnglish
    case parakeetAutomatic
    case parakeetFallback
}

struct DictationSessionReport: Equatable {
    let capture: AudioCaptureSummary
    var releaseToCaptureStopDurationSeconds: TimeInterval?
    var transcriptCharacterCount: Int?
    var speechRecognitionEngine: SpeechRecognitionEngine?
    var inferenceDurationSeconds: TimeInterval?
    var melExtractionDurationSeconds: TimeInterval?
    var encoderDurationSeconds: TimeInterval?
    var decoderDurationSeconds: TimeInterval?
    var detokenizationDurationSeconds: TimeInterval?
    var releaseToASRDurationSeconds: TimeInterval?
    var asrAttemptCount: Int?
    var asrUsedFallbackSegmentation: Bool?
    var asrEmittedTokenCount: Int?
    var asrMeanTokenLogitMargin: Double?
    var asrLowerDecileTokenLogitMargin: Double?
    var asrMeanDurationLogitMargin: Double?
    var asrLowerDecileDurationLogitMargin: Double?
    var asrBlankDecisionRatio: Double?
    var asrMaximumFramesWithoutEmission: Int?
    var asrMinimumOverlapTokenAgreement: Double?
    var normalizationDurationSeconds: TimeInterval?
    var polishingDurationSeconds: TimeInterval?
    var releaseToTextReadyDurationSeconds: TimeInterval?
    var insertionDurationSeconds: TimeInterval?
    var releaseToPasteDurationSeconds: TimeInterval?
    var processingRoute: TextProcessingRoute?
    var processingFallback: TextProcessingFailure?
    var fidelityRejectionReason: String?
    var outcome: DictationSessionOutcome
    var failureReason: String?
}

struct DictationPipelineTrace: Equatable, Identifiable {
    let id: UUID
    let createdAt: Date
    let rawTranscript: String
    let finalText: String
    let speechRecognitionEngine: SpeechRecognitionEngine
    let processingRoute: TextProcessingRoute
    let asrDurationSeconds: TimeInterval
    let polishingDurationSeconds: TimeInterval
}

private struct LocalSpeechResult {
    let text: String
    let inferenceDurationSeconds: TimeInterval
    let melExtractionDurationSeconds: TimeInterval?
    let encoderDurationSeconds: TimeInterval?
    let decoderDurationSeconds: TimeInterval?
    let detokenizationDurationSeconds: TimeInterval?
    let engine: SpeechRecognitionEngine
    let attemptCount: Int
    let usedFallbackSegmentation: Bool
    let confidence: TranscriptionConfidence?
    /// Per-word decoder confidence, Parakeet only. Feeds the shadow repair
    /// log; the Apple path has no equivalent signal.
    let repairShadowWords: [(word: String, margin: Float)]?
}

/// Owns the Phase 1 shortcut, microphone capture and deterministic insertion test.
@MainActor
@Observable
final class DictationSessionCoordinator {
    static let shared = DictationSessionCoordinator()

    private(set) var state = DictationRuntimeState.waitingForInputMonitoring
    private(set) var lastCapture: AudioCaptureSummary?
    private(set) var lastReport: DictationSessionReport?
    private(set) var lastError: String?
    private(set) var liveInputLevel: Float = 0
    private(set) var livePartialTranscript = ""
    private(set) var pipelineTraces: [DictationPipelineTrace] = []
    /// True while a preflight rehearsal owns the current capture. The session runs the real
    /// pipeline, but the result is handed back instead of being inserted, and history is skipped.
    private(set) var rehearsalIsActive = false

    @ObservationIgnored private var rehearsalHandler: ((String, String) -> Void)?

    @ObservationIgnored private let permissions: PermissionCoordinator
    @ObservationIgnored private let audioCapture: AudioCaptureSession
    @ObservationIgnored private let injector: TextInjector
    @ObservationIgnored private let contextProvider = MacOSContextProvider()
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.voxol.VoxoL",
        category: "dictation"
    )
    @ObservationIgnored private let performanceSignposter = OSSignposter(
        subsystem: "com.voxol.VoxoL",
        category: "dictation-performance"
    )
    @ObservationIgnored private var hotkeyMonitor: GlobalHotkeyMonitor!
    @ObservationIgnored private var speechRuntime: ParakeetRuntime?
    @ObservationIgnored private let appleSpeechRuntime = AppleDictationRuntime()
    @ObservationIgnored private var configuredModelRoot: URL?
    @ObservationIgnored private var configuredPolisherRoot: URL?
    @ObservationIgnored private var textProcessor = DictationTextProcessor(modelRoot: nil)
    @ObservationIgnored private var personalizationStore: PersonalizationStore?
    @ObservationIgnored private lazy var correctionWatcher = InsertionCorrectionWatcher(
        injector: injector
    )
    @ObservationIgnored private var transcriptStore: TranscriptStore?
    @ObservationIgnored private var shortcutHeld = false
    @ObservationIgnored private var toggleSessionIsActive = false
    @ObservationIgnored private var holdToTalk = HoldToTalkStateMachine()
    @ObservationIgnored private var destinationApplicationName = "Unknown"
    @ObservationIgnored private var destinationBundleIdentifier: String?
    @ObservationIgnored private var destinationInsertionTarget: TextInsertionTarget?
    @ObservationIgnored private var destinationContext: ContextSnapshot?
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?
    @ObservationIgnored private var modelPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var polisherPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var languagePreparationTask: Task<Void, Never>?
    @ObservationIgnored private var levelPollingTask: Task<Void, Never>?
    @ObservationIgnored private var partialTranscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var capsuleDismissalTask: Task<Void, Never>?

    init(
        permissions: PermissionCoordinator = .shared,
        audioCapture: AudioCaptureSession = AudioCaptureSession(),
        injector: TextInjector = TextInjector()
    ) {
        self.permissions = permissions
        self.audioCapture = audioCapture
        self.injector = injector
        hotkeyMonitor = GlobalHotkeyMonitor { [weak self] action in
            self?.handle(action)
        }
    }

    var shortcutIsActive: Bool {
        hotkeyMonitor.isRunning
    }

    func pressDictationTrigger() {
        handle(.dictationPressed)
    }

    func releaseDictationTrigger() {
        handle(.dictationReleased)
    }

    /// Starts one real capture → transcription → polish pass for the preflight rehearsal.
    /// `onResult` receives the raw transcript and the finished text; nothing is inserted into
    /// another application and nothing is written to history.
    func beginRehearsal(onResult: @escaping (String, String) -> Void) {
        guard !audioCapture.isRecording, transcriptionTask == nil else {
            return
        }
        rehearsalHandler = onResult
        rehearsalIsActive = true
        shortcutHeld = true
        holdToTalk.handle(.shortcutPressed)
        Task { @MainActor [weak self] in
            await self?.beginDictation()
        }
    }

    func endRehearsal() {
        guard rehearsalIsActive else {
            return
        }
        shortcutHeld = false
        holdToTalk.handle(.shortcutReleased)
        finishDictation(releasedAt: ContinuousClock().now)
    }

    func cancelRehearsal() {
        guard rehearsalIsActive else {
            return
        }
        abandonRehearsal()
        cancelDictation()
    }

    /// Hands the finished texts to the waiting rehearsal, if one owns this session.
    private func resolveRehearsal(raw: String, polished: String) -> Bool {
        guard rehearsalIsActive else {
            return false
        }
        let handler = rehearsalHandler
        abandonRehearsal()
        handler?(raw, polished)
        return true
    }

    private func abandonRehearsal() {
        rehearsalIsActive = false
        rehearsalHandler = nil
    }

    func toggleDictationFromInterface() {
        if shortcutHeld || audioCapture.isRecording {
            toggleSessionIsActive = false
            shortcutHeld = false
            holdToTalk.handle(.shortcutReleased)
            finishDictation(releasedAt: ContinuousClock().now)
        } else {
            guard transcriptionTask == nil else { return }
            shortcutHeld = true
            holdToTalk.handle(.shortcutPressed)
            Task { @MainActor [weak self] in
                await self?.beginDictation()
            }
        }
    }

    func configureASR(modelRoot: URL, transcriptStore: TranscriptStore) {
        self.transcriptStore = transcriptStore
        guard configuredModelRoot != modelRoot else {
            return
        }

        configuredModelRoot = modelRoot
        modelPreparationTask?.cancel()
        let runtime = ParakeetRuntime(modelRoot: modelRoot, computeUnits: .all)
        speechRuntime = runtime
        modelPreparationTask = Task { @MainActor [weak self, runtime] in
            do {
                try await runtime.prepare()
                self?.logger.notice("Parakeet runtime prepared")
                self?.refreshDecodingBias()
            } catch is CancellationError {
                return
            } catch {
                self?.logger.error("Parakeet preparation failed: \(error.localizedDescription)")
                self?.lastError = error.localizedDescription
            }
            self?.modelPreparationTask = nil
        }
    }

    /// Records a repair the user made in the destination app, so the dictionary
    /// can learn the word that was misheard.
    ///
    /// Gated on the same two switches as every other form of learning: this
    /// reads the contents of another application's text field, and doing that
    /// without consent is not a feature. Private mode declines outright.
    private func watchForCorrection(
        target: TextInsertionTarget,
        insertedText: String,
        rawTranscript: String,
        bundleIdentifier: String?
    ) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "voxol.learningEnabled"),
            !defaults.bool(forKey: "voxol.privateMode")
        else {
            correctionWatcher.cancel()
            return
        }
        correctionWatcher.watch(
            target: target,
            insertedText: insertedText
        ) { [weak self] corrected in
            guard let personalizationStore = self?.personalizationStore else { return }
            Task {
                await personalizationStore.addCorrection(
                    CorrectionPair(
                        rawTranscript: rawTranscript,
                        correctedText: corrected,
                        bundleIdentifier: bundleIdentifier,
                        profile: .automatic,
                        language: .any
                    )
                )
            }
        }
    }

    func configureTextProcessing(
        modelRoot: URL?,
        personalizationStore: PersonalizationStore
    ) {
        self.personalizationStore = personalizationStore
        refreshDecodingBias()
        guard configuredPolisherRoot != modelRoot else {
            return
        }

        configuredPolisherRoot = modelRoot
        polisherPreparationTask?.cancel()
        let processor = DictationTextProcessor(modelRoot: modelRoot)
        textProcessor = processor
        guard modelRoot != nil else {
            polisherPreparationTask = nil
            return
        }

        polisherPreparationTask = Task { @MainActor [weak self, processor] in
            do {
                try await processor.warmUp()
                self?.logger.notice("Qwen text runtime prepared")
            } catch is CancellationError {
                return
            } catch {
                self?.logger.error(
                    "Qwen preparation failed type=\(String(describing: type(of: error)), privacy: .public)"
                )
            }
            self?.polisherPreparationTask = nil
        }
    }

    /// Points the next capture at a specific microphone, or back at the system default.
    ///
    /// Applied to the session rather than to a running engine: switching input mid-sentence would
    /// change the audio format under the converter, so a change takes effect on the next hold.
    func configureInputDevice(uid: String?) {
        let resolved = (uid?.isEmpty ?? true) ? nil : uid
        guard audioCapture.preferredInputUID != resolved else {
            return
        }
        audioCapture.preferredInputUID = resolved
        logger.notice(
            "Input device preference set selected=\(resolved != nil, privacy: .public)"
        )
    }

    /// The microphone the current or last capture actually used, when one was forced.
    var activeInputUID: String? {
        audioCapture.activeInputUID
    }

    func configureDictationLanguage(_ preference: DictationLanguagePreference) {
        languagePreparationTask?.cancel()
        languagePreparationTask = nil
        guard let localeIdentifier = preference.localeIdentifier else {
            return
        }

        let runtime = appleSpeechRuntime
        languagePreparationTask = Task { @MainActor [weak self, runtime] in
            do {
                try await runtime.prepare(localeIdentifier: localeIdentifier)
                self?.logger.notice(
                    "Language-locked speech runtime prepared locale=\(localeIdentifier, privacy: .public)"
                )
            } catch is CancellationError {
                return
            } catch {
                self?.logger.notice(
                    "Language-locked speech runtime unavailable; Parakeet fallback remains active"
                )
            }
        }
    }

    func activate() {
        guard availabilityTask == nil else {
            return
        }
        refreshShortcutAvailability()
        availabilityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshShortcutAvailability()
            }
        }
    }

    func deactivate() {
        availabilityTask?.cancel()
        availabilityTask = nil
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        polisherPreparationTask?.cancel()
        polisherPreparationTask = nil
        languagePreparationTask?.cancel()
        languagePreparationTask = nil
        levelPollingTask?.cancel()
        levelPollingTask = nil
        partialTranscriptionTask?.cancel()
        partialTranscriptionTask = nil
        transcriptionTask?.cancel()
        destinationInsertionTarget = nil
        destinationContext = nil
        toggleSessionIsActive = false
        liveInputLevel = 0
        livePartialTranscript = ""
        capsuleDismissalTask?.cancel()
        capsuleDismissalTask = nil
        hotkeyMonitor.stop()
        if audioCapture.isRecording {
            _ = audioCapture.stop()
        }
        state = .waitingForInputMonitoring
    }

    func diagnosticsExportData() throws -> Data {
        let export = DictationDiagnosticsExport(
            exportedAt: Date(),
            promptVersion: PolishingPrompt.version,
            asrConfigured: configuredModelRoot != nil,
            polisherConfigured: configuredPolisherRoot != nil,
            lastSession: lastReport.map(DictationDiagnosticSession.init)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }

    func clearPipelineTraces() {
        pipelineTraces = []
    }

    func copyPipelineTraces() {
        guard !pipelineTraces.isEmpty else {
            return
        }
        let export = DictationPipelineTraceExport(
            traces: pipelineTraces.reversed().map(DictationPipelineTraceExport.Item.init)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(export),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private extension DictationSessionCoordinator {
    func refreshShortcutAvailability() {
        permissions.refresh()
        guard !hotkeyMonitor.isRunning else {
            if state == .waitingForInputMonitoring {
                state = .ready
            }
            return
        }

        if hotkeyMonitor.start(), state == .waitingForInputMonitoring {
            state = .ready
        } else if !audioCapture.isRecording {
            state = .waitingForInputMonitoring
        }
    }

    func handle(_ action: GlobalHotkeyAction) {
        switch action {
        case .dictationPressed:
            if usesToggleToTalk {
                if toggleSessionIsActive {
                    toggleSessionIsActive = false
                    shortcutHeld = false
                    holdToTalk.handle(.shortcutReleased)
                    finishDictation(releasedAt: ContinuousClock().now)
                } else {
                    guard transcriptionTask == nil else {
                        return
                    }
                    toggleSessionIsActive = true
                    shortcutHeld = true
                    holdToTalk.handle(.shortcutPressed)
                    Task { @MainActor [weak self] in
                        await self?.beginDictation()
                    }
                }
            } else {
                shortcutHeld = true
                holdToTalk.handle(.shortcutPressed)
                Task { @MainActor [weak self] in
                    await self?.beginDictation()
                }
            }
        case .dictationReleased:
            guard !usesToggleToTalk else {
                return
            }
            shortcutHeld = false
            holdToTalk.handle(.shortcutReleased)
            finishDictation(releasedAt: ContinuousClock().now)
        case .insertionTestRequested:
            Task { @MainActor [weak self] in
                await self?.runInsertionTest()
            }
        case .cancelRequested:
            cancelDictation()
        }
    }

    func beginDictation() async {
        guard !audioCapture.isRecording, transcriptionTask == nil else {
            return
        }

        capsuleDismissalTask?.cancel()
        capsuleDismissalTask = nil
        lastError = nil
        lastReport = nil
        liveInputLevel = 0
        permissions.refresh()
        if permissions.microphone == .notRequested {
            await permissions.request(.microphone)
        }
        guard permissions.microphone == .granted, shortcutHeld else {
            if shortcutHeld {
                state = .failed
                lastError = "Microphone permission is unavailable."
                VoiceCapsuleController.shared.showError(.microphoneUnavailable)
                dismissCapsule(after: .seconds(2))
            }
            toggleSessionIsActive = false
            abandonRehearsal()
            return
        }

        do {
            let destination = NSWorkspace.shared.frontmostApplication
            destinationApplicationName = destination?.localizedName ?? "Unknown"
            destinationBundleIdentifier = destination?.bundleIdentifier
            destinationInsertionTarget = rehearsalIsActive ? nil : (try? injector.captureTarget())
            if setting("voxol.contextEnabled", default: true) {
                destinationContext = contextProvider.capture()
            } else {
                destinationContext = ContextSnapshot(
                    bundleIdentifier: destinationBundleIdentifier,
                    applicationName: destinationApplicationName
                )
            }
            try audioCapture.start()
            holdToTalk.handle(.captureStarted)
            state = .listening
            VoiceCapsuleController.shared.show(.listening)
            startStatusPolling()
            startPartialTranscription()
        } catch {
            toggleSessionIsActive = false
            destinationInsertionTarget = nil
            destinationContext = nil
            abandonRehearsal()
            state = .failed
            lastError = error.localizedDescription
            VoiceCapsuleController.shared.showError(.microphoneUnavailable)
            dismissCapsule(after: .seconds(2))
        }
    }

    func startStatusPolling() {
        levelPollingTask?.cancel()
        levelPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, audioCapture.isRecording else {
                    return
                }
                let status = audioCapture.status
                liveInputLevel = max(status.currentRootMeanSquare, liveInputLevel * 0.72)
                VoiceCapsuleController.shared.updateInputLevel(liveInputLevel)
                if status.speechDetected, !holdToTalk.speechWasDetected {
                    holdToTalk.handle(.endpointDetectedSpeech)
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func startPartialTranscription() {
        partialTranscriptionTask?.cancel()
        livePartialTranscript = ""
        guard
            setting("voxol.streamingEnabled", default: true),
            dictationLanguagePreference == .automatic,
            let speechRuntime
        else {
            return
        }
        partialTranscriptionTask = Task { @MainActor [weak self, speechRuntime] in
            var tracker = StableTranscriptTracker()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_250))
                guard !Task.isCancelled, let self, audioCapture.isRecording else {
                    return
                }
                guard await speechRuntime.isReady else {
                    continue
                }
                let samples = audioCapture.snapshotSamples(maximumCount: 20 * 16_000)
                guard samples.count >= 24_000 else {
                    continue
                }
                do {
                    let partial = try await speechRuntime.transcribe(samples: samples)
                    try Task.checkCancellation()
                    guard audioCapture.isRecording else {
                        return
                    }
                    livePartialTranscript = tracker.observe(partial.text)
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
            }
        }
    }

    func finishDictation(releasedAt: ContinuousClock.Instant) {
        guard audioCapture.isRecording else {
            return
        }
        let clock = ContinuousClock()
        performanceSignposter.emitEvent("ShortcutReleased")
        shortcutHeld = false
        toggleSessionIsActive = false
        levelPollingTask?.cancel()
        levelPollingTask = nil
        partialTranscriptionTask?.cancel()
        partialTranscriptionTask = nil
        guard let capturedAudio = audioCapture.stop() else {
            return
        }
        let captureStoppedAt = clock.now
        performanceSignposter.emitEvent("CaptureStopped")
        liveInputLevel = 0
        livePartialTranscript = ""
        VoiceCapsuleController.shared.updateInputLevel(0)

        let captureSummary = AudioCaptureSummary(
            durationSeconds: capturedAudio.durationSeconds,
            sampleCount: capturedAudio.samples.count,
            droppedSampleCount: capturedAudio.droppedSampleCount,
            speechDetected: capturedAudio.speechDetected,
            maximumRootMeanSquare: capturedAudio.maximumRootMeanSquare
        )
        lastCapture = captureSummary
        lastReport = DictationSessionReport(
            capture: captureSummary,
            releaseToCaptureStopDurationSeconds: seconds(
                releasedAt.duration(to: captureStoppedAt)
            ),
            outcome: .captured
        )
        logger.notice(
            "Capture completed duration_ms=\(Int(capturedAudio.durationSeconds * 1_000), privacy: .public) samples=\(capturedAudio.samples.count, privacy: .public) peak_millirms=\(Int(capturedAudio.maximumRootMeanSquare * 1_000), privacy: .public) detector=\(capturedAudio.speechDetected, privacy: .public)"
        )

        let insertionTarget = destinationInsertionTarget
        destinationInsertionTarget = nil
        let capturedContext = destinationContext
        destinationContext = nil
        // Endpointing drives live feedback only. The push-to-talk capture and
        // ASR result are authoritative, avoiding false negatives on quiet mics.
        guard capturedAudio.samples.count >= 1_600 else {
            showNoSpeech()
            return
        }

        let languagePreference = dictationLanguagePreference
        guard speechRuntime != nil || languagePreference.localeIdentifier != nil else {
            abandonRehearsal()
            updateLastReport { report in
                report.outcome = .failed
                report.failureReason = "The transcription model is unavailable."
            }
            state = .captureNeedsModel
            VoiceCapsuleController.shared.showError(.modelsUnavailable)
            dismissCapsule(after: .seconds(2))
            return
        }

        state = .transcribing
        VoiceCapsuleController.shared.show(.transcribing)
        let applicationName = destinationApplicationName
        let bundleIdentifier = destinationBundleIdentifier
        let processingContext = textProcessingContext(
            capturedContext,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier
        )
        let processingPreferences = textProcessingPreferences()
        let personalization = personalizationStore?.snapshot ?? PersonalizationSnapshot()
        let effectiveProfile = ProfileResolver.resolve(
            requested: processingPreferences.profile,
            context: processingContext,
            personalization: personalization
        )
        let speechContextualStrings = SpeechContextVocabulary.terms(
            profile: effectiveProfile,
            context: processingContext,
            personalization: personalization
        )
        // Canonical dictionary terms only — the repair candidates. The wider
        // speech-context list adds application names and developer terms,
        // which are boost material, not things a mistake should be rewritten
        // into.
        let repairShadowDictionary = personalization.dictionaryEntries(
            for: processingContext.bundleIdentifier
        ).map(\.canonical)
        let appleSpeechRuntime = appleSpeechRuntime
        transcriptionTask = Task {
            @MainActor [
                weak self, speechRuntime, appleSpeechRuntime, languagePreference,
                speechContextualStrings, repairShadowDictionary
            ] in
            guard let self else {
                return
            }
            defer { transcriptionTask = nil }
            var textForRecovery: String?

            // The same vocabulary Apple's recognizer gets has to reach Parakeet,
            // and it can only be built now: it depends on which application the
            // text is going into, which is unknown until dictation starts. A
            // term the user says in Cursor is not the one they say in Mail.
            if let speechRuntime {
                await speechRuntime.applyDecodingBias(
                    vocabulary: speechContextualStrings,
                    languageCode: languagePreference.decodingLanguageCode
                )
            }

            do {
                let result = try await transcribe(
                    samples: capturedAudio.samples,
                    languagePreference: languagePreference,
                    parakeetRuntime: speechRuntime,
                    appleSpeechRuntime: appleSpeechRuntime,
                    contextualStrings: speechContextualStrings
                )
                try Task.checkCancellation()
                if let words = result.repairShadowWords, !words.isEmpty {
                    let isPrivate = setting("voxol.privateMode", default: false)
                    Task.detached(priority: .utility) {
                        RepairShadowRecorder.record(
                            words: words,
                            dictionary: repairShadowDictionary,
                            privateMode: isPrivate
                        )
                    }
                }
                let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawText.isEmpty else {
                    showNoSpeech()
                    return
                }
                updateLastReport { report in
                    report.inferenceDurationSeconds = result.inferenceDurationSeconds
                    report.melExtractionDurationSeconds =
                        result.melExtractionDurationSeconds
                    report.encoderDurationSeconds = result.encoderDurationSeconds
                    report.decoderDurationSeconds = result.decoderDurationSeconds
                    report.detokenizationDurationSeconds =
                        result.detokenizationDurationSeconds
                    report.releaseToASRDurationSeconds = seconds(
                        releasedAt.duration(to: clock.now)
                    )
                    report.speechRecognitionEngine = result.engine
                    report.asrAttemptCount = result.attemptCount
                    report.asrUsedFallbackSegmentation =
                        result.usedFallbackSegmentation
                    report.asrEmittedTokenCount =
                        result.confidence?.emittedTokenCount
                    report.asrMeanTokenLogitMargin =
                        result.confidence?.meanTokenLogitMargin
                    report.asrLowerDecileTokenLogitMargin =
                        result.confidence?.lowerDecileTokenLogitMargin
                    report.asrMeanDurationLogitMargin =
                        result.confidence?.meanDurationLogitMargin
                    report.asrLowerDecileDurationLogitMargin =
                        result.confidence?.lowerDecileDurationLogitMargin
                    report.asrBlankDecisionRatio =
                        result.confidence?.blankDecisionRatio
                    report.asrMaximumFramesWithoutEmission =
                        result.confidence?.maximumFramesWithoutEmission
                    report.asrMinimumOverlapTokenAgreement =
                        result.confidence?.minimumOverlapTokenAgreement
                    report.outcome = .transcribed
                }
                performanceSignposter.emitEvent("ASRCompleted")

                logger.notice(
                    "Speech inference completed engine=\(result.engine.rawValue, privacy: .public) duration_ms=\(Int(result.inferenceDurationSeconds * 1_000), privacy: .public) attempts=\(result.attemptCount, privacy: .public) confidence_fallback=\(result.usedFallbackSegmentation, privacy: .public) characters=\(rawText.count, privacy: .public)"
                )

                let normalizationStarted = clock.now
                let preparation = DeterministicTextProcessor.prepare(
                    TextProcessingRequest(
                        rawTranscript: rawText,
                        preferredLanguage: languagePreference.textLanguage,
                        context: processingContext,
                        preferences: processingPreferences,
                        personalization: personalization
                    )
                )
                let normalizationDuration = seconds(
                    normalizationStarted.duration(to: clock.now)
                )
                performanceSignposter.emitEvent("NormalizationCompleted")

                if preparation.shouldUsePolisher, await textProcessor.isPolisherReady {
                    state = .polishing
                    VoiceCapsuleController.shared.show(.polishing)
                }
                let processed = await textProcessor.process(preparation)
                try Task.checkCancellation()
                performanceSignposter.emitEvent("TextProcessingCompleted")
                let text = processed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    showNoSpeech()
                    return
                }
                let textForInsertion = InsertionTextPolicy.adjust(
                    text,
                    beforeCursor: capturedContext?.beforeCursor ?? "",
                    afterCursor: capturedContext?.afterCursor ?? ""
                )
                textForRecovery = textForInsertion
                if setting("voxol.correctionCapture", default: false),
                    !setting("voxol.privateMode", default: false) {
                    PersonalBenchmarkRecorder.record(
                        samples: capturedAudio.samples,
                        rawText: rawText,
                        finalText: textForInsertion,
                        engine: result.engine.rawValue,
                        language: languagePreference.decodingLanguageCode ?? "auto",
                        application: processingContext.bundleIdentifier
                    )
                }
                updateLastReport { report in
                    report.transcriptCharacterCount = text.count
                    report.normalizationDurationSeconds = normalizationDuration
                    report.polishingDurationSeconds = processed.polishingDurationSeconds
                    report.releaseToTextReadyDurationSeconds = seconds(
                        releasedAt.duration(to: clock.now)
                    )
                    report.processingRoute = processed.route
                    report.processingFallback = processed.failure
                    report.fidelityRejectionReason = processed.rejectionReason?.rawValue
                }
                appendPipelineTrace(
                    rawTranscript: rawText,
                    finalText: text,
                    result: result,
                    processed: processed
                )
                let fallbackName = processed.failure?.rawValue ?? "none"
                let rejectionName = processed.rejectionReason?.rawValue ?? "none"
                logger.notice(
                    "Text processing completed route=\(processed.route.rawValue, privacy: .public) normalization_ms=\(Int(normalizationDuration * 1_000), privacy: .public) polishing_ms=\(Int(processed.polishingDurationSeconds * 1_000), privacy: .public) fallback=\(fallbackName, privacy: .public) rejection=\(rejectionName, privacy: .public)"
                )

                if resolveRehearsal(raw: rawText, polished: text) {
                    updateLastReport { report in
                        report.outcome = .transcribed
                        report.failureReason = nil
                    }
                    state = .ready
                    VoiceCapsuleController.shared.show(.success)
                    dismissCapsule(after: .milliseconds(900))
                    return
                }

                if let transcriptStore {
                    let revisions =
                        rawText == text
                        ? []
                        : [TranscriptRevision(text: rawText, createdAt: Date())]
                    await transcriptStore.add(
                        TranscriptRecord(
                            createdAt: Date(),
                            applicationName: applicationName,
                            applicationBundleIdentifier: bundleIdentifier,
                            text: text,
                            durationSeconds: capturedAudio.durationSeconds,
                            revisions: revisions
                        )
                    )
                }

                state = .inserting
                VoiceCapsuleController.shared.show(.inserting)
                let insertionStartedAt = clock.now
                performanceSignposter.emitEvent("InsertionRequested")
                let method = try await injector.insert(textForInsertion, target: insertionTarget)
                try Task.checkCancellation()
                let insertionCompletedAt = clock.now
                performanceSignposter.emitEvent("InsertionCompleted")

                updateLastReport { report in
                    report.insertionDurationSeconds = seconds(
                        insertionStartedAt.duration(to: insertionCompletedAt)
                    )
                    report.releaseToPasteDurationSeconds = seconds(
                        releasedAt.duration(to: insertionCompletedAt)
                    )
                    report.outcome = .inserted(method)
                    report.failureReason = nil
                }
                logger.notice(
                    "Text delivery succeeded method=\(String(describing: method), privacy: .public)"
                )

                state = .insertionSucceeded(method)
                VoiceCapsuleController.shared.show(.success)
                dismissCapsule(after: .milliseconds(900))

                if let insertionTarget {
                    watchForCorrection(
                        target: insertionTarget,
                        insertedText: textForInsertion,
                        rawTranscript: textForInsertion,
                        bundleIdentifier: bundleIdentifier
                    )
                }
            } catch is CancellationError {
                abandonRehearsal()
                state = .ready
                VoiceCapsuleController.shared.dismiss()
            } catch let error as TextInjectionError {
                lastError = error.localizedDescription
                logger.error(
                    "Text delivery failed error=\(error.localizedDescription, privacy: .public)"
                )

                if let textForRecovery,
                    InsertionRecoveryPolicy.allowsManualClipboardRecovery(for: error),
                    (try? injector.copyForManualPaste(textForRecovery)) != nil
                {
                    updateLastReport { report in
                        report.outcome = .copiedForManualPaste
                        report.failureReason = error.localizedDescription
                    }
                    state = .copiedForManualPaste
                    VoiceCapsuleController.shared.show(.copiedFallback)
                    dismissCapsule(after: .seconds(3))
                } else {
                    updateLastReport { report in
                        report.outcome = .failed
                        report.failureReason = error.localizedDescription
                    }
                    state = .failed
                    VoiceCapsuleController.shared.showError(.insertionFailed)
                    dismissCapsule(after: .seconds(2))
                }
            } catch {
                abandonRehearsal()
                state = .failed
                lastError = error.localizedDescription
                updateLastReport { report in
                    report.outcome = .failed
                    report.failureReason = error.localizedDescription
                }
                logger.error("Speech transcription failed: \(error.localizedDescription)")
                VoiceCapsuleController.shared.showError(.transcriptionFailed)
                dismissCapsule(after: .seconds(2))
            }
        }
    }

    func cancelDictation() {
        abandonRehearsal()
        shortcutHeld = false
        toggleSessionIsActive = false
        holdToTalk.handle(.cancelled)
        levelPollingTask?.cancel()
        levelPollingTask = nil
        partialTranscriptionTask?.cancel()
        partialTranscriptionTask = nil
        transcriptionTask?.cancel()
        destinationInsertionTarget = nil
        destinationContext = nil
        if audioCapture.isRecording {
            _ = audioCapture.stop()
        }
        liveInputLevel = 0
        livePartialTranscript = ""
        VoiceCapsuleController.shared.updateInputLevel(0)
        state = .ready
        VoiceCapsuleController.shared.dismiss()
    }

    func runInsertionTest() async {
        guard !audioCapture.isRecording, transcriptionTask == nil else {
            return
        }
        capsuleDismissalTask?.cancel()
        capsuleDismissalTask = nil
        lastError = nil
        VoiceCapsuleController.shared.show(.inserting)
        let insertionTarget = try? injector.captureTarget()

        do {
            let method = try await injector.insert(
                insertionTestText,
                target: insertionTarget
            )
            logger.notice(
                "Insertion probe succeeded method=\(String(describing: method), privacy: .public)"
            )
            state = .insertionSucceeded(method)
            VoiceCapsuleController.shared.show(.success)
            dismissCapsule(after: .milliseconds(900))
        } catch {
            state = .failed
            lastError = error.localizedDescription
            logger.error(
                "Insertion probe failed error=\(error.localizedDescription, privacy: .public)"
            )
            VoiceCapsuleController.shared.showError(.insertionFailed)
            dismissCapsule(after: .seconds(2))
        }
    }

    var insertionTestText: String {
        let language = UserDefaults.standard.string(forKey: "voxol.interfaceLanguage")
        if language == "fr" {
            return "Test VoxoL — insertion locale réussie."
        }
        return "VoxoL test — local insertion succeeded."
    }

    var usesToggleToTalk: Bool {
        UserDefaults.standard.string(forKey: "voxol.activationMode") == "toggle"
    }

    /// Pushes the user's dictionary and language choice into ASR decoding.
    ///
    /// The dictionary used to reach only text post-processing, which cannot
    /// help: once the decoder has emitted "cul bernetes" no string replacement
    /// recovers "Kubernetes". Biasing the decoder is the only place a personal
    /// term can be won back, and it is the advantage a cloud service cannot
    /// copy without holding the dictionary on its servers.
    ///
    /// Automatic language sends nil rather than a guess: the penalty suppresses
    /// English function words, so guessing French on English speech would strip
    /// the transcript.
    func refreshDecodingBias() {
        guard let speechRuntime else { return }
        let terms = (personalizationStore?.snapshot.dictionary ?? [])
            .map(\.canonical)
            .filter { !$0.isEmpty }
        let languageCode: String? =
            switch dictationLanguagePreference {
            case .french: "fr"
            case .english: "en"
            case .automatic: nil
            }
        Task { [speechRuntime, terms, languageCode] in
            await speechRuntime.applyDecodingBias(
                vocabulary: terms,
                languageCode: languageCode
            )
        }
    }

    var dictationLanguagePreference: DictationLanguagePreference {
        let rawValue =
            UserDefaults.standard.string(forKey: "voxol.dictationLanguage")
            ?? DictationLanguagePreference.preferred.rawValue
        return DictationLanguagePreference(rawValue: rawValue) ?? .preferred
    }

    func transcribe(
        samples: [Float],
        languagePreference: DictationLanguagePreference,
        parakeetRuntime: ParakeetRuntime?,
        appleSpeechRuntime: AppleDictationRuntime,
        contextualStrings: [String]
    ) async throws -> LocalSpeechResult {
        if let localeIdentifier = languagePreference.localeIdentifier {
            do {
                let result = try await appleSpeechRuntime.transcribe(
                    samples: samples,
                    localeIdentifier: localeIdentifier,
                    contextualStrings: contextualStrings
                )
                return LocalSpeechResult(
                    text: result.text,
                    inferenceDurationSeconds: result.inferenceDurationSeconds,
                    melExtractionDurationSeconds: nil,
                    encoderDurationSeconds: nil,
                    decoderDurationSeconds: nil,
                    detokenizationDurationSeconds: nil,
                    engine: languagePreference == .french ? .appleFrench : .appleEnglish,
                    attemptCount: 1,
                    usedFallbackSegmentation: false,
                    confidence: nil,
                    repairShadowWords: nil
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.notice(
                    "Language-locked speech inference unavailable; using Parakeet fallback"
                )
            }
        }

        guard let parakeetRuntime else {
            throw ParakeetError.runtimeUnavailable
        }
        let result = try await parakeetRuntime.transcribe(samples: samples)
        return LocalSpeechResult(
            text: result.text,
            inferenceDurationSeconds: result.inferenceDurationSeconds,
            melExtractionDurationSeconds: result.timing.melExtract,
            encoderDurationSeconds: result.timing.encoder,
            decoderDurationSeconds: result.timing.decoderLoop,
            detokenizationDurationSeconds: result.timing.detokenize,
            engine: languagePreference == .automatic
                ? .parakeetAutomatic : .parakeetFallback,
            attemptCount: result.inferenceAttemptCount,
            usedFallbackSegmentation: result.usedFallbackSegmentation,
            confidence: result.confidence,
            repairShadowWords: await parakeetRuntime.wordConfidences(for: result)
        )
    }

    func textProcessingPreferences() -> TextProcessingPreferences {
        let cleanupMode =
            CleanupMode(
                rawValue: UserDefaults.standard.string(forKey: "voxol.cleanupMode") ?? "faithful"
            ) ?? .faithful
        let selectedProfile =
            WritingProfile(
                rawValue: UserDefaults.standard.string(forKey: "voxol.writingProfile")
                    ?? "automatic"
            ) ?? .automatic
        return TextProcessingPreferences(
            cleanupMode: cleanupMode,
            removeFillers: setting("voxol.removeFillers", default: true),
            automaticLists: setting("voxol.automaticLists", default: true),
            fastPathEnabled: setting("voxol.fastPathEnabled", default: true),
            profile: cleanupMode == .raw ? .raw : selectedProfile
        )
    }

    func textProcessingContext(
        _ snapshot: ContextSnapshot?,
        applicationName: String,
        bundleIdentifier: String?
    ) -> TextProcessingContext {
        guard let snapshot, !snapshot.isSecure else {
            return TextProcessingContext(
                bundleIdentifier: bundleIdentifier,
                applicationName: applicationName
            )
        }
        let nearbyTextEnabled = setting("voxol.nearbyTextEnabled", default: true)
        return TextProcessingContext(
            bundleIdentifier: snapshot.bundleIdentifier ?? bundleIdentifier,
            applicationName: snapshot.applicationName,
            domain: setting("voxol.websiteDomainEnabled", default: true)
                ? snapshot.domain : nil,
            selectedText: snapshot.selectedText,
            beforeCursor: nearbyTextEnabled ? snapshot.beforeCursor : "",
            afterCursor: nearbyTextEnabled ? snapshot.afterCursor : ""
        )
    }

    func setting(_ key: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    func dismissCapsule(after delay: Duration) {
        capsuleDismissalTask?.cancel()
        capsuleDismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            VoiceCapsuleController.shared.dismiss()
            self?.capsuleDismissalTask = nil
            self?.settleAfterOutcome()
        }
    }

    /// Returns the runtime to rest once an outcome has been shown.
    ///
    /// Without this the last outcome is also the current status: one failed insertion left the
    /// interface reading "failed" for the rest of the session, which the Hub then rendered as a
    /// broken setup. A finished dictation — succeeded, failed or silent — is over.
    private func settleAfterOutcome() {
        guard !audioCapture.isRecording, transcriptionTask == nil, !shortcutHeld else {
            return
        }
        switch state {
        case .insertionSucceeded, .copiedForManualPaste, .noSpeech, .failed:
            state = hotkeyMonitor.isRunning ? .ready : .waitingForInputMonitoring
        default:
            break
        }
    }

    func showNoSpeech() {
        abandonRehearsal()
        updateLastReport { report in
            report.outcome = .noSpeech
        }
        state = .noSpeech
        VoiceCapsuleController.shared.show(.noSpeech)
        dismissCapsule(after: .milliseconds(1_200))
    }

    func updateLastReport(_ mutation: (inout DictationSessionReport) -> Void) {
        guard var report = lastReport else {
            return
        }
        mutation(&report)
        lastReport = report
    }

    func appendPipelineTrace(
        rawTranscript: String,
        finalText: String,
        result: LocalSpeechResult,
        processed: DictationTextProcessingResult
    ) {
        guard setting("voxol.pipelineInspectorEnabled", default: false),
            !setting("voxol.privateMode", default: false)
        else {
            return
        }
        pipelineTraces.insert(
            DictationPipelineTrace(
                id: UUID(),
                createdAt: Date(),
                rawTranscript: rawTranscript,
                finalText: finalText,
                speechRecognitionEngine: result.engine,
                processingRoute: processed.route,
                asrDurationSeconds: result.inferenceDurationSeconds,
                polishingDurationSeconds: processed.polishingDurationSeconds
            ),
            at: 0
        )
        if pipelineTraces.count > 20 {
            pipelineTraces.removeLast(pipelineTraces.count - 20)
        }
    }

    func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private struct DictationDiagnosticsExport: Encodable {
    let schemaVersion = 1
    let exportedAt: Date
    let promptVersion: String
    let asrConfigured: Bool
    let polisherConfigured: Bool
    let lastSession: DictationDiagnosticSession?
}

private struct DictationPipelineTraceExport: Encodable {
    let schemaVersion = 1
    let traces: [Item]

    struct Item: Encodable {
        let id: UUID
        let createdAt: Date
        let rawTranscript: String
        let finalText: String
        let speechRecognitionEngine: String
        let processingRoute: String
        let asrMilliseconds: Int
        let polishingMilliseconds: Int

        init(_ trace: DictationPipelineTrace) {
            id = trace.id
            createdAt = trace.createdAt
            rawTranscript = trace.rawTranscript
            finalText = trace.finalText
            speechRecognitionEngine = trace.speechRecognitionEngine.rawValue
            processingRoute = trace.processingRoute.rawValue
            asrMilliseconds = Int(trace.asrDurationSeconds * 1_000)
            polishingMilliseconds = Int(trace.polishingDurationSeconds * 1_000)
        }
    }
}

private struct DictationDiagnosticSession: Encodable {
    let audioDurationMilliseconds: Int
    let releaseToCaptureStopMilliseconds: Int?
    let sampleCount: Int
    let droppedSampleCount: Int
    let speechDetected: Bool
    let maximumLevelDBFS: Double
    let transcriptCharacterCount: Int?
    let speechRecognitionEngine: String?
    let asrMilliseconds: Int?
    let melExtractionMilliseconds: Int?
    let encoderMilliseconds: Int?
    let decoderMilliseconds: Int?
    let detokenizationMilliseconds: Int?
    let releaseToASRMilliseconds: Int?
    let asrAttemptCount: Int?
    let asrUsedFallbackSegmentation: Bool?
    let asrEmittedTokenCount: Int?
    let asrMeanTokenLogitMargin: Double?
    let asrLowerDecileTokenLogitMargin: Double?
    let asrMeanDurationLogitMargin: Double?
    let asrLowerDecileDurationLogitMargin: Double?
    let asrBlankDecisionRatio: Double?
    let asrMaximumFramesWithoutEmission: Int?
    let asrMinimumOverlapTokenAgreement: Double?
    let normalizationMilliseconds: Int?
    let polishingMilliseconds: Int?
    let releaseToTextReadyMilliseconds: Int?
    let insertionMilliseconds: Int?
    let releaseToPasteMilliseconds: Int?
    let processingRoute: String?
    let fallbackReason: String?
    let rejectionReason: String?
    let outcome: String
    let failed: Bool

    init(_ report: DictationSessionReport) {
        audioDurationMilliseconds = Int(report.capture.durationSeconds * 1_000)
        releaseToCaptureStopMilliseconds =
            report.releaseToCaptureStopDurationSeconds.map { Int($0 * 1_000) }
        sampleCount = report.capture.sampleCount
        droppedSampleCount = report.capture.droppedSampleCount
        speechDetected = report.capture.speechDetected
        maximumLevelDBFS = report.capture.maximumLevelDBFS
        transcriptCharacterCount = report.transcriptCharacterCount
        speechRecognitionEngine = report.speechRecognitionEngine?.rawValue
        asrMilliseconds = report.inferenceDurationSeconds.map { Int($0 * 1_000) }
        melExtractionMilliseconds =
            report.melExtractionDurationSeconds.map { Int($0 * 1_000) }
        encoderMilliseconds = report.encoderDurationSeconds.map { Int($0 * 1_000) }
        decoderMilliseconds = report.decoderDurationSeconds.map { Int($0 * 1_000) }
        detokenizationMilliseconds =
            report.detokenizationDurationSeconds.map { Int($0 * 1_000) }
        releaseToASRMilliseconds =
            report.releaseToASRDurationSeconds.map { Int($0 * 1_000) }
        asrAttemptCount = report.asrAttemptCount
        asrUsedFallbackSegmentation =
            report.asrUsedFallbackSegmentation
        asrEmittedTokenCount = report.asrEmittedTokenCount
        asrMeanTokenLogitMargin = report.asrMeanTokenLogitMargin
        asrLowerDecileTokenLogitMargin =
            report.asrLowerDecileTokenLogitMargin
        asrMeanDurationLogitMargin = report.asrMeanDurationLogitMargin
        asrLowerDecileDurationLogitMargin =
            report.asrLowerDecileDurationLogitMargin
        asrBlankDecisionRatio = report.asrBlankDecisionRatio
        asrMaximumFramesWithoutEmission =
            report.asrMaximumFramesWithoutEmission
        asrMinimumOverlapTokenAgreement =
            report.asrMinimumOverlapTokenAgreement
        normalizationMilliseconds = report.normalizationDurationSeconds.map { Int($0 * 1_000) }
        polishingMilliseconds = report.polishingDurationSeconds.map { Int($0 * 1_000) }
        releaseToTextReadyMilliseconds =
            report.releaseToTextReadyDurationSeconds.map { Int($0 * 1_000) }
        insertionMilliseconds = report.insertionDurationSeconds.map { Int($0 * 1_000) }
        releaseToPasteMilliseconds = report.releaseToPasteDurationSeconds.map { Int($0 * 1_000) }
        processingRoute = report.processingRoute?.rawValue
        fallbackReason = report.processingFallback?.rawValue
        rejectionReason = report.fidelityRejectionReason
        outcome = String(describing: report.outcome)
        failed = report.outcome == .failed
    }
}


/// Appends shadow-repair observations to a local diagnostics file.
///
/// The repair feature itself is deliberately not enabled: measurement put the
/// confidence flag's precision at 23%, so an automatic substitution would
/// break about three words for every one it fixed. What is missing is
/// evidence from the owner's real dictation — prevalence, candidate coverage,
/// false-substitution opportunities — and this collects exactly that while
/// changing nothing.
///
/// The file lives with the app's other local data and never leaves the
/// machine. Private mode suppresses recording entirely. Growth stops at five
/// megabytes instead of rotating: by then the question this exists to answer
/// is answerable.
private enum RepairShadowRecorder {
    private static let maximumBytes: UInt64 = 5_000_000

    static func record(
        words: [(word: String, margin: Float)],
        dictionary: [String],
        privateMode: Bool
    ) {
        guard !privateMode, !words.isEmpty else { return }
        let proposals = RepairShadow.proposals(words: words, dictionary: dictionary)
        let flagged = words.filter {
            $0.margin <= RepairShadow.defaultMarginThreshold
        }
        let entry: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "words": words.count,
            "flagged": flagged.count,
            "dictionaryTerms": dictionary.count,
            "proposals": proposals.map { proposal in
                [
                    "heard": proposal.heard,
                    "candidate": proposal.candidate,
                    "index": proposal.index,
                    "margin": Double(proposal.margin),
                    "distance": proposal.distance,
                ] as [String: Any]
            },
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: entry),
            let line = String(data: data, encoding: .utf8)
        else { return }
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("VoxoL/Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let file = directory.appendingPathComponent("repair-shadow.jsonl")
            let payload = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                guard size < maximumBytes else { return }
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: file)
            }
        } catch {
            // Diagnostics must never interfere with dictation.
        }
    }
}


/// Saves each dictation locally so the owner can build a personal benchmark.
///
/// Every public corpus in the suite is someone else's voice reading someone
/// else's text; the only measurement that predicts this product's quality for
/// its owner is the owner's own dictation against the text they actually
/// wanted. Each session stores the audio, the raw recognition, the inserted
/// text, and a `corrected.txt` pre-filled with the inserted text — reviewing a
/// session means fixing that file. `build-personal-benchmark.py` turns the
/// reviewed sessions into a frozen benchmark and scores it.
///
/// Strictly opt-in, suppressed in private mode, nothing leaves the machine,
/// and recording stops at 500 MB rather than rotating away old sessions the
/// owner may not have reviewed yet.
private enum PersonalBenchmarkRecorder {
    private static let maximumBytes: UInt64 = 500_000_000
    private static let sampleRate = 16_000.0

    static func record(
        samples: [Float],
        rawText: String,
        finalText: String,
        engine: String,
        language: String,
        application: String?
    ) {
        guard !samples.isEmpty, !finalText.isEmpty else { return }
        Task.detached(priority: .utility) {
            write(
                samples: samples,
                rawText: rawText,
                finalText: finalText,
                engine: engine,
                language: language,
                application: application
            )
        }
    }

    private static func write(
        samples: [Float],
        rawText: String,
        finalText: String,
        engine: String,
        language: String,
        application: String?
    ) {
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("VoxoL/PersonalBenchmark", isDirectory: true)
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(
                at: sessions,
                withIntermediateDirectories: true
            )
            guard directorySize(root) < maximumBytes else { return }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let name =
                formatter.string(from: Date()) + "-"
                + UUID().uuidString.prefix(8).lowercased()
            let directory = sessions.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            try wavData(from: samples).write(
                to: directory.appendingPathComponent("audio.wav")
            )
            // Reviewing a session means editing this file to what should have
            // been written. Left untouched, it records "the output was right".
            try Data(finalText.utf8).write(
                to: directory.appendingPathComponent("corrected.txt")
            )
            let meta: [String: Any] = [
                "schemaVersion": 1,
                "date": ISO8601DateFormatter().string(from: Date()),
                "engine": engine,
                "language": language,
                "application": application ?? "unknown",
                "rawText": rawText,
                "finalText": finalText,
                "durationSeconds": Double(samples.count) / sampleRate,
            ]
            try JSONSerialization.data(
                withJSONObject: meta,
                options: [.sortedKeys]
            )
            .write(to: directory.appendingPathComponent("meta.json"))
        } catch {
            // A diagnostics feature must never be able to fail a dictation.
        }
    }

    private static func wavData(from samples: [Float]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32767)
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func append(_ text: String) { header.append(Data(text.utf8)) }
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        append("RIFF")
        append32(UInt32(36 + pcm.count))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * 2)
        append16(2)
        append16(16)
        append("data")
        append32(UInt32(pcm.count))
        return header + pcm
    }

    private static func directorySize(_ url: URL) -> UInt64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey]
            )
        else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            total += UInt64(
                (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
        }
        return total
    }
}
