import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class TranscriptStore {
    static weak var activeStore: TranscriptStore?

    var records: [TranscriptRecord] = []
    var isLoading = false
    var usesExampleData = false
    var toast: TranscriptToast? {
        didSet {
            if toast != nil { toastID = UUID() }
        }
    }
    private(set) var toastID = UUID()
    private(set) var historyIssue: TranscriptHistoryIssue?

    @ObservationIgnored private let fileStore: TranscriptFileStore
    @ObservationIgnored private var pendingChanges: [UUID: UUID] = [:]
    @ObservationIgnored private var exportedChanges: [UUID: UUID] = [:]

    init(directoryURL: URL? = nil) {
        fileStore = TranscriptFileStore(directoryURL: directoryURL)
        if directoryURL == nil { Self.activeStore = self }
    }

    var hasUnsavedChanges: Bool { !pendingChanges.isEmpty }
    var hasUnprotectedChanges: Bool {
        pendingChanges.contains { exportedChanges[$0.key] != $0.value }
    }

    func chooseRecoveryDestination() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "VoxoL-Recovery.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        _ = await exportRecoveryCopy(to: destination)
    }

    @discardableResult
    func exportRecoveryCopy(to destination: URL) async -> Bool {
        let changes = pendingChanges
        do {
            try await fileStore.exportRecoveryCopy(
                TranscriptArchive(records: records), to: destination)
            for (id, revision) in changes { exportedChanges[id] = revision }
            toast = .recoveryExported
            return true
        } catch {
            toast = .recoveryExportFailed
            return false
        }
    }

    func flushPendingSaves() async {
        if hasUnsavedChanges { await retryHistory() }
    }

    var metrics: TranscriptHistoryMetrics {
        TranscriptHistoryMetrics(records: records)
    }

    func load() async {
        guard !isLoading else {
            return
        }
        isLoading = true

        do {
            let archive = try await fileStore.load()
            let pending = records.filter { pendingChanges[$0.id] != nil }
            records = (archive.records.filter { pendingChanges[$0.id] == nil } + pending)
                .sorted { $0.createdAt > $1.createdAt }
            usesExampleData = false
            historyIssue = pendingChanges.isEmpty ? nil : .saveFailed
        } catch TranscriptFileStoreError.fileMissing {
            records = records.filter { pendingChanges[$0.id] != nil }
            usesExampleData = false
            historyIssue = pendingChanges.isEmpty ? nil : .saveFailed
        } catch {
            // Keep in-memory results and leave the unreadable file untouched.
            historyIssue = .loadFailed
            toast = .historyLoadFailed
        }
        isLoading = false
        if historyIssue != .loadFailed, !pendingChanges.isEmpty {
            await persist()
        }
    }

    func retryHistory() async {
        guard !isLoading else { return }
        await load()
    }

    func add(_ record: TranscriptRecord) async {
        guard UserDefaults.standard.bool(forKey: "voxol.historyEnabled"),
            !UserDefaults.standard.bool(forKey: "voxol.privateMode")
        else {
            return
        }
        if usesExampleData {
            records = []
        }
        records.insert(record, at: 0)
        pendingChanges[record.id] = UUID()
        usesExampleData = false
        await persist()
    }

    func copy(_ record: TranscriptRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.text, forType: .string)
        toast = .copied
    }

    func undoLastEdit(for id: UUID) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard records[index].undoLastEdit() else {
            return
        }
        toast = .previousVersionRestored
        if !usesExampleData {
            pendingChanges[id] = UUID()
            await persist()
        }
    }

    func redoLastEdit(for id: UUID) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard records[index].redoLastEdit() else {
            return
        }
        toast = .laterVersionRestored
        if !usesExampleData {
            pendingChanges[id] = UUID()
            await persist()
        }
    }

    func replaceText(for id: UUID, with newText: String) async -> TranscriptEdit? {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let index = records.firstIndex(where: { $0.id == id }),
            !records[index].isExample,
            records[index].text != trimmed
        else {
            return nil
        }
        let rawTranscript = records[index].revisions.first?.text ?? records[index].text
        records[index].replaceText(with: trimmed)
        pendingChanges[id] = UUID()
        let edit = TranscriptEdit(
            rawTranscript: rawTranscript,
            correctedText: trimmed,
            applicationBundleIdentifier: records[index].applicationBundleIdentifier
        )
        toast = .editSaved
        await persist()
        return edit
    }

    func dismissToast() {
        toast = nil
    }

    func audioURL(for record: TranscriptRecord) async -> URL? {
        guard let path = record.audioRelativePath else {
            return nil
        }
        return await fileStore.audioURL(relativePath: path)
    }

    func exportAudio(for record: TranscriptRecord) async {
        guard let sourceURL = await audioURL(for: record) else {
            toast = .noAudioRetained
            return
        }

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        let fileExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        savePanel.nameFieldStringValue =
            "VoxoL-\(record.id.uuidString.prefix(8)).\(fileExtension)"
        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            toast = .audioExported
        } catch {
            toast = .audioExportFailed
        }
    }

    private func persist() async {
        // Loading yields to other main-actor work. Wait until its records are merged
        // before allowing a dictation that arrived during launch to write the archive.
        guard !isLoading else { return }
        let changesBeingSaved = pendingChanges
        do {
            try await fileStore.save(TranscriptArchive(records: records))
            for (id, revision) in changesBeingSaved where pendingChanges[id] == revision {
                pendingChanges.removeValue(forKey: id)
                exportedChanges.removeValue(forKey: id)
            }
            if pendingChanges.isEmpty { historyIssue = nil }
        } catch {
            if historyIssue != .loadFailed { historyIssue = .saveFailed }
            toast = .historySaveFailed
        }
    }

    #if DEBUG
        /// An explicit in-memory state for native UI review; never reads an archive.
        func configureAuditPreview(_ state: String) {
            if state == "history-error" || state == "history-error-populated" {
                historyIssue = .loadFailed
            }
            if state == "loading" { isLoading = true }
            if state == "populated" || state == "history-error-populated" {
                records = [
                    TranscriptRecord(
                        createdAt: .now, applicationName: "Notes",
                        text:
                            "Exemple fictif : préparer la réunion de mercredi et vérifier le budget.",
                        durationSeconds: 8),
                    TranscriptRecord(
                        createdAt: .now.addingTimeInterval(-120), applicationName: "Mail",
                        text: "Exemple fictif : le café est prêt, rendez-vous à dix heures.",
                        durationSeconds: 6),
                    TranscriptRecord(
                        createdAt: .now.addingTimeInterval(-90_000), applicationName: "Notes",
                        text:
                            "Synthetic example: review the application before publishing the release.",
                        durationSeconds: 7),
                ]
            }
        }
    #endif
}

enum TranscriptHistoryIssue: Equatable {
    case loadFailed
    case saveFailed
}

enum TranscriptToast: Equatable {
    case recoveryExported
    case recoveryExportFailed
    case copied
    case previousVersionRestored
    case laterVersionRestored
    case audioExported
    case noAudioRetained
    case audioExportFailed
    case historyLoadFailed
    case historySaveFailed
    case editSaved
}

struct TranscriptEdit: Equatable, Sendable {
    let rawTranscript: String
    let correctedText: String
    let applicationBundleIdentifier: String?
}

private extension TranscriptStore {
    @MainActor
    static let exampleRecords: [TranscriptRecord] = {
        let now = Date()
        return [
            TranscriptRecord(
                createdAt: now.addingTimeInterval(-8 * 60),
                applicationName: "Mail",
                applicationBundleIdentifier: "com.apple.mail",
                text:
                    "Let’s move the product review to Wednesday morning and keep the agenda focused on launch readiness.",
                durationSeconds: 9.8,
                revisions: [
                    TranscriptRevision(
                        text: "Let’s move the review to Wednesday morning.",
                        createdAt: now.addingTimeInterval(-9 * 60)
                    )
                ],
                isExample: true
            ),
            TranscriptRecord(
                createdAt: now.addingTimeInterval(-52 * 60),
                applicationName: "Notes",
                applicationBundleIdentifier: "com.apple.Notes",
                text:
                    "Valider les permissions au moment précis où la fonctionnalité en a besoin, avec une explication claire.",
                durationSeconds: 7.4,
                isExample: true
            ),
            TranscriptRecord(
                createdAt: now.addingTimeInterval(-26 * 60 * 60),
                applicationName: "VS Code",
                applicationBundleIdentifier: "com.microsoft.VSCode",
                text:
                    "The model installer verifies the checksum before moving any artifact into the active runtime directory.",
                durationSeconds: 8.2,
                isExample: true
            ),
        ]
    }()
}
