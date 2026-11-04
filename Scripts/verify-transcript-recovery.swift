import Foundation

/// Run against the actual app store, without loading models or personal data:
/// xcrun swiftc -parse-as-library -swift-version 6 \
///   Packages/AppCoreKit/Sources/TranscriptHistory.swift \
///   App/Services/TranscriptStore.swift Scripts/verify-transcript-recovery.swift \
///   -o /tmp/voxol-transcript-recovery && /tmp/voxol-transcript-recovery
@main
struct TranscriptRecoveryVerification {
    @MainActor
    static func main() async throws {
        UserDefaults.standard.setVolatileDomain(
            ["voxol.historyEnabled": true, "voxol.privateMode": false],
            forName: UserDefaults.argumentDomain)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxol-recovery-verification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("transcripts.json")
        let damaged = Data("interrupted archive".utf8)
        try damaged.write(to: url)

        let store = TranscriptStore(directoryURL: directory)
        await store.load()
        try require(store.historyIssue == .loadFailed, "Load failure remains visible")
        let newRecord = record("Unsaved dictation", at: 100)
        await store.add(newRecord)
        try require(store.records == [newRecord], "New text remains available in memory")
        try require(store.hasUnprotectedChanges, "Unsaved results prevent a silent normal exit")
        try require(try Data(contentsOf: url) == damaged, "Broken archive remains byte-identical")
        let exported = await store.exportRecoveryCopy(
            to: directory.appendingPathComponent("recovery.json"))
        try require(exported, "The application can export a recovery copy")
        try require(
            store.hasUnsavedChanges && !store.hasUnprotectedChanges,
            "An exported copy permits exit without discarding pending history changes")

        let oldRecord = record("Previously retained dictation", at: 10)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TranscriptArchive(records: [oldRecord])).write(to: url)
        await store.retryHistory()
        try require(
            store.records == [newRecord, oldRecord], "Retry merges old and pending records")
        try require(store.historyIssue == nil, "Successful recovery clears the persistent warning")
        try require(!store.hasUnsavedChanges, "A recovered archive allows normal termination")
        let disk = TranscriptFileStore(directoryURL: directory)
        let recovered = try await disk.load()
        try require(recovered.records == store.records, "Recovered results are persisted")

        _ = await store.replaceText(for: newRecord.id, with: "Corrected dictation")
        let edited = try await disk.load()
        try require(
            edited.records.first?.text == "Corrected dictation", "Edits persist after recovery")
        try damaged.write(to: url)
        await store.load()
        try require(store.records.count == 2, "A later read failure preserves visible results")
        _ = await store.replaceText(for: newRecord.id, with: "A further unsaved edit")
        try require(store.hasUnprotectedChanges, "An older recovery copy cannot cover a new edit")

        store.toast = .copied
        let firstNotification = store.toastID
        store.toast = .copied
        try require(
            store.toastID != firstNotification, "Repeated actions have distinct notifications")
        store.dismissToast()
        try require(store.toast == nil, "Notifications can be dismissed")

        let launchDirectory = directory.appendingPathComponent("launch")
        try FileManager.default.createDirectory(
            at: launchDirectory, withIntermediateDirectories: true)
        let launchURL = launchDirectory.appendingPathComponent("transcripts.json")
        let previous = TranscriptArchive(records: [oldRecord])
        let previousBytes = try encoder.encode(previous)
        try previousBytes.write(to: launchURL)
        let launchingStore = TranscriptStore(directoryURL: launchDirectory)
        await launchingStore.add(newRecord)
        try require(
            try Data(contentsOf: launchURL) == previousBytes,
            "Early capture cannot replace unread history")
        await launchingStore.load()
        let launchDisk = TranscriptFileStore(directoryURL: launchDirectory)
        let merged = try await launchDisk.load()
        try require(
            merged.records == [newRecord, oldRecord], "Loading merges and saves an early capture")
        try require(
            !launchingStore.hasUnsavedChanges, "Early capture no longer needs manual recovery")
        print("PASS: 18 app-store recovery and notification checks; temporary fixtures only")
    }

    private static func record(_ text: String, at seconds: TimeInterval) -> TranscriptRecord {
        TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: seconds), applicationName: "Test",
            text: text, durationSeconds: 2)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String)
        throws
    {
        guard try condition() else {
            throw NSError(
                domain: "VoxoLTranscriptRecovery", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
