import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class TranscriptStore {
    var records: [TranscriptRecord] = []
    var isLoading = false
    var usesExampleData = false
    var toast: TranscriptToast?

    private let fileStore = TranscriptFileStore()

    var metrics: TranscriptHistoryMetrics {
        TranscriptHistoryMetrics(records: records)
    }

    func load() async {
        guard !isLoading else {
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let archive = try await fileStore.load()
            records = archive.records.sorted { $0.createdAt > $1.createdAt }
            usesExampleData = false
        } catch TranscriptFileStoreError.fileMissing {
            #if DEBUG
                records = Self.exampleRecords
                usesExampleData = true
            #else
                records = []
                usesExampleData = false
            #endif
        } catch {
            records = []
            usesExampleData = false
            toast = .historyLoadFailed
        }
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
        do {
            try await fileStore.save(TranscriptArchive(records: records))
        } catch {
            toast = .historySaveFailed
        }
    }
}

enum TranscriptToast: Equatable {
    case copied
    case previousVersionRestored
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

private enum TranscriptFileStoreError: Error {
    case fileMissing
    case unsupportedSchema(Int)
}

private actor TranscriptFileStore {
    private let directoryURL: URL
    private let archiveURL: URL

    init() {
        let applicationSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        directoryURL = applicationSupport.appendingPathComponent("VoxoL", isDirectory: true)
        archiveURL = directoryURL.appendingPathComponent("transcripts.json")
    }

    func load() throws -> TranscriptArchive {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw TranscriptFileStoreError.fileMissing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(
            TranscriptArchive.self,
            from: Data(contentsOf: archiveURL)
        )
        guard archive.schemaVersion == TranscriptArchive.currentSchemaVersion else {
            throw TranscriptFileStoreError.unsupportedSchema(archive.schemaVersion)
        }
        return archive
    }

    func save(_ archive: TranscriptArchive) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(
            to: archiveURL, options: [.atomic, .completeFileProtection])
    }

    func audioURL(relativePath: String) -> URL? {
        let root = directoryURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate =
            directoryURL
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            return nil
        }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
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
