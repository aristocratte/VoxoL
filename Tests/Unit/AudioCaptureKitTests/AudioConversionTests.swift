@preconcurrency import AVFoundation
import XCTest

@testable import AudioCaptureKit

final class AudioConversionTests: XCTestCase {
    func testNativeProbePreservesBothChannelsBeforeGainAndDownmix() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
            )
        )
        let processor = try XCTUnwrap(
            AudioTapProcessor(inputFormat: format, ringCapacity: 16_000, retainsNativeAudio: true))
        let count = 1_024
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        let left = (0..<count).map { Float($0) / 10_000 }
        let right = left.map { -$0 / 2 }
        for (index, channel) in [left, right].enumerated() {
            channel.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress!, count: count)
            }
        }
        processor.consume(buffer)
        let native = try XCTUnwrap(processor.drainNativeAudio())
        XCTAssertEqual(native.sampleRate, 48_000)
        XCTAssertEqual(native.channels, [left, right])
        XCTAssertEqual(native.droppedFrameCount, 0)
        XCTAssertFalse(processor.drainSamples().isEmpty)
    }

    func testOrdinaryCaptureDoesNotRetainNativeAudio() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false
            ))
        let processor = try XCTUnwrap(AudioTapProcessor(inputFormat: format, ringCapacity: 16_000))
        XCTAssertNil(processor.drainNativeAudio())
    }

    func testOriginalRetentionBeyondProbeLimitDoesNotChangeASR() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false
            ))
        let ordinary = try XCTUnwrap(
            AudioTapProcessor(inputFormat: format, ringCapacity: 20 * 16_000))
        let retained = try XCTUnwrap(
            AudioTapProcessor(
                inputFormat: format, ringCapacity: 20 * 16_000, retainsNativeAudio: true,
                maximumNativeDurationSeconds: 20))
        let count = 16 * 44_100
        var offset = 0
        while offset < count {
            let frames = min(1_024, count - offset)
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            for index in 0..<frames {
                buffer.floatChannelData![0][index] = Float((offset + index) % 101) / 10_000
            }
            ordinary.consume(buffer)
            retained.consume(buffer)
            offset += frames
        }
        let native = try XCTUnwrap(retained.drainNativeAudio())
        XCTAssertTrue(native.isComplete)
        XCTAssertEqual(native.channels[0].count, count)
        XCTAssertEqual(ordinary.drainSamples(), retained.drainSamples())
    }

    func testTruncatedOriginalCannotBeExportedAsCompleteRecording() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
            ))
        let processor = try XCTUnwrap(
            AudioTapProcessor(
                inputFormat: format, ringCapacity: 32_000, retainsNativeAudio: true,
                maximumNativeDurationSeconds: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        buffer.floatChannelData![0].initialize(repeating: 0.01, count: 1_024)
        for _ in 0..<20 { processor.consume(buffer) }
        let native = try XCTUnwrap(processor.drainNativeAudio())
        XCTAssertEqual(native.channels[0].count, 16_000)
        XCTAssertGreaterThan(native.droppedFrameCount, 0)
        XCTAssertFalse(native.isComplete)
        XCTAssertThrowsError(try native.wavData())
        XCTAssertEqual(processor.status.droppedSampleCount, 0)
    }

    func testPeriodicDrainKeepsCompleteNativeRecordingPastBufferCapacity() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false)
        )
        let processor = try XCTUnwrap(
            AudioTapProcessor(
                inputFormat: format, ringCapacity: 2 * 16_000,
                retainsNativeAudio: true, maximumNativeDurationSeconds: 1))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        var offset = 0
        while offset < 3 * 16_000 {
            let count = min(1_024, 3 * 16_000 - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                buffer.floatChannelData![0][index] = Float(offset + index) / 100_000
            }
            processor.consume(buffer)
            offset += count
            if offset / 8_000 != (offset - count) / 8_000 {
                processor.collectSamples()
            }
        }
        let native = try XCTUnwrap(processor.drainNativeAudio())
        XCTAssertTrue(native.isComplete)
        XCTAssertEqual(native.channels[0].count, 3 * 16_000)
        XCTAssertEqual(native.channels[0].first, 0)
        XCTAssertEqual(native.channels[0].last, Float(3 * 16_000 - 1) / 100_000)
        XCTAssertEqual(processor.status.droppedSampleCount, 0)
    }

    func testOriginalWAVRoundTripsBothFloatChannelsExactly() throws {
        let left: [Float] = (0..<4_800).map { Float($0 - 2_400) / Float(10_001) }
        let right: [Float] = (0..<4_800).map { Float(2_400 - $0) / Float(30_007) }
        let channels = [left, right]
        let native = NativeCapturedAudio(
            channels: channels, sampleRate: 48_000, droppedFrameCount: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try native.wavData().write(to: url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800))
        try file.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, 4_800)
        for index in 0..<2 {
            XCTAssertEqual(
                Array(UnsafeBufferPointer(start: buffer.floatChannelData![index], count: 4_800)),
                channels[index])
        }
    }

    func testMicrophoneRatesKeepDurationAndAnUnbrokenToneAcrossTapBuffers() throws {
        for rate in [44_100.0, 48_000.0] {
            let samples = try convertTone(rate: rate, frequency: 1_000, amplitude: 0.02)
            // Streaming conversion may retain a short filter tail when capture stops.
            XCTAssertEqual(Double(samples.count), 32_000, accuracy: 640, "\(rate) Hz")
            let quality = toneQuality(samples, frequency: 1_000)
            XCTAssertGreaterThan(quality.signalToResidualDB, 65, "\(rate) Hz: \(quality)")
            XCTAssertEqual(quality.amplitude, 0.023, accuracy: 0.001)
        }
    }

    func testQuietVoiceLevelDoesNotBecomeCoarselyQuantizedBeforeASR() throws {
        let samples = try convertTone(rate: 44_100, frequency: 700, amplitude: 0.005)
        let quality = toneQuality(samples, frequency: 700)
        XCTAssertGreaterThan(quality.signalToResidualDB, 65, "\(quality)")
        XCTAssertEqual(quality.amplitude, 0.00575, accuracy: 0.0003)
    }

    func testConverterPreservesSpeechBandAndRejectsAboveNyquist() throws {
        for rate in [44_100.0, 48_000.0] {
            let speech = toneQuality(
                try convertTone(rate: rate, frequency: 6_000, amplitude: 0.02), frequency: 6_000)
            XCTAssertGreaterThan(speech.amplitude, 0.021)
            let above = try convertTone(rate: rate, frequency: 10_000, amplitude: 0.02)
            let interior = above.dropFirst(800).dropLast(800)
            let rms = sqrt(interior.reduce(0.0) { $0 + Double($1 * $1) } / Double(interior.count))
            XCTAssertLessThan(rms, 0.0001, "Above-band audio must not alias into speech")
            print(
                "conversion rate=\(rate) speech6kAmplitude=\(speech.amplitude) above10kResidualRMS=\(rms)"
            )
        }
    }

    func testDrainHandlerRunsOnBackgroundQueue() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false)
        )
        let processor = try XCTUnwrap(
            AudioTapProcessor(inputFormat: format, ringCapacity: 16_000))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024
        for index in 0..<1_024 {
            buffer.floatChannelData![0][index] = 0.02
        }
        processor.consume(buffer)

        let handler = AudioCaptureSession.makeDrainHandler(processor: processor)
        DispatchQueue(label: "voxol.test-background-drain").sync(execute: handler)

        XCTAssertGreaterThan(processor.drainSamples().count, 0)
        XCTAssertEqual(processor.status.droppedSampleCount, 0)
    }

    func testPeriodicDrainKeepsMoreThanThreeMinutesInOrder() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false)
        )
        // Only two seconds fit in the callback ring. The collector must keep
        // the full session while that ring is reused for 181 seconds.
        let processor = try XCTUnwrap(
            AudioTapProcessor(inputFormat: format, ringCapacity: 2 * 16_000))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        let totalFrames = 181 * 16_000
        var offset = 0
        while offset < totalFrames {
            let count = min(1_024, totalFrames - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let frame = offset + index
                let amplitude = frame < 90 * 16_000 ? 0.01 : 0.03
                buffer.floatChannelData![0][index] = Float(
                    amplitude * sin(2 * .pi * 400 * Double(frame) / 16_000))
            }
            processor.consume(buffer)
            offset += count
            if offset / 16_000 != (offset - count) / 16_000 {
                processor.collectSamples()
            }
        }
        let samples = processor.drainSamples()
        XCTAssertEqual(processor.status.droppedSampleCount, 0)
        XCTAssertEqual(Double(samples.count), Double(totalFrames), accuracy: 1_024)
        XCTAssertGreaterThan(samples.count, 180 * 16_000)
        let earlyRMS = sqrt(
            samples[16_000..<32_000].reduce(0.0) { $0 + Double($1 * $1) } / 16_000)
        let lateRMS = sqrt(
            samples[(179 * 16_000)..<(180 * 16_000)].reduce(0.0) {
                $0 + Double($1 * $1)
            } / 16_000)
        XCTAssertGreaterThan(lateRMS, earlyRMS * 2)
    }

    private func convertTone(rate: Double, frequency: Double, amplitude: Double) throws -> [Float] {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        )
        let processor = try XCTUnwrap(AudioTapProcessor(inputFormat: format, ringCapacity: 40_000))
        let frameCount = Int(rate * 2)
        var offset = 0
        while offset < frameCount {
            let count = min(1_024, frameCount - offset)
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<count {
                channel[index] = Float(
                    amplitude * sin(2 * .pi * frequency * Double(offset + index) / rate))
            }
            processor.consume(buffer)
            offset += count
        }
        XCTAssertEqual(processor.status.droppedSampleCount, 0)
        return processor.drainSamples()
    }

    private func toneQuality(_ samples: [Float], frequency: Double) -> (
        amplitude: Double, signalToResidualDB: Double
    ) {
        let start = 800
        let count = min(24_000, samples.count - 2 * start)
        var sine: Double = 0
        var cosine: Double = 0
        for index in 0..<count {
            let phase = 2 * Double.pi * frequency * Double(index) / 16_000
            sine += Double(samples[index + start]) * sin(phase)
            cosine += Double(samples[index + start]) * cos(phase)
        }
        sine *= 2 / Double(count)
        cosine *= 2 / Double(count)
        var residual: Double = 0
        for index in 0..<count {
            let phase = 2 * Double.pi * frequency * Double(index) / 16_000
            let error = Double(samples[index + start]) - sine * sin(phase) - cosine * cos(phase)
            residual += error * error
        }
        let signal = (sine * sine + cosine * cosine) / 2
        return (sqrt(signal * 2), 10 * log10(signal / max(1e-20, residual / Double(count))))
    }
}
