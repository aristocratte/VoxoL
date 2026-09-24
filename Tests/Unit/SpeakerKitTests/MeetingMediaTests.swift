import AVFoundation
import Foundation
import Testing
@testable import SpeakerKit

struct MeetingMediaTests {
    @Test func videoImportMixesBothAudioTracksWithoutDecodingVideo() async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "two-track-video", withExtension: "mp4", subdirectory: "Fixtures"))
        let original = try Data(contentsOf: url)
        let samples = try await MeetingMedia.load(url)
        #expect(abs(samples.count - 32000) < 1200)
        #expect(samples.allSatisfy { $0.isFinite })
        // Each track contains a distinct tone. Losing either stream fails this test.
        for frequency in [440.0, 880.0] {
            let middle = Array(samples[8000..<24000])
            let real = middle.enumerated().reduce(0.0) {
                $0 + Double($1.element) * cos(2 * .pi * frequency * Double($1.offset) / 16000)
            }
            let imaginary = middle.enumerated().reduce(0.0) {
                $0 + Double($1.element) * sin(2 * .pi * frequency * Double($1.offset) / 16000)
            }
            #expect(sqrt(real * real + imaginary * imaginary) / Double(middle.count) > 0.01)
        }
        let preserved = try Data(contentsOf: url)
        #expect(preserved == original)
    }

    @Test func silentVideoReportsMissingAudio() async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "silent-video", withExtension: "mp4", subdirectory: "Fixtures"))
        do {
            _ = try await MeetingMedia.load(url)
            Issue.record("Silent video must be rejected")
        } catch MeetingMedia.ImportError.noAudio {}
    }

    @Test func audioFastPathPreservesSamplesExactly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<16000 { channel[index] = Float(sin(Double(index) * 0.1)) * 0.2 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let expected = try SpeakerAudio.load(url)
        let actual = try await MeetingMedia.load(url)
        #expect(actual == expected)
    }

    @Test func cancelledImportDoesNotReturnAudio() async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "two-track-video", withExtension: "mp4", subdirectory: "Fixtures"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingMedia.load(url)
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled import must throw")
        } catch is CancellationError {}
    }
}
