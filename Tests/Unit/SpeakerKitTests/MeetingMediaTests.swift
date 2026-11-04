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

    @Test func preparedVideoLivesUntilExplicitCleanup() async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "two-track-video", withExtension: "mp4", subdirectory: "Fixtures"))
        let prepared = try await MeetingMedia.prepare(url)
        #expect(prepared.url != url)
        #expect(FileManager.default.fileExists(atPath: prepared.url.path))
        let samples = try SpeakerAudio.load(prepared.url)
        #expect(!samples.isEmpty)
        prepared.cleanup()
        #expect(!FileManager.default.fileExists(atPath: prepared.url.path))
    }

    @Test func streamedSpeakerAudioMatchesCompatibilityLoader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)
        )
        buffer.frameLength = 44_100
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<44_100 {
            channels[0][index] = Float(sin(Double(index) * 0.07)) * 0.2
            channels[1][index] = Float(cos(Double(index) * 0.11)) * 0.1
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let expected = try SpeakerAudio.load(url)
        var streamed = [Float]()
        let count = try SpeakerAudio.streamMono16k(url, samplesPerChunk: 4_321) {
            samples, _, _ in
            streamed.append(contentsOf: samples)
        }
        #expect(count == expected.count)
        #expect(streamed == expected)
    }

    @Test func twoHourSparseWAVIsAcceptedWithoutMaterializingWaveform() async throws {
        let url = try makeSparsePCM16WAV(durationSeconds: 7_200)
        defer { try? FileManager.default.removeItem(at: url) }

        let prepared = try await MeetingMedia.prepare(url)
        #expect(prepared.url == url)
        #expect(abs(prepared.durationSeconds - 7_200) < 0.01)
        prepared.cleanup()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func importLongerThanTwoHoursIsRejectedFromMetadata() async throws {
        let url = try makeSparsePCM16WAV(durationSeconds: 7_201)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await MeetingMedia.prepare(url)
            Issue.record("Audio longer than the two-hour contract must be rejected")
        } catch MeetingMedia.ImportError.invalidDuration {}
    }

    private func makeSparsePCM16WAV(durationSeconds: Int) throws -> URL {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(durationSeconds) * byteRate
        let riffSize = UInt32(36) + dataSize
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID()).wav")

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(riffSize, to: &header)
        header.append(contentsOf: "WAVEfmt ".utf8)
        appendLittleEndian(UInt32(16), to: &header)
        appendLittleEndian(UInt16(1), to: &header)
        appendLittleEndian(channels, to: &header)
        appendLittleEndian(sampleRate, to: &header)
        appendLittleEndian(byteRate, to: &header)
        appendLittleEndian(blockAlign, to: &header)
        appendLittleEndian(bitsPerSample, to: &header)
        header.append(contentsOf: "data".utf8)
        appendLittleEndian(dataSize, to: &header)
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(44) + UInt64(dataSize))
        return url
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
