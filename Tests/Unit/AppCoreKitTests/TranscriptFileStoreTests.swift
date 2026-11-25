import AppCoreKit
import Foundation
import XCTest

@MainActor
final class TranscriptFileStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxol-history-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private var record: TranscriptRecord {
        TranscriptRecord(
            createdAt: Date(timeIntervalSince1970: 42), applicationName: "Test",
            text: "A retained result", durationSeconds: 2)
    }

    func testMissingHistoryCanBeCreatedAfterCheckingForAnArchive() async throws {
        let store = TranscriptFileStore(directoryURL: try directory())
        do {
            _ = try await store.load()
            XCTFail("A new directory has no archive")
        } catch {
            XCTAssertEqual(error as? TranscriptFileStoreError, .fileMissing)
        }
        let archive = TranscriptArchive(records: [record])
        try await store.save(archive)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, archive)
    }

    func testUnreadableHistoryCannotBeOverwrittenByTheNextDictation() async throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("transcripts.json")
        let damaged = Data("{\"records\": [interrupted write".utf8)
        try damaged.write(to: url)
        let store = TranscriptFileStore(directoryURL: directory)
        do {
            _ = try await store.load()
            XCTFail("The damaged archive must fail to decode")
        } catch {}
        do {
            try await store.save(TranscriptArchive(records: [record]))
            XCTFail("A failed load must block overwriting the archive")
        } catch {
            XCTAssertEqual(error as? TranscriptFileStoreError, .recoveryRequired)
        }
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testFutureSchemaIsPreservedByteForByte() async throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("transcripts.json")
        let future = Data(#"{"schemaVersion":99,"records":[],"futureField":"keep"}"#.utf8)
        try future.write(to: url)
        let store = TranscriptFileStore(directoryURL: directory)
        do {
            _ = try await store.load()
            XCTFail("A future schema must not be interpreted as an empty archive")
        } catch {
            XCTAssertEqual(error as? TranscriptFileStoreError, .unsupportedSchema(99))
        }
        do {
            try await store.save(TranscriptArchive(records: [record]))
            XCTFail("An unsupported archive must not be replaced")
        } catch {
            XCTAssertEqual(error as? TranscriptFileStoreError, .recoveryRequired)
        }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testSavingBeforeLoadingIsRejected() async throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("transcripts.json")
        let original = Data(#"{"schemaVersion":1,"records":[]}"#.utf8)
        try original.write(to: url)
        let store = TranscriptFileStore(directoryURL: directory)
        do {
            try await store.save(TranscriptArchive(records: [record]))
            XCTFail("Saving must wait until the archive is read")
        } catch {
            XCTAssertEqual(error as? TranscriptFileStoreError, .recoveryRequired)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testExplicitRetryCanRecoverAfterTheArchiveIsRepaired() async throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("transcripts.json")
        try Data("damaged".utf8).write(to: url)
        let store = TranscriptFileStore(directoryURL: directory)
        do { _ = try await store.load() } catch {}
        try Data(#"{"schemaVersion":1,"records":[]}"#.utf8).write(to: url)
        _ = try await store.load()
        let expectedRecord = record
        try await store.save(TranscriptArchive(records: [expectedRecord]))
        let restored = try await store.load()
        XCTAssertEqual(restored.records, [expectedRecord])
    }

    func testRecoveryCopyPreservesUnreadableOriginalAndDoesNotEnableOverwritingIt() async throws {
        let directory = try directory()
        let original = directory.appendingPathComponent("transcripts.json")
        let damaged = Data("damaged archive".utf8)
        try damaged.write(to: original)
        let store = TranscriptFileStore(directoryURL: directory)
        do { _ = try await store.load() } catch {}
        let recovery = directory.appendingPathComponent("recovery.json")
        let archive = TranscriptArchive(records: [record])
        try await store.exportRecoveryCopy(archive, to: recovery)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(TranscriptArchive.self, from: Data(contentsOf: recovery)), archive)
        XCTAssertEqual(try Data(contentsOf: original), damaged)
        do {
            try await store.save(archive)
            XCTFail("Exporting a copy must not unlock the unreadable original")
        } catch {
            XCTAssertEqual(error as? TranscriptFileStoreError, .recoveryRequired)
        }
    }

    func testRecoveryDestinationCannotBeTheOriginalOrASymlinkToIt() async throws {
        let directory = try directory()
        let original = directory.appendingPathComponent("transcripts.json")
        let damaged = Data("original archive".utf8)
        try damaged.write(to: original)
        let alias = directory.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let store = TranscriptFileStore(directoryURL: directory)
        for destination in [original, alias, directory.appendingPathComponent("TRANSCRIPTS.JSON")] {
            do {
                try await store.exportRecoveryCopy(
                    TranscriptArchive(records: [record]), to: destination)
                XCTFail("A recovery copy must never replace the original archive")
            } catch {
                XCTAssertEqual(error as? TranscriptFileStoreError, .recoveryDestinationIsArchive)
            }
        }
        XCTAssertEqual(try Data(contentsOf: original), damaged)
    }

    func testAudioPathCannotEscapeHistoryDirectory() async throws {
        let root = try directory()
        let history = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.m4a")
        try Data("synthetic fixture".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: history.appendingPathComponent("link.m4a"), withDestinationURL: outside)
        let store = TranscriptFileStore(directoryURL: history)
        let escaped = await store.audioURL(relativePath: "../outside.m4a")
        XCTAssertNil(escaped)
        let symlink = await store.audioURL(relativePath: "link.m4a")
        XCTAssertNil(symlink)
    }

    func testDeletingARecordsAudioRemovesTheRetainedFile() async throws {
        let directory = try directory()
        let audio = directory.appendingPathComponent("Audio/take.wav")
        try FileManager.default.createDirectory(
            at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("samples".utf8).write(to: audio)
        let store = TranscriptFileStore(directoryURL: directory)

        await store.remove(relativePath: "Audio/take.wav")

        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testDeletingAudioNeverReachesOutsideTheHistoryDirectory() async throws {
        let directory = try directory()
        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent("voxol-outside-\(UUID().uuidString).wav")
        try Data("someone else's file".utf8).write(to: outside)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let store = TranscriptFileStore(directoryURL: directory)

        await store.remove(relativePath: "../\(outside.lastPathComponent)")

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testUnreadableHistoryIsSetAsideSoNewDictationsCanBeSaved() async throws {
        let directory = try directory()
        let url = directory.appendingPathComponent("transcripts.json")
        let damaged = Data("{\"records\": [interrupted write".utf8)
        try damaged.write(to: url)
        let store = TranscriptFileStore(directoryURL: directory)
        _ = try? await store.load()

        let kept = try await store.setAsideUnreadableArchive()

        XCTAssertEqual(try Data(contentsOf: kept), damaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let archive = TranscriptArchive(records: [record])
        try await store.save(archive)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, archive)
    }

    func testAReadableHistoryIsNeverSetAside() async throws {
        let store = TranscriptFileStore(directoryURL: try directory())
        _ = try? await store.load()
        try await store.save(TranscriptArchive(records: [record]))
        _ = try await store.load()

        do {
            _ = try await store.setAsideUnreadableArchive()
            XCTFail("A history that loads must stay where it is")
        } catch {
            XCTAssertEqual(error as? TranscriptFileStoreError, .archiveIsReadable)
        }
    }

    private func benchmarkSession(
        in directory: URL, named name: String, finalText: String, date: Date
    ) throws -> URL {
        let session = directory.appendingPathComponent("PersonalBenchmark/sessions/\(name)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "finalText": finalText, "rawText": finalText,
            "date": ISO8601DateFormatter().string(from: date),
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: session.appendingPathComponent("meta.json"))
        try Data("audio".utf8).write(to: session.appendingPathComponent("audio.wav"))
        return session
    }

    func testDeletingADictationAlsoDeletesItsBenchmarkRecording() async throws {
        let directory = try directory()
        let now = Date()
        let mine = try benchmarkSession(
            in: directory, named: "a", finalText: "Envoie le rapport.", date: now)
        let other = try benchmarkSession(
            in: directory, named: "b", finalText: "Autre chose.", date: now)
        let sameTextLater = try benchmarkSession(
            in: directory, named: "c", finalText: "Envoie le rapport.",
            date: now.addingTimeInterval(3_600))
        let store = TranscriptFileStore(directoryURL: directory)

        await store.removeBenchmarkRecording(text: "Envoie le rapport.", createdAt: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sameTextLater.path))
    }

    func testErasingEverythingDeletesEveryBenchmarkRecording() async throws {
        let directory = try directory()
        _ = try benchmarkSession(in: directory, named: "a", finalText: "Un.", date: Date())
        _ = try benchmarkSession(in: directory, named: "b", finalText: "Deux.", date: Date())
        let store = TranscriptFileStore(directoryURL: directory)

        await store.removeAllBenchmarkRecordings()

        let sessions = directory.appendingPathComponent("PersonalBenchmark/sessions")
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? [], [])
    }
}
