import AVFoundation
import CryptoKit
import Foundation
import ParakeetCore

/// Replays growing dictation prefixes while transcribing only a bounded tail.
/// Full-prefix previews are used as a semantic reference, never as a latency baseline.
enum RollingPreviewBenchmark {
    static func run(_ arguments: [String]) async throws {
        guard arguments.count == 6,
            arguments[0] == "--model-root",
            arguments[2] == "--manifest",
            arguments[4] == "--window-seconds",
            let windowSeconds = Double(arguments[5]),
            windowSeconds.isFinite,
            windowSeconds >= 5,
            windowSeconds < 30
        else { throw Failure.usage }

        let manifestURL = URL(fileURLWithPath: arguments[3])
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: manifestURL)
        )
        guard (1...10).contains(manifest.repetitions), !manifest.samples.isEmpty else {
            throw Failure.usage
        }

        let runtime = ParakeetRuntime(
            modelRoot: URL(fileURLWithPath: arguments[1]), computeUnits: .all)
        let clock = ContinuousClock()
        let loadStart = clock.now
        try await runtime.prepare()
        emit([
            "type": "load",
            "scope": "rolling-preview",
            "milliseconds": milliseconds(loadStart.duration(to: clock.now)),
            "windowSeconds": windowSeconds,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
        ])

        let windowSamples = Int(windowSeconds * 16_000)
        for sample in manifest.samples {
            let audio = try load(sample)
            guard let prefixSeconds = sample.primePrefixSeconds,
                !prefixSeconds.isEmpty
            else { throw Failure.usage }

            var references = [Int: String]()
            for seconds in prefixSeconds {
                let count = Int(seconds * 16_000)
                guard count >= 24_000, count < audio.count else { throw Failure.usage }
                let result = try await runtime.transcribePreview(
                    samples: Array(audio.prefix(count)), sessionID: nil)
                references[count] = result.text
            }

            for repetition in 0..<manifest.repetitions {
                let sessionID = UUID()
                await runtime.beginDictationSession(sessionID)
                var assembler = RollingAssembler()
                for seconds in prefixSeconds {
                    let prefixCount = Int(seconds * 16_000)
                    let prefix = audio.prefix(prefixCount)
                    let tail = Array(prefix.suffix(min(prefix.count, windowSamples)))
                    let started = clock.now
                    let result = try await runtime.transcribePreview(
                        samples: tail, sessionID: sessionID)
                    let wallMilliseconds = milliseconds(started.duration(to: clock.now))
                    let assembly = assembler.observe(result.text)
                    guard let reference = references[prefixCount] else {
                        throw Failure.missingReference(sample.id)
                    }
                    let similarity = wordSimilarity(assembly.text, reference)
                    emit([
                        "type": "rolling-prefix",
                        "id": sample.id,
                        "repetition": repetition,
                        "prefixSeconds": seconds,
                        "windowSeconds": windowSeconds,
                        "tailSeconds": Double(tail.count) / 16_000,
                        "wallMilliseconds": wallMilliseconds,
                        "reusedEncoderChunks": result.timing.reusedEncoderChunks,
                        "matchedWords": assembly.matchedWords,
                        "mergeSucceeded": assembly.mergeSucceeded,
                        "wordSimilarity": similarity,
                        "candidateSHA256": digest(Data(assembly.text.utf8)),
                        "referenceSHA256": digest(Data(reference.utf8)),
                        "exactText": assembly.text == reference,
                        "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                    ])
                }
                await runtime.endDictationSession(sessionID)
            }
        }
    }

    private static func load(_ sample: Sample) throws -> [Float] {
        let audioURL = URL(fileURLWithPath: sample.path)
        let bytes = try Data(contentsOf: audioURL)
        guard digest(bytes) == sample.sha256 else { throw Failure.audioChanged(sample.id) }
        let file = try AVAudioFile(
            forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000,
            file.processingFormat.channelCount == 1,
            file.length > 0,
            file.length <= AVAudioFramePosition(UInt32.max),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw Failure.invalidAudio(sample.id) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?.pointee else {
            throw Failure.invalidAudio(sample.id)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func wordSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalizedWords(lhs)
        let right = normalizedWords(rhs)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        var previous = Array(0...right.count)
        for (row, word) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = row + 1
            for column in 1...right.count {
                current[column] = min(
                    previous[column] + 1,
                    current[column - 1] + 1,
                    previous[column - 1] + (word == right[column - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(max(left.count, right.count))
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.split(whereSeparator: \Character.isWhitespace).compactMap { raw in
            let normalized = raw.lowercased().trimmingCharacters(
                in: .punctuationCharacters.union(.symbols)
            )
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }

    private static func emit(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    private struct Manifest: Decodable {
        let repetitions: Int
        let samples: [Sample]
    }

    private struct Sample: Decodable {
        let id: String
        let path: String
        let sha256: String
        let primePrefixSeconds: [Double]?
    }

    private struct RollingAssembler {
        private var words = [String]()
        private var normalized = [String]()

        mutating func observe(_ hypothesis: String) -> AssemblyResult {
            let incomingWords = hypothesis.split(whereSeparator: \Character.isWhitespace).map(String.init)
            let incomingNormalized = incomingWords.map {
                $0.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            }
            guard !incomingWords.isEmpty else {
                return AssemblyResult(text: words.joined(separator: " "), matchedWords: 0,
                    mergeSucceeded: false)
            }
            guard !words.isEmpty else {
                words = incomingWords
                normalized = incomingNormalized
                return AssemblyResult(text: words.joined(separator: " "), matchedWords: 0,
                    mergeSucceeded: true)
            }

            let match = longestContiguousMatch(
                left: normalized, right: incomingNormalized, minimumWords: 4)
            guard let match else {
                return AssemblyResult(text: words.joined(separator: " "), matchedWords: 0,
                    mergeSucceeded: false)
            }
            words = Array(words.prefix(match.leftStart)) + Array(incomingWords.dropFirst(match.rightStart))
            normalized = Array(normalized.prefix(match.leftStart))
                + Array(incomingNormalized.dropFirst(match.rightStart))
            return AssemblyResult(
                text: words.joined(separator: " "), matchedWords: match.length,
                mergeSucceeded: true)
        }

        private func longestContiguousMatch(
            left: [String], right: [String], minimumWords: Int
        ) -> (leftStart: Int, rightStart: Int, length: Int)? {
            var best: (leftStart: Int, rightStart: Int, length: Int)?
            let leftFloor = max(0, left.count - 220)
            for leftStart in leftFloor..<left.count {
                for rightStart in right.indices {
                    var length = 0
                    while leftStart + length < left.count,
                        rightStart + length < right.count,
                        !left[leftStart + length].isEmpty,
                        left[leftStart + length] == right[rightStart + length]
                    {
                        length += 1
                    }
                    guard length >= minimumWords else { continue }
                    if best == nil
                        || length > best!.length
                        || (length == best!.length && leftStart > best!.leftStart)
                        || (length == best!.length && leftStart == best!.leftStart
                            && rightStart < best!.rightStart)
                    {
                        best = (leftStart, rightStart, length)
                    }
                }
            }
            return best
        }
    }

    private struct AssemblyResult {
        let text: String
        let matchedWords: Int
        let mergeSucceeded: Bool
    }

    private enum Failure: Error {
        case usage
        case audioChanged(String)
        case invalidAudio(String)
        case missingReference(String)
    }
}
