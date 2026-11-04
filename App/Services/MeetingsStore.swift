import AppKit
import CryptoKit
import Foundation
import Observation
import QwenPolisher
import SpeakerKit
import UniformTypeIdentifiers

private struct ReportModelFileStamp: Equatable, Sendable {
    let filename: String
    let size: UInt64
    let modificationDateBits: UInt64
    let fileNumber: UInt64
}

private struct ReportModelVerificationHandle: Sendable {
    let stamp: [ReportModelFileStamp]
    let task: Task<URL, Error>
}

private struct ReportRuntimePreparationHandle: Sendable {
    let stamp: [ReportModelFileStamp]
    let task: Task<QwenPolisherRuntime, Error>
}

private actor ReportModelVerificationCache {
    static let shared = ReportModelVerificationCache()

    private var verifiedStamp: [ReportModelFileStamp]?
    private var verifiedDirectory: URL?
    private var inFlightStamp: [ReportModelFileStamp]?
    private var inFlightTask: Task<URL, Error>?

    func handle(
        stamp: [ReportModelFileStamp],
        verify: @escaping @Sendable () throws -> URL
    ) -> ReportModelVerificationHandle {
        if verifiedStamp == stamp, let verifiedDirectory {
            return ReportModelVerificationHandle(
                stamp: stamp, task: Task { verifiedDirectory })
        }
        if inFlightStamp == stamp, let inFlightTask {
            return ReportModelVerificationHandle(stamp: stamp, task: inFlightTask)
        }

        inFlightTask?.cancel()
        let task = Task.detached(priority: .utility) { try verify() }
        inFlightStamp = stamp
        inFlightTask = task
        Task { [weak self] in
            do {
                let directory = try await task.value
                await self?.verificationSucceeded(stamp: stamp, directory: directory)
            } catch {
                await self?.verificationFailed(stamp: stamp)
            }
        }
        return ReportModelVerificationHandle(stamp: stamp, task: task)
    }

    private func verificationSucceeded(stamp: [ReportModelFileStamp], directory: URL) {
        guard inFlightStamp == stamp else { return }
        verifiedStamp = stamp
        verifiedDirectory = directory
        inFlightStamp = nil
        inFlightTask = nil
    }

    private func verificationFailed(stamp: [ReportModelFileStamp]) {
        guard inFlightStamp == stamp else { return }
        inFlightStamp = nil
        inFlightTask = nil
    }
}

@MainActor
@Observable
final class MeetingsStore {
    static weak var activeStore: MeetingsStore?
    enum SaveState { case session, saving, saved, failed }
    private(set) var saveState: SaveState = .session
    private(set) var processingID: UUID?
    private(set) var reportStage = ""
    var reportStyle =
        MeetingReportStyle(
            rawValue: UserDefaults.standard.string(forKey: "voxol.meetings.reportStyle") ?? "")
        ?? .complete
    {
        didSet {
            UserDefaults.standard.set(reportStyle.rawValue, forKey: "voxol.meetings.reportStyle")
        }
    }
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var recordsDirty = false
    @ObservationIgnored private var recordSaveFailed = false
    @ObservationIgnored private var checkpointedIDs = Set<UUID>()
    @ObservationIgnored private var generationCache = [String: MeetingDocument]()
    @ObservationIgnored private var topicCache = [String: [MeetingDocumentTopic]]()

    enum Phase {
        case idle, checking, downloading, reading, transcribing, speakers, reporting, cancelling
    }
    private(set) var phase: Phase = .idle
    private(set) var speakerProgress: Double = 0
    private(set) var reportProgress: Double = 0
    private(set) var modelReady = false
    private(set) var records: [SpeakerTranscript] = []
    private(set) var reports: [UUID: MeetingReportDraft] = [:]
    private(set) var savedIDs: Set<UUID> = []
    var selection: UUID?
    var failure: String?
    let recorder = MeetingRecorder()
    let calendar = MeetingCalendarStore()
    private(set) var processingStartedAt: Date?
    private(set) var processingTitle = ""

    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var archiveWritable = true
    @ObservationIgnored private var savedRecords: [SpeakerTranscript] = []
    @ObservationIgnored private var reportArchiveWritable = true
    @ObservationIgnored private var reportSaveJob: Task<Void, Never>?
    @ObservationIgnored private let archive: SpeakerArchiveStore
    @ObservationIgnored private let reportArchive: MeetingReportArchiveStore
    let modelDirectory: URL

    var busy: Bool { phase != .idle || recorder.active }
    var selected: SpeakerTranscript? { records.first { $0.id == selection } }
    var selectedReport: MeetingReportDraft? { selection.flatMap { reports[$0] } }
    var reportModelAvailable: Bool {
        FileManager.default.fileExists(
            atPath: Self.reportModelDirectory().appendingPathComponent("model.safetensors").path)
    }
    private var maySave: Bool {
        UserDefaults.standard.bool(forKey: "voxol.historyEnabled")
            && !UserDefaults.standard.bool(forKey: "voxol.privateMode") && archiveWritable
    }

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxoL")
        var storage = support.appendingPathComponent("Meetings")
        var model = support.appendingPathComponent("Models/speakers/\(SpeakerModelAssets.revision)")
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["VOXOL_MEETINGS_ROOT"] {
                storage = URL(fileURLWithPath: path)
            }
            if let path = ProcessInfo.processInfo.environment["VOXOL_SPEAKERS_MODEL_ROOT"] {
                model = URL(fileURLWithPath: path)
            }
        #endif
        modelDirectory = model
        archive = SpeakerArchiveStore(url: storage.appendingPathComponent("meetings.json"))
        reportArchive = MeetingReportArchiveStore(
            url: storage.appendingPathComponent("reports.json"))
        Self.activeStore = self
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            savedRecords = try await archive.load()
            records = savedRecords
            savedIDs = Set(records.map(\.id))
            selection = nil
        } catch {
            archiveWritable = false
            failure = String(
                localized:
                    "Meeting history could not be opened. New results will stay in this session.")
        }
        do {
            let saved = try await reportArchive.load()
            let recordIDs = Set(savedRecords.map(\.id))
            reports = saved.reduce(into: [:]) { result, report in
                if recordIDs.contains(report.transcriptID) {
                    var migrated = report
                    if let transcript = records.first(where: { $0.id == report.transcriptID }) {
                        migrated.migrate(transcript: transcript)
                        if migrated.isCurrent(for: transcript) {
                            migrated.sourceFingerprint =
                                (try? MeetingReportDraft.fingerprint(of: transcript))
                                ?? migrated.sourceFingerprint
                        }
                    }
                    result[report.transcriptID] = migrated
                }
            }
        } catch {
            reportArchiveWritable = false
            failure = String(
                localized:
                    "Meeting reports could not be opened. New drafts will stay in this session.")
        }
        saveState = maySave ? .saved : .session
        guard job == nil else { return }
        phase = .checking
        let directory = modelDirectory
        modelReady = await Task.detached {
            (try? SpeakerModelAssets.verify(directory: directory)) != nil
        }.value
        phase = .idle
    }

    #if DEBUG
        /// In-memory fixtures for the isolated UI preview, never written to the archive.
        func configurePreview(_ state: String) {
            loaded = true
            archiveWritable = false
            reportArchiveWritable = false
            modelReady = true
            if state == "prose" {
                let turns: [SpeakerTurn] = [
                    .init(
                        id: 0, start: 12, end: 25, speakerIDs: [0], overlapping: false,
                        text: "La date de la migration reste à confirmer."),
                    .init(
                        id: 1, start: 30, end: 48, speakerIDs: [1], overlapping: false,
                        text: "Les tests ont révélé deux erreurs dans le parcours de paiement."),
                    .init(
                        id: 2, start: 53, end: 68, speakerIDs: [0], overlapping: false,
                        text: "Je vais préparer le correctif et transmettre les résultats vendredi."
                    ),
                ]
                var document = SpeakerTranscript(
                    title: "Aperçu · réunion fictive", duration: 92,
                    rawText: turns.map(\.text).joined(separator: " "), turns: turns,
                    diarizationRevision: "synthetic-preview")
                document.names = [0: "Alice", 1: "Bob"]
                let evidence = Dictionary(
                    uniqueKeysWithValues: turns.map {
                        ($0.id, MeetingReportEvidence(id: $0.id, turnID: $0.id, text: $0.text))
                    })
                let extraction = try? MeetingReportExtraction.parseDAQ(
                    "{\"d\":[],\"a\":[\"E2\"],\"q\":[\"E0\"]}", evidence: evidence)
                let narrative = MeetingReportNarrative(paragraphs: [
                    .init(
                        text:
                            "La réunion a porté sur la préparation de la migration. Sa date reste à confirmer. Les tests ont révélé deux erreurs dans le parcours de paiement, et Alice s'est engagée à préparer un correctif puis à transmettre les résultats vendredi.",
                        sourceTurnIDs: [0, 1, 2]),
                    .init(
                        text:
                            "Bob a décrit les erreurs constatées lors des tests. Alice a précisé qu'elle transmettrait les résultats vendredi. La date de la migration demeure ouverte dans la transcription.",
                        sourceTurnIDs: [0, 1, 2]),
                ])
                records = [document]
                selection = document.id
                if let extraction,
                    let fingerprint = try? MeetingReportDraft.fingerprint(of: document)
                {
                    reports[document.id] = MeetingReportDraft(
                        transcriptID: document.id, sourceFingerprint: fingerprint,
                        generator: "Aperçu synthétique",
                        markdown: MeetingReportMarkdown.render(
                            transcript: document, extractions: [extraction], french: true,
                            narratives: [narrative]))
                }
                phase = .idle
                return
            }
            let text = "Nous validons la maquette. Je prépare les retours pour vendredi."
            let document = SpeakerTranscript(
                title: "Démo · Revue de design", duration: 1245,
                rawText: text, turns: [], diarizationRevision: "synthetic-preview")
            records = [document]
            reports[document.id] = try? MeetingReportDraft.template(for: document, french: true)
            processingTitle = document.title
            processingStartedAt = Date()
            switch state {
            case "transcribing": phase = .transcribing
            case "speakers": phase = .speakers; speakerProgress = 0.46
            case "reporting": phase = .reporting; reportProgress = 0.65; selection = document.id
            default: phase = .idle
            }
        }
    #endif

    func installModel() {
        guard !busy else { return }
        phase = .downloading
        failure = nil
        let directory = modelDirectory
        job = Task {
            defer { phase = .idle; job = nil }
            let download = Task.detached {
                try await SpeakerModelAssets.install(directory: directory)
            }
            do {
                try await withTaskCancellationHandler {
                    try await download.value
                } onCancel: {
                    download.cancel()
                }
                try Task.checkCancellation()
                modelReady = true
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    func importAudio(asrDirectory: URL, french: Bool) {
        guard !busy, modelReady else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .video]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Transcribe")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribe(url: url, asrDirectory: asrDirectory, french: french)
    }

    private static func transcribeImportedAudio(
        at audioURL: URL,
        asrDirectory: URL
    ) async throws -> (transcript: Transcription, words: [SpeakerWord]) {
        // Keep the ASR runtime scoped to this phase so its Core ML models can be
        // released before the speaker models are loaded for very long imports.
        let runtime = ParakeetRuntime(modelRoot: asrDirectory, computeUnits: .gpu)
        let transcript = try await runtime.transcribe(audioURL: audioURL)
        let words = await runtime.wordEvidence(for: transcript).map { word in
            SpeakerWord(
                range: word.sourceRange,
                start: word.frameRange.map { Double($0.lowerBound) * 0.08 },
                end: word.frameRange.map { Double($0.upperBound) * 0.08 }
            )
        }
        return (transcript, words)
    }

    func transcribe(url: URL, asrDirectory: URL, french: Bool, title: String? = nil) {
        guard !busy, modelReady else { return }
        phase = .reading
        processingStartedAt = Date()
        processingTitle = title ?? url.deletingPathExtension().lastPathComponent
        failure = nil
        speakerProgress = 0
        reportProgress = 0
        let saveAllowedAtStart = maySave
        let recording = recorder.completedURL == url
        let event = recording ? recorder.calendarEvent : nil
        let notes = recording ? recorder.notes : ""
        let markers = recording ? recorder.markers : []
        let recordedAt = recording ? recorder.startedAt : nil
        job = Task {
            let securityScope = url.startAccessingSecurityScopedResource()
            defer {
                if securityScope { url.stopAccessingSecurityScopedResource() }
                phase = .idle
                job = nil
            }
            do {
                let prepared = try await MeetingMedia.prepare(url)
                defer { prepared.cleanup() }
                try Task.checkCancellation()
                phase = .transcribing
                let asr = try await Self.transcribeImportedAudio(
                    at: prepared.url,
                    asrDirectory: asrDirectory
                )
                let transcript = asr.transcript
                let words = asr.words
                try Task.checkCancellation()
                guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    failure = String(localized: "No speech was transcribed in this recording.")
                    return
                }
                let prestartedReportRuntime: ReportRuntimePreparationHandle?
                if reportModelAvailable {
                    let system =
                        Self.reportLikelyClassifierInstruction(transcript.text)
                        ?? Self.reportNarrativeInstruction(french: french)
                    prestartedReportRuntime = try? await Self.reportRuntimePreparationHandle(
                        system: system)
                } else {
                    prestartedReportRuntime = nil
                }
                phase = .speakers
                let activity = try await NativeSpeakerDiarizer().analyze(
                    audioURL: prepared.url, directory: modelDirectory
                ) { [weak self] value in
                    Task { @MainActor in
                        if self?.phase == .speakers { self?.speakerProgress = value }
                    }
                }
                try Task.checkCancellation()
                let duration = transcript.audioDurationSeconds
                let turns = try SpeakerAttribution.turns(
                    text: transcript.text, words: words,
                    probabilities: activity.probabilities, frameCount: activity.frameCount,
                    duration: duration)
                var result = SpeakerTranscript(
                    title: title ?? url.deletingPathExtension().lastPathComponent,
                    duration: duration, rawText: transcript.text, turns: turns,
                    diarizationRevision: SpeakerModelAssets.revision)
                result.meetingDate = event?.start ?? recordedAt
                result.calendarEvent = event
                result.personalNotes = notes
                result.markers = markers
                if let bookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                {
                    result.audioReference = .init(
                        bookmark: bookmark, filename: url.lastPathComponent)
                }
                processingID = result.id
                records.insert(result, at: 0)
                if recorder.completedURL == url { recorder.dismissRecording() }
                reports[result.id] = try MeetingReportDraft.template(for: result, french: french)
                if saveAllowedAtStart && maySave {
                    savedRecords.insert(result, at: 0)
                    await persist()
                    await persistReports()
                }
                // Open the new meeting after its transcript and draft are in the archive.
                selection = result.id
                if reportModelAvailable {
                    try Task.checkCancellation()
                    phase = .reporting
                    try await generateReportDraft(
                        for: result, french: french,
                        prestartedRuntime: prestartedReportRuntime)
                }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    func cancel() {
        guard job != nil else { return }
        phase = .cancelling
        job?.cancel()
    }

    func rename(speaker: Int, to name: String, in id: UUID) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(
            in: .whitespacesAndNewlines)
        records[index].names[speaker] = String(clean.prefix(80))
        reports[id]?.reviewedAt = nil
        scheduleReportSave()
        if maySave, let saved = savedRecords.firstIndex(where: { $0.id == id }) {
            savedRecords[saved] = records[index]
            await persist()
        }
    }

    func assign(speaker: Int?, turn: Int, document id: UUID) async {
        guard let record = records.firstIndex(where: { $0.id == id }),
            let index = records[record].turns.firstIndex(where: { $0.id == turn })
        else { return }
        records[record].turns[index].correctedSpeakerIDs = speaker.map { [$0] } ?? []
        reports[id]?.reviewedAt = nil
        scheduleReportSave()
        if maySave, let saved = savedRecords.firstIndex(where: { $0.id == id }) {
            savedRecords[saved] = records[record]
            await persist()
        }
    }

    func remove(_ id: UUID) async {
        // Deleting a saved meeting is explicit, even when private mode is on.
        reportSaveJob?.cancel()
        await reportSaveJob?.value
        let remaining = savedRecords.filter { $0.id != id }
        if remaining.count != savedRecords.count {
            do { try await archive.save(remaining) } catch {
                failure = error.localizedDescription; return
            }
        }
        savedRecords = remaining
        savedIDs = Set(remaining.map(\.id))
        records.removeAll { $0.id == id }
        reports[id] = nil
        if reportArchiveWritable {
            do {
                try await reportArchive.save(
                    reports.values.filter { savedIDs.contains($0.transcriptID) }
                        .sorted { $0.createdAt < $1.createdAt })
            } catch { failure = error.localizedDescription }
        }
        generationCache = generationCache.filter { !$0.key.hasPrefix(id.uuidString) }
        topicCache = topicCache.filter { !$0.key.hasPrefix(id.uuidString) }
        if selection == id { selection = nil }
    }

    func createReport(for id: UUID, french: Bool) async {
        guard let document = records.first(where: { $0.id == id }), reports[id] == nil else {
            return
        }
        do {
            reports[id] = try MeetingReportDraft.template(for: document, french: french)
            await persistReports()
        } catch { failure = error.localizedDescription }
    }

    func rewritePassage(_ blockID: UUID, in id: UUID, instruction: String, french: Bool) {
        guard !busy, let transcript = records.first(where: { $0.id == id }),
            let original = reports[id]?.content.blocks.first(where: { $0.id == blockID }),
            !original.sourceTurnIDs.isEmpty
        else { return }
        phase = .reporting
        processingID = id
        processingTitle = transcript.title
        reportStage = french ? "Réécriture du passage" : "Rewriting the passage"
        reportProgress = 0
        processingStartedAt = Date()
        failure = nil
        job = Task {
            defer { phase = .idle; job = nil }
            var runtime: QwenPolisherRuntime?
            do {
                let fingerprint = try MeetingReportDraft.fingerprint(of: transcript)
                let index = MeetingDocumentEvidenceIndex(transcript: transcript)
                let full = index.evidence.filter {
                    original.sourceTurnIDs.contains($0.value.turnID)
                }
                var evidence = [Int: MeetingReportEvidence]()
                var count = 0
                for source in full.values.sorted(by: { $0.id < $1.id }) {
                    guard count + source.text.count <= 8_000 else { break }
                    evidence[source.id] = source
                    count += source.text.count
                }
                guard !evidence.isEmpty else { throw MeetingReportGenerationError.invalidSource }
                let partition = MeetingReportExtraction.deterministicDAQPartition(
                    candidateIDs: evidence.keys.sorted(), evidence: evidence)
                let extracted = try MeetingReportExtraction.parseDAQ(
                    partition?.resolvedOutput ?? "{\"d\":[],\"a\":[],\"q\":[]}", evidence: evidence)
                let decisions = Set(
                    evidence.compactMap {
                        extracted.confirmedDecisionQuotes.contains($0.value.text) ? $0.key : nil
                    })
                let actions = Set(
                    evidence.compactMap { source in
                        extracted.confirmedActionQuotes.contains(source.value.text)
                            ? source.key : nil
                    })
                let system = MeetingDocumentGeneration.instruction(french: french)
                let prepared = try await Self.preparedReportRuntime(prestarted: nil)
                runtime = prepared
                let passages = evidence.values.sorted { $0.id < $1.id }.map {
                    "[E\($0.id)] \($0.text)"
                }.joined(separator: "\n")
                let output = try await prepared.generateStructured(
                    system: system,
                    user:
                        "Rewrite only this passage. \(instruction) Return paragraph blocks only. Preserve all facts and uncertainty.\n<draft>\(original.text)</draft>\n<transcript>\n\(passages)\n</transcript>",
                    maximumOutputTokens: 900, timeout: .seconds(180))
                var replacement = try MeetingDocumentGeneration.parse(
                    output.text, title: transcript.title,
                    evidence: evidence, transcript: transcript, decisionIDs: decisions,
                    actionIDs: actions)
                try Task.checkCancellation()
                guard var report = reports[id],
                    let current = records.first(where: { $0.id == id }),
                    try MeetingReportDraft.fingerprint(of: current) == fingerprint,
                    let position = report.content.blocks.firstIndex(where: { $0.id == blockID }),
                    report.content.blocks[position] == original
                else { throw MeetingReportGenerationError.invalidSource }
                replacement.blocks[0].id = blockID
                var proposed = report.content
                proposed.blocks.replaceSubrange(position...position, with: replacement.blocks)
                report.proposal = MeetingReportVersion(
                    document: proposed, sourceFingerprint: fingerprint,
                    generator: "Qwen local · passage v4")
                reports[id] = report
                reportProgress = 1
                await persistReports()
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            await runtime?.unload()
        }
    }

    func generateReport(for id: UUID, french: Bool) {
        guard !busy, let document = records.first(where: { $0.id == id }) else { return }
        phase = .reporting
        processingID = id
        processingStartedAt = Date()
        processingTitle = document.title
        reportProgress = 0
        failure = nil
        job = Task {
            defer { phase = .idle; job = nil }
            do { try await generateReportDraft(for: document, french: french) } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }

    func updateReport(_ markdown: String, for id: UUID) {
        updateDocument(.migrating(markdown, transcript: records.first { $0.id == id }), for: id)
    }

    func updateDocument(_ content: MeetingDocument, for id: UUID) {
        guard var report = reports[id], report.content != content else { return }
        if checkpointedIDs.insert(id).inserted { report.checkpoint() }
        report.replaceContent(content)
        reports[id] = report
        scheduleReportSave()
    }

    private func scheduleReportSave() {
        reportSaveJob?.cancel()
        saveRevision += 1
        guard maySave, reportArchiveWritable else { saveState = .session; return }
        saveState = .saving
        reportSaveJob = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.savePendingChanges()
        }
    }

    private func savePendingChanges() async {
        guard maySave else { saveState = .session; return }
        if recordsDirty {
            recordsDirty = false
            await persist()
            if recordSaveFailed { recordsDirty = true }
        }
        await persistReports()
    }

    func flushPendingSaves() async {
        reportSaveJob?.cancel()
        await savePendingChanges()
    }

    func acceptProposal(for id: UUID) {
        guard var report = reports[id], let proposal = report.proposal,
            let transcript = records.first(where: { $0.id == id }),
            (try? MeetingReportDraft.fingerprint(of: transcript)) == proposal.sourceFingerprint
        else { return }
        report.checkpoint()
        report.replaceContent(proposal.document)
        report.sourceFingerprint = proposal.sourceFingerprint
        report.generator = proposal.generator
        report.proposal = nil
        reports[id] = report
        checkpointedIDs.remove(id)
        scheduleReportSave()
    }

    func discardProposal(for id: UUID) {
        reports[id]?.proposal = nil
        scheduleReportSave()
    }

    func restoreVersion(_ version: MeetingReportVersion, for id: UUID) {
        guard var report = reports[id] else { return }
        report.checkpoint()
        report.replaceContent(version.document)
        report.sourceFingerprint = version.sourceFingerprint
        report.generator = version.generator
        reports[id] = report
        checkpointedIDs.remove(id)
        scheduleReportSave()
    }

    func markReviewed(_ reviewed: Bool, for id: UUID) {
        reports[id]?.reviewedAt = reviewed ? Date() : nil
        scheduleReportSave()
    }

    func updateMeeting(_ id: UUID, change: (inout SpeakerTranscript) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        if var report = reports[id], report.content.title != records[index].title {
            var content = report.content
            content.title = records[index].title
            report.replaceContent(content)
            reports[id] = report
            scheduleReportSave()
        }
        guard maySave, let saved = savedRecords.firstIndex(where: { $0.id == id }) else { return }
        savedRecords[saved] = records[index]
        recordsDirty = true
        scheduleReportSave()
    }

    func attachAudio(to id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .video]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            updateMeeting(id) {
                $0.audioReference = .init(bookmark: bookmark, filename: url.lastPathComponent)
            }
        } catch { failure = error.localizedDescription }
    }

    func exportReport(_ report: MeetingReportDraft, title: String, includeSources: Bool = true) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = title + " - compte rendu.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(
                report.content.markdown(
                    includeSources: includeSources, transcript: records.first { $0.id == report.id }
                ).utf8
            ).write(to: url, options: .atomic)
        } catch {
            failure = error.localizedDescription
        }
    }

    func exportWord(_ report: MeetingReportDraft, title: String, includeSources: Bool = true) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.nameFieldStringValue = title + " - compte rendu.docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MeetingWordDocument.data(
                document: report.content, transcript: records.first { $0.id == report.id },
                includeSources: includeSources
            ).write(to: url, options: .atomic)
        } catch { failure = error.localizedDescription }
    }

    func copyReport(_ report: MeetingReportDraft) {
        NSPasteboard.general.clearContents()
        let document = MeetingAttributedDocument.exportDocument(
            report.content,
            transcript: records.first { $0.id == report.id }, includeSources: false)
        let rich = MeetingAttributedDocument.render(document)
        NSPasteboard.general.setString(rich.string, forType: .string)
        if let rtf = try? rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        {
            NSPasteboard.general.setData(rtf, forType: .rtf)
        }
    }

    func export(_ document: SpeakerTranscript, format: String, french: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            format == "json"
                ? .json
                : format == "srt" ? UTType(filenameExtension: "srt") ?? .plainText : .plainText
        ]
        panel.nameFieldStringValue = document.title + "." + format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if format == "json" {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                var exported = document
                // Security-scoped bookmarks and personal workspace metadata never leave the archive.
                exported.audioReference = nil
                exported.calendarEvent = nil
                exported.personalNotes = nil
                exported.markers = nil
                exported.project = nil
                exported.favorite = nil
                data = try encoder.encode(exported)
            } else {
                data = Data(render(document, subtitles: format == "srt", french: french).utf8)
            }
            try data.write(to: url, options: .atomic)
        } catch { failure = error.localizedDescription }
    }

    func copy(_ document: SpeakerTranscript, french: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(render(document, french: french), forType: .string)
    }

    private func render(_ document: SpeakerTranscript, subtitles: Bool = false, french: Bool)
        -> String
    {
        let prefix = french ? "Intervenant" : "Speaker"
        let unknown = french ? "Intervenant incertain" : "Uncertain speaker"
        let overlap = french ? "Voix superposées" : "Overlapping voices"
        return subtitles
            ? document.subtitles(prefix: prefix, unknown: unknown, overlap: overlap)
            : document.plainText(prefix: prefix, unknown: unknown, overlap: overlap)
    }

    private func persist() async {
        do {
            try await archive.save(savedRecords)
            savedIDs = Set(savedRecords.map(\.id))
            recordSaveFailed = false
        } catch {
            recordSaveFailed = true
            saveState = .failed
            failure = String(
                localized:
                    "The transcript is available, but saving failed. Export it to keep a copy.")
        }
    }

    private func persistReports() async {
        guard maySave, reportArchiveWritable else { saveState = .session; return }
        let revision = saveRevision
        do {
            try await reportArchive.save(
                reports.values.filter { savedIDs.contains($0.transcriptID) }
                    .sorted { $0.createdAt < $1.createdAt })
            if revision == saveRevision { saveState = recordSaveFailed ? .failed : .saved }
        } catch {
            saveState = .failed
            failure = String(
                localized: "The report is available, but saving failed. Export it to keep a copy.")
        }
    }

    private func generateReportDraft(
        for document: SpeakerTranscript, french: Bool,
        prestartedRuntime: ReportRuntimePreparationHandle? = nil
    ) async throws {
        reportProgress = 0
        reportStage = french ? "Lecture des échanges" : "Reading the conversation"
        let fingerprint = try MeetingReportDraft.fingerprint(of: document)
        let style = reportStyle
        let cacheKey =
            document.id.uuidString + fingerprint + style.rawValue + (french ? "fr" : "en")
        // Keep retry checkpoints bounded to the current document/source/style.
        generationCache = generationCache.filter { $0.key.hasPrefix(cacheKey) }
        topicCache = topicCache.filter { $0.key == cacheKey }
        let chunks = reportChunks(for: document)
        guard !chunks.isEmpty else { throw MeetingReportGenerationError.invalidOutput }
        let plans = try chunks.map { chunk in
            guard
                let partition = MeetingReportExtraction.deterministicDAQPartition(
                    candidateIDs: chunk.candidateIDs, evidence: chunk.evidence)
            else { throw MeetingReportGenerationError.invalidOutput }
            return (chunk: chunk, partition: partition)
        }
        let unresolvedCount = plans.reduce(into: 0) { total, plan in
            total += plan.partition.unresolvedIDs.count
        }
        let usesLineClassifier = Self.reportUsesLineClassifier(unresolvedCount: unresolvedCount)
        let classifierInstruction =
            usesLineClassifier ? Self.reportLineInstruction() : Self.reportInstruction()
        let narrativeInstruction = Self.reportNarrativeInstruction(french: french)
        let runtime = try await Self.preparedReportRuntime(prestarted: prestartedRuntime)
        var remoteSelections = Array(
            repeating: ["d": [String](), "a": [String](), "q": [String]()],
            count: plans.count)
        var extractions = [MeetingReportExtraction]()
        do {
            if unresolvedCount > 0 {
                try await runtime.prepareStructuredPrefix(system: classifierInstruction)
                var unresolved = [(chunkIndex: Int, sourceID: Int, source: MeetingReportEvidence)]()
                for (chunkIndex, plan) in plans.enumerated() {
                    for sourceID in plan.partition.unresolvedIDs {
                        guard let source = plan.chunk.evidence[sourceID] else {
                            throw MeetingReportGenerationError.invalidOutput
                        }
                        unresolved.append((chunkIndex, sourceID, source))
                    }
                }

                if usesLineClassifier {
                    for item in unresolved {
                        try Task.checkCancellation()
                        let result = try await runtime.generateStructured(
                            system: classifierInstruction,
                            user: item.source.text,
                            maximumOutputTokens: 4,
                            timeout: .seconds(180)
                        )
                        let category = try Self.daqLineCategory(result.text)
                        if category != "x" {
                            remoteSelections[item.chunkIndex][category, default: []].append(
                                "E\(item.sourceID)")
                        }
                    }
                } else {
                    let batchSize = 12
                    for start in stride(from: 0, to: unresolved.count, by: batchSize) {
                        try Task.checkCancellation()
                        let end = min(start + batchSize, unresolved.count)
                        let batch = Array(unresolved[start..<end])
                        var batchEvidence = [Int: MeetingReportEvidence]()
                        let unresolvedText = batch.enumerated().map { temporaryID, item in
                            batchEvidence[temporaryID] = MeetingReportEvidence(
                                id: temporaryID, turnID: item.source.turnID, text: item.source.text)
                            return "[E\(temporaryID)] \(item.source.text)"
                        }.joined(separator: "\n")
                        let result = try await runtime.generateStructured(
                            system: classifierInstruction,
                            user: "<transcript>\n\(unresolvedText)\n</transcript>",
                            maximumOutputTokens: 64,
                            timeout: .seconds(180)
                        )
                        _ = try MeetingReportExtraction.parseDAQ(
                            result.text, evidence: batchEvidence)
                        let labels = try Self.daqLabels(result.text)
                        for category in ["d", "a", "q"] {
                            for label in labels[category, default: []] {
                                guard label.first == "E", let temporaryID = Int(label.dropFirst()),
                                    batch.indices.contains(temporaryID)
                                else { throw MeetingReportGenerationError.invalidOutput }
                                let item = batch[temporaryID]
                                remoteSelections[item.chunkIndex][category, default: []].append(
                                    "E\(item.sourceID)")
                            }
                        }
                    }
                }
            }

            for (index, plan) in plans.enumerated() {
                try Task.checkCancellation()
                let remoteOutput = try Self.daqOutput(from: remoteSelections[index])
                let mergedSelection = try Self.mergeDAQOutputs(
                    plan.partition.resolvedOutput, remoteOutput)
                extractions.append(
                    try MeetingReportExtraction.parseDAQ(
                        mergedSelection, evidence: plan.chunk.evidence))
                reportProgress = 0.35 * Double(index + 1) / Double(plans.count)
            }
            let index = MeetingDocumentEvidenceIndex(transcript: document)
            let overview = index.overview()
            let decisionQuotes = extractions.reduce(into: Set<String>()) {
                $0.formUnion($1.confirmedDecisionQuotes)
            }
            let actionQuotes = extractions.reduce(into: Set<String>()) {
                $0.formUnion($1.confirmedActionQuotes)
            }
            let decisions = Set(
                index.evidence.compactMap { decisionQuotes.contains($0.value.text) ? $0.key : nil })
            let actions = Set(
                index.evidence.compactMap { actionQuotes.contains($0.value.text) ? $0.key : nil })
            func sourceText(_ evidence: [Int: MeetingReportEvidence]) -> String {
                evidence.values.sorted { $0.id < $1.id }.map { source in
                    let label =
                        document.turns.first { $0.id == source.turnID }
                        .map {
                            document.label(
                                for: $0, prefix: french ? "Intervenant" : "Speaker",
                                unknown: french ? "Voix incertaine" : "Uncertain speaker")
                        } ?? ""
                    return "[E\(source.id)] \(label): \(source.text)"
                }.joined(separator: "\n")
            }
            var content = MeetingDocument(title: document.title)
            if index.characterCount <= 14_000 || style == .concise {
                reportStage = french ? "Rédaction du document" : "Writing the document"
                let prompt =
                    "<transcript>\n" + sourceText(overview) + "\n</transcript>\n"
                    + style.instruction
                    + " Begin with a contextual paragraph, then topic-specific sections if useful."
                try await runtime.prepareStructuredPrefix(system: narrativeInstruction)
                let output = try await runtime.generateStructured(
                    system: narrativeInstruction, user: prompt,
                    maximumOutputTokens: style == .concise ? 900 : 1_800, timeout: .seconds(240))
                content = try MeetingDocumentGeneration.parse(
                    output.text, title: document.title,
                    evidence: overview, transcript: document, decisionIDs: decisions,
                    actionIDs: actions)
                if overview.count < index.evidence.count {
                    content.coverageNotice =
                        french
                        ? "Synthèse courte fondée sur une sélection de passages."
                        : "Short summary based on selected passages."
                }
            } else {
                reportStage = french ? "Organisation des sujets" : "Organizing topics"
                let topics: [MeetingDocumentTopic]
                if let cached = topicCache[cacheKey] {
                    topics = cached
                } else {
                    let instruction = MeetingDocumentGeneration.outlineInstruction(french: french)
                    let output = try await runtime.generateStructured(
                        system: instruction,
                        user: "<transcript>\n" + sourceText(overview) + "\n</transcript>",
                        maximumOutputTokens: 900, timeout: .seconds(180))
                    topics = try MeetingDocumentGeneration.parseTopics(
                        output.text, evidence: overview)
                    topicCache[cacheKey] = topics
                }
                try await runtime.prepareStructuredPrefix(system: narrativeInstruction)
                for (position, topic) in topics.enumerated() {
                    try Task.checkCancellation()
                    reportStage = topic.title
                    let key = cacheKey + String(position)
                    let section: MeetingDocument
                    if let cached = generationCache[key] {
                        section = cached
                    } else {
                        let passages = index.passages(for: topic)
                        let prompt =
                            "Write only the section about: \(topic.title). "
                            + "Use one specific heading and 1-3 substantive paragraphs. "
                            + (position == 0
                                ? "Include the meeting context only if these sources explain it. "
                                : "")
                            + style.instruction + "\n<transcript>\n" + sourceText(passages)
                            + "\n</transcript>"
                        let output = try await runtime.generateStructured(
                            system: narrativeInstruction,
                            user: prompt, maximumOutputTokens: 750, timeout: .seconds(180))
                        section = try MeetingDocumentGeneration.parse(
                            output.text, title: document.title,
                            evidence: passages, transcript: document, decisionIDs: decisions,
                            actionIDs: actions)
                        generationCache[key] = section
                    }
                    content.blocks.append(contentsOf: section.blocks)
                    reportProgress = 0.35 + 0.65 * Double(position + 1) / Double(topics.count)
                }
                content.coverageNotice =
                    french
                    ? "Document organisé par sujets à partir des passages sélectionnés dans la transcription complète. À relire."
                    : "Topic-based document using passages selected across the full transcript. Review before sharing."
            }
            reportProgress = 1
            await runtime.unload()
            try Task.checkCancellation()
            guard let current = records.first(where: { $0.id == document.id }),
                try MeetingReportDraft.fingerprint(of: current) == fingerprint
            else {
                throw MeetingReportGenerationError.invalidSource
            }
            content.title = current.title
            var report =
                try reports[document.id]
                ?? MeetingReportDraft.template(for: current, french: french)
            let generator = "Qwen local · document v4 · " + style.rawValue
            if report.content.blocks.contains(where: {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                report.proposal = MeetingReportVersion(
                    document: content, sourceFingerprint: fingerprint, generator: generator)
            } else {
                report.replaceContent(content)
                report.sourceFingerprint = fingerprint
                report.generator = generator
            }
            reports[document.id] = report
            checkpointedIDs.remove(document.id)
            await persistReports()
        } catch {
            await runtime.unload()
            throw error
        }
    }

    private struct ReportChunk: Sendable {
        let text: String
        let start: Double
        let evidence: [Int: MeetingReportEvidence]
        let candidateIDs: [Int]
    }

    private func reportChunks(for document: SpeakerTranscript) -> [ReportChunk] {
        let maximumCharacters = 6_000
        var chunks = [ReportChunk]()
        var lines = [String]()
        var candidateIDs = [Int]()
        var length = 0
        var evidence = [Int: MeetingReportEvidence]()
        var start = 0.0
        func flush() {
            guard !evidence.isEmpty else { return }
            chunks.append(
                ReportChunk(
                    text: lines.joined(separator: "\n"), start: start, evidence: evidence,
                    candidateIDs: candidateIDs))
            lines.removeAll()
            candidateIDs.removeAll()
            evidence.removeAll()
            length = 0
        }
        for turn in document.turns {
            let label = document.label(
                for: turn, prefix: "Intervenant", unknown: "Intervenant incertain")
            for fragment in MeetingReportEvidenceBuilder.fragments(in: turn.text) {
                var evidenceID = evidence.count
                var sourceLine =
                    "E\(evidenceID)|T\(turn.id)|\(SpeakerTranscript.timestamp(turn.start))|\(label)|\(fragment)"
                if !evidence.isEmpty && length + sourceLine.count + 1 > maximumCharacters {
                    flush()
                    evidenceID = evidence.count
                    sourceLine =
                        "E\(evidenceID)|T\(turn.id)|\(SpeakerTranscript.timestamp(turn.start))|\(label)|\(fragment)"
                }
                if evidence.isEmpty { start = turn.start }
                if MeetingReportExtraction.isLikelyDAQCandidate(fragment) {
                    lines.append("E\(evidenceID)|\(fragment)")
                    candidateIDs.append(evidenceID)
                }
                length += sourceLine.count + 1
                evidence[evidenceID] = MeetingReportEvidence(
                    id: evidenceID, turnID: turn.id, text: fragment)
            }
        }
        flush()
        return chunks
    }

    nonisolated private static func reportModelDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(
            "VoxoL/Models/polisher/851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a",
            isDirectory: true)
    }

    private static func reportModelVerificationHandle() async throws
        -> ReportModelVerificationHandle
    {
        let stamp = try await Task.detached(priority: .utility) { try reportModelStamp() }.value
        return await ReportModelVerificationCache.shared.handle(stamp: stamp) {
            try verifiedReportModelDirectory(expectedStamp: stamp)
        }
    }

    private static func reportRuntimePreparationHandle(system: String) async throws
        -> ReportRuntimePreparationHandle
    {
        let verification = try await reportModelVerificationHandle()
        let task = Task(priority: .utility) {
            let modelRoot = try await verification.task.value
            try Task.checkCancellation()
            let runtime = QwenPolisherRuntime(
                modelRoot: modelRoot,
                useInstalledAdapter: false,
                generationConfiguration: .meetingReport
            )
            do {
                try await runtime.prepare()
                try await runtime.prepareStructuredPrefix(system: system)
                try Task.checkCancellation()
                return runtime
            } catch {
                await runtime.unload()
                throw error
            }
        }
        return ReportRuntimePreparationHandle(stamp: verification.stamp, task: task)
    }

    private static func preparedReportRuntime(
        prestarted: ReportRuntimePreparationHandle?
    ) async throws -> QwenPolisherRuntime {
        let stamp = try await Task.detached(priority: .utility) { try reportModelStamp() }.value
        if let prestarted, prestarted.stamp == stamp {
            return try await prestarted.task.value
        }
        if let prestarted {
            cancelPreparedReportRuntime(prestarted)
        }
        let modelRoot = try await verifiedReportModelDirectory(prestarted: nil)
        let runtime = QwenPolisherRuntime(
            modelRoot: modelRoot,
            useInstalledAdapter: false,
            generationConfiguration: .meetingReport
        )
        do {
            try await runtime.prepare()
            return runtime
        } catch {
            await runtime.unload()
            throw error
        }
    }

    nonisolated private static func cancelPreparedReportRuntime(
        _ handle: ReportRuntimePreparationHandle
    ) {
        handle.task.cancel()
        Task.detached(priority: .utility) {
            if let runtime = try? await handle.task.value {
                await runtime.unload()
            }
        }
    }

    private static func verifiedReportModelDirectory(
        prestarted: ReportModelVerificationHandle?
    ) async throws -> URL {
        let stamp = try await Task.detached(priority: .utility) { try reportModelStamp() }.value
        let handle: ReportModelVerificationHandle
        if let prestarted, prestarted.stamp == stamp {
            handle = prestarted
        } else {
            handle = await ReportModelVerificationCache.shared.handle(stamp: stamp) {
                try verifiedReportModelDirectory(expectedStamp: stamp)
            }
        }
        return try await handle.task.value
    }

    nonisolated private static func reportModelExpectedDigests() -> [(String, String)] {
        [
            (
                "chat_template.jinja",
                "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"
            ),
            (
                "config.json",
                "8591d683d8d132234766399897415b9427967c05e77c1c169a40de3e81177e62"
            ),
            (
                "model.safetensors",
                "6626ef65bc697df9217e91372430cef39772ffda804f37f9825e453b15c2414a"
            ),
            (
                "model.safetensors.index.json",
                "bedb8a543e5b510447d4e91d268eeac6a154cc1d2dd0c7542593419e59ec8310"
            ),
            (
                "tokenizer.json",
                "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"
            ),
            (
                "tokenizer_config.json",
                "b2bed5e033438f09f22b0ce9522115b4807d9bbcc3b82bf23372cb74d93ed081"
            ),
        ]
    }

    nonisolated private static func reportModelStamp() throws -> [ReportModelFileStamp] {
        let directory = reportModelDirectory()
        return try reportModelExpectedDigests().map { filename, _ in
            let url = directory.appendingPathComponent(filename)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                let modificationDate = attributes[.modificationDate] as? Date,
                let fileNumber = attributes[.systemFileNumber] as? NSNumber
            else { throw SpeakerError.modelIntegrity }
            return ReportModelFileStamp(
                filename: filename,
                size: size.uint64Value,
                modificationDateBits: modificationDate.timeIntervalSinceReferenceDate.bitPattern,
                fileNumber: fileNumber.uint64Value)
        }
    }

    nonisolated private static func verifiedReportModelDirectory(
        expectedStamp: [ReportModelFileStamp]
    ) throws -> URL {
        let directory = reportModelDirectory()
        guard try reportModelStamp() == expectedStamp else { throw SpeakerError.modelIntegrity }
        for (filename, digest) in reportModelExpectedDigests() {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(filename)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == digest else { throw SpeakerError.modelIntegrity }
        }
        guard try reportModelStamp() == expectedStamp else { throw SpeakerError.modelIntegrity }
        return directory
    }

    nonisolated private static func mergeDAQOutputs(
        _ first: String, _ second: String
    ) throws -> String {
        var merged = ["d": [String](), "a": [String](), "q": [String]()]
        for output in [first, second] {
            let labels = try daqLabels(output)
            for category in ["d", "a", "q"] {
                merged[category, default: []].append(contentsOf: labels[category, default: []])
            }
        }
        return try daqOutput(from: merged)
    }

    nonisolated private static func daqLabels(_ output: String) throws -> [String: [String]] {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)),
            let dictionary = object as? [String: Any],
            Set(dictionary.keys) == Set(["d", "a", "q"]),
            let decisions = dictionary["d"] as? [String],
            let actions = dictionary["a"] as? [String],
            let questions = dictionary["q"] as? [String]
        else { throw MeetingReportGenerationError.invalidOutput }
        return ["d": decisions, "a": actions, "q": questions]
    }

    nonisolated private static func daqOutput(from labels: [String: [String]]) throws -> String {
        guard Set(labels.keys) == Set(["d", "a", "q"]),
            let data = try? JSONSerialization.data(withJSONObject: labels, options: [.sortedKeys]),
            let output = String(data: data, encoding: .utf8)
        else { throw MeetingReportGenerationError.invalidOutput }
        return output
    }

    nonisolated private static func reportInstruction() -> String {
        """
        Classify every supplied evidence line. Return ONLY one JSON object exactly shaped {"d":["E..."],"a":["E..."],"q":["E..."]} and stop after it.
        Use only supplied E labels. Include every qualifying line once; omit nonmatches.
        d = the line explicitly says a decision was made, decided, confirmed, approved, accepted, rejected, validated, or settled.
        a = the speaker explicitly commits themself to a concrete future task, including a conditional commitment.
        q = the line explicitly says a decision is not made yet, approval is pending/not given, a choice still must be decided, or a direct question remains unanswered.
        Do not explain or reason.
        """
    }

    nonisolated private static func reportNarrativeInstruction(french: Bool) -> String {
        MeetingDocumentGeneration.instruction(french: french)
    }

    nonisolated private static func reportLineInstruction() -> String {
        """
        Classify one meeting evidence line. Return exactly one lowercase letter and nothing else.
        d = explicit made/confirmed/approved/accepted/rejected/validated/settled decision.
        a = speaker explicitly commits themself to a concrete future task, including conditional commitment.
        q = explicitly unresolved/pending/not-given/still-to-decide/unanswered direct question.
        x = none.
        A plan to decide/review/consider/discuss/choose later is x unless also a separate concrete task.
        Return only d, a, q, or x.
        """
    }

    nonisolated private static func daqLineCategory(_ output: String) throws -> String {
        let category = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard category == "d" || category == "a" || category == "q" || category == "x"
        else { throw MeetingReportGenerationError.invalidOutput }
        return category
    }

    nonisolated private static func reportUsesLineClassifier(unresolvedCount: Int) -> Bool {
        unresolvedCount > 0 && unresolvedCount <= 4
    }

    nonisolated private static func reportLikelyClassifierInstruction(_ text: String) -> String? {
        let fragments = MeetingReportEvidenceBuilder.fragments(in: text)
        var evidence = [Int: MeetingReportEvidence]()
        var candidateIDs = [Int]()
        for (id, fragment) in fragments.enumerated() {
            evidence[id] = MeetingReportEvidence(id: id, turnID: 0, text: fragment)
            if MeetingReportExtraction.isLikelyDAQCandidate(fragment) { candidateIDs.append(id) }
        }
        guard !candidateIDs.isEmpty else { return nil }
        guard
            let partition = MeetingReportExtraction.deterministicDAQPartition(
                candidateIDs: candidateIDs, evidence: evidence)
        else { return reportInstruction() }
        let unresolvedCount = partition.unresolvedIDs.count
        guard unresolvedCount > 0 else { return nil }
        return reportUsesLineClassifier(unresolvedCount: unresolvedCount)
            ? reportLineInstruction() : reportInstruction()
    }
}
