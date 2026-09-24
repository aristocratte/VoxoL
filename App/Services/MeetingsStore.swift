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
                    result[report.transcriptID] = report
                }
            }
        } catch {
            reportArchiveWritable = false
            failure = String(
                localized:
                    "Meeting reports could not be opened. New drafts will stay in this session.")
        }
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

    func transcribe(url: URL, asrDirectory: URL, french: Bool, title: String? = nil) {
        guard !busy, modelReady else { return }
        phase = .reading
        processingStartedAt = Date()
        processingTitle = title ?? url.deletingPathExtension().lastPathComponent
        failure = nil
        speakerProgress = 0
        reportProgress = 0
        let saveAllowedAtStart = maySave
        job = Task {
            let securityScope = url.startAccessingSecurityScopedResource()
            defer {
                if securityScope { url.stopAccessingSecurityScopedResource() }
                phase = .idle
                job = nil
            }
            do {
                let read = Task.detached { try await MeetingMedia.load(url) }
                let samples = try await withTaskCancellationHandler {
                    try await read.value
                } onCancel: {
                    read.cancel()
                }
                try Task.checkCancellation()
                phase = .transcribing
                let runtime = ParakeetRuntime(modelRoot: asrDirectory, computeUnits: .gpu)
                let transcript = try await runtime.transcribe(samples: samples)
                let words = await runtime.wordEvidence(for: transcript).map { word in
                    SpeakerWord(
                        range: word.sourceRange,
                        start: word.frameRange.map { Double($0.lowerBound) * 0.08 },
                        end: word.frameRange.map { Double($0.upperBound) * 0.08 })
                }
                try Task.checkCancellation()
                guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    failure = String(localized: "No speech was transcribed in this recording.")
                    return
                }
                let prestartedReportRuntime: ReportRuntimePreparationHandle?
                if reportModelAvailable,
                    let system = Self.reportLikelyClassifierInstruction(transcript.text)
                {
                    prestartedReportRuntime = try? await Self.reportRuntimePreparationHandle(
                        system: system)
                } else {
                    prestartedReportRuntime = nil
                }
                phase = .speakers
                let activity = try await NativeSpeakerDiarizer().analyze(
                    samples: samples, directory: modelDirectory
                ) { [weak self] value in
                    Task { @MainActor in
                        if self?.phase == .speakers { self?.speakerProgress = value }
                    }
                }
                try Task.checkCancellation()
                let duration = Double(samples.count) / 16000
                let turns = try SpeakerAttribution.turns(
                    text: transcript.text, words: words,
                    probabilities: activity.probabilities, frameCount: activity.frameCount,
                    duration: duration)
                let result = SpeakerTranscript(
                    title: title ?? url.deletingPathExtension().lastPathComponent,
                    duration: duration, rawText: transcript.text, turns: turns,
                    diarizationRevision: SpeakerModelAssets.revision)
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

    func generateReport(for id: UUID, french: Bool) {
        guard !busy, let document = records.first(where: { $0.id == id }) else { return }
        phase = .reporting
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
        guard var report = reports[id] else { return }
        report.markdown = markdown
        report.updatedAt = Date()
        reports[id] = report
        reportSaveJob?.cancel()
        guard maySave, reportArchiveWritable, savedIDs.contains(id) else { return }
        reportSaveJob = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.persistReports()
        }
    }

    func exportReport(_ report: MeetingReportDraft, title: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = title + " - compte rendu.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(report.markdown.utf8).write(to: url, options: .atomic) } catch {
            failure = error.localizedDescription
        }
    }

    func exportWord(_ report: MeetingReportDraft, title: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.nameFieldStringValue = title + " - compte rendu.docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MeetingWordDocument.data(markdown: report.markdown).write(to: url, options: .atomic)
        } catch { failure = error.localizedDescription }
    }

    func copyReport(_ report: MeetingReportDraft) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.markdown, forType: .string)
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
                data = try encoder.encode(document)
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
        } catch {
            failure = String(
                localized:
                    "The transcript is available, but saving failed. Export it to keep a copy.")
        }
    }

    private func persistReports() async {
        guard maySave, reportArchiveWritable else { return }
        do {
            try await reportArchive.save(
                reports.values.filter { savedIDs.contains($0.transcriptID) }
                    .sorted { $0.createdAt < $1.createdAt })
        } catch {
            failure = String(
                localized: "The report is available, but saving failed. Export it to keep a copy.")
        }
    }

    private func generateReportDraft(
        for document: SpeakerTranscript, french: Bool,
        prestartedRuntime: ReportRuntimePreparationHandle? = nil
    ) async throws {
        reportProgress = 0
        let initialMarkdown = reports[document.id]?.markdown
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
        let needsRuntime = unresolvedCount > 0
        let usesLineClassifier = Self.reportUsesLineClassifier(unresolvedCount: unresolvedCount)
        let classifierInstruction =
            usesLineClassifier ? Self.reportLineInstruction() : Self.reportInstruction()
        let runtime: QwenPolisherRuntime?
        if needsRuntime {
            runtime = try await Self.preparedReportRuntime(prestarted: prestartedRuntime)
            try await runtime?.prepareStructuredPrefix(system: classifierInstruction)
        } else {
            if let prestartedRuntime {
                Self.cancelPreparedReportRuntime(prestartedRuntime)
            }
            runtime = nil
        }
        var remoteSelections = Array(
            repeating: ["d": [String](), "a": [String](), "q": [String]()],
            count: plans.count)
        var extractions = [MeetingReportExtraction]()
        do {
            if let runtime {
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
                reportProgress = Double(index + 1) / Double(plans.count)
            }
            if let runtime { await runtime.unload() }
        } catch {
            if let runtime { await runtime.unload() }
            throw error
        }
        try Task.checkCancellation()
        guard let current = records.first(where: { $0.id == document.id }),
            current == document, reports[document.id]?.markdown == initialMarkdown
        else { throw MeetingReportGenerationError.invalidSource }
        let markdown = MeetingReportMarkdown.render(
            transcript: document, extractions: extractions, french: french)
        reports[document.id] = try MeetingReportDraft(
            transcriptID: document.id,
            createdAt: reports[document.id]?.createdAt ?? Date(),
            sourceFingerprint: MeetingReportDraft.fingerprint(of: document),
            generator: "Qwen3.5-4B local",
            markdown: markdown
        )
        await persistReports()
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
                if Self.isReportClassifierCandidate(fragment) {
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
            let runtime = QwenPolisherRuntime(modelRoot: modelRoot, useInstalledAdapter: false)
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
        let runtime = QwenPolisherRuntime(modelRoot: modelRoot, useInstalledAdapter: false)
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

    nonisolated private static func isReportClassifierCandidate(_ text: String) -> Bool {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        let signals = [
            "decid", "decision", "valide", "validated", "confirm", "approv", "accept", "reject",
            "rejet", "commit", "engage", "prends en charge", "je vais", "je ferai",
            "je preparerai", "je terminerai", "je verifierai", "je publierai", "i will",
            "i'll", "i, ", "pending", "en attente", "pas encore", "not decided", "not yet",
            "still have not", "undecid", "question", "?",
        ]
        return signals.contains { folded.contains($0) }
    }

    nonisolated private static func reportLikelyClassifierInstruction(_ text: String) -> String? {
        let fragments = MeetingReportEvidenceBuilder.fragments(in: text)
        var evidence = [Int: MeetingReportEvidence]()
        var candidateIDs = [Int]()
        for (id, fragment) in fragments.enumerated() {
            evidence[id] = MeetingReportEvidence(id: id, turnID: 0, text: fragment)
            if isReportClassifierCandidate(fragment) { candidateIDs.append(id) }
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
