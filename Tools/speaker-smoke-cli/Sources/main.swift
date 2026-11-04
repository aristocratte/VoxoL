import Foundation
import ParakeetCore
import SpeakerKit

@main
struct SpeakerSmokeCLI {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 8, args[0] == "--asr", args[2] == "--speakers",
            args[4] == "--audio", args[6] == "--output"
        else { throw UsageError() }
        let started = Date()
        let sourceURL = URL(fileURLWithPath: args[5])
        FileHandle.standardError.write(Data("Preparing audio\n".utf8))
        let prepared = try await MeetingMedia.prepare(sourceURL)
        defer { prepared.cleanup() }

        FileHandle.standardError.write(Data("Transcribing\n".utf8))
        let asrStarted = Date()
        let asr = try await transcribeFileBacked(
            audioURL: prepared.url,
            modelRoot: URL(fileURLWithPath: args[1])
        )
        let asrSeconds = Date().timeIntervalSince(asrStarted)

        FileHandle.standardError.write(Data("Diarizing\n".utf8))
        let diarizationStarted = Date()
        let activity = try await NativeSpeakerDiarizer().analyze(
            audioURL: prepared.url, directory: URL(fileURLWithPath: args[3]))
        let diarizationSeconds = Date().timeIntervalSince(diarizationStarted)
        let turns = try SpeakerAttribution.turns(
            text: asr.text, words: asr.words, probabilities: activity.probabilities,
            frameCount: activity.frameCount, duration: asr.durationSeconds)
        let document = SpeakerTranscript(
            title: sourceURL.lastPathComponent,
            duration: asr.durationSeconds, rawText: asr.text, turns: turns,
            diarizationRevision: SpeakerModelAssets.revision)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: URL(fileURLWithPath: args[7]), options: .atomic)
        print(document.plainText())
        print(
            "\nspeakers=\(document.speakerIDs.count) audio_seconds=\(document.duration) asr_seconds=\(asrSeconds) diarization_seconds=\(diarizationSeconds) elapsed_seconds=\(Date().timeIntervalSince(started)) frames=\(activity.frameCount)"
        )
    }

    private struct FileBackedASRResult: Sendable {
        let text: String
        let durationSeconds: Double
        let words: [SpeakerWord]
    }

    private static func transcribeFileBacked(
        audioURL: URL,
        modelRoot: URL
    ) async throws -> FileBackedASRResult {
        // Scope the runtime to the ASR phase so its Core ML models can be
        // released before the diarization model is loaded, matching MeetingsStore.
        let runtime = ParakeetRuntime(modelRoot: modelRoot, computeUnits: .gpu)
        let result = try await runtime.transcribe(audioURL: audioURL)
        let words = await runtime.wordEvidence(for: result).map { word in
            SpeakerWord(
                range: word.sourceRange,
                start: word.frameRange.map { Double($0.lowerBound) * 0.08 },
                end: word.frameRange.map { Double($0.upperBound) * 0.08 }
            )
        }
        return FileBackedASRResult(
            text: result.text,
            durationSeconds: result.audioDurationSeconds,
            words: words
        )
    }

    struct UsageError: LocalizedError {
        var errorDescription: String? {
            "Usage: voxol-speaker-smoke --asr <directory> --speakers <directory> --audio <file> --output <json>"
        }
    }
}
