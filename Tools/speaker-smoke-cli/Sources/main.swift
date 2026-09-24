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
        FileHandle.standardError.write(Data("Reading audio\n".utf8))
        let samples = try SpeakerAudio.load(URL(fileURLWithPath: args[5]))
        FileHandle.standardError.write(Data("Transcribing\n".utf8))
        let asr = ParakeetRuntime(modelRoot: URL(fileURLWithPath: args[1]), computeUnits: .gpu)
        let result = try await asr.transcribe(samples: samples)
        let words = await asr.wordEvidence(for: result).map { word in
            SpeakerWord(
                range: word.sourceRange,
                start: word.frameRange.map { Double($0.lowerBound) * 0.08 },
                end: word.frameRange.map { Double($0.upperBound) * 0.08 })
        }
        FileHandle.standardError.write(Data("Diarizing\n".utf8))
        let activity = try await NativeSpeakerDiarizer().analyze(
            samples: samples, directory: URL(fileURLWithPath: args[3]))
        let turns = try SpeakerAttribution.turns(
            text: result.text, words: words, probabilities: activity.probabilities,
            frameCount: activity.frameCount, duration: Double(samples.count) / 16000)
        let document = SpeakerTranscript(
            title: URL(fileURLWithPath: args[5]).lastPathComponent,
            duration: Double(samples.count) / 16000, rawText: result.text, turns: turns,
            diarizationRevision: SpeakerModelAssets.revision)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: URL(fileURLWithPath: args[7]), options: .atomic)
        print(document.plainText())
        print(
            "\nspeakers=\(document.speakerIDs.count) audio_seconds=\(document.duration) elapsed_seconds=\(Date().timeIntervalSince(started)) frames=\(activity.frameCount)"
        )
    }

    struct UsageError: LocalizedError {
        var errorDescription: String? {
            "Usage: voxol-speaker-smoke --asr <directory> --speakers <directory> --audio <file> --output <json>"
        }
    }
}
