@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
import Foundation

/// Speaker activity on a continuous 10 ms timeline.
public struct SpeakerActivity: Sendable {
    /// Frame-major probabilities with eight voice slots per frame.
    public let probabilities: [Float]
    /// Number of complete frames in the probability array.
    public let frameCount: Int
}

/// Owns each Nemotron inference session on a serial executor.
public actor NativeSpeakerDiarizer {
    /// Creates a new value with the supplied local data.
    public init() {}

    /// Runs local diarization with cancellation between audio chunks.
    public func analyze(
        samples: [Float], directory: URL,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> SpeakerActivity {
        guard !samples.isEmpty, samples.count <= 16_000 * 7200,
            samples.allSatisfy(\.isFinite)
        else { throw SpeakerError.invalidAudio }
        try SpeakerModelAssets.verify(directory: directory)
        let config = Nemotron3Config.fast32
        let models = try await Nemotron3Models.load(config: config, directory: directory)
        try Task.checkCancellation()
        let diarizer = Nemotron3Diarizer(config: config, models: models)
        var probabilities: [Float] = []
        probabilities.reserveCapacity((samples.count / 160 + 1) * 8)
        // Use the upstream streaming frontend even for files: cancellation and
        // autorelease drainage happen at each 2.56-second audio step.
        for offset in stride(from: 0, to: samples.count, by: 40_960) {
            try Task.checkCancellation()
            let end = min(samples.count, offset + 40_960)
            try autoreleasepool {
                diarizer.appendAudio(Array(samples[offset..<end]))
                for chunk in try diarizer.processBufferedAudio() {
                    probabilities.append(contentsOf: chunk.probabilities)
                }
            }
            progress(Double(end) / Double(samples.count))
        }
        try Task.checkCancellation()
        for chunk in try diarizer.finishStream() {
            probabilities.append(contentsOf: chunk.probabilities)
        }
        return SpeakerActivity(probabilities: probabilities, frameCount: probabilities.count / 8)
    }

    /// File-backed diarization for long imports. The converter feeds the
    /// upstream streaming frontend in bounded chunks, so a two-hour recording
    /// does not require a two-hour Float32 waveform in heap memory.
    public func analyze(
        audioURL: URL, directory: URL,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> SpeakerActivity {
        try SpeakerModelAssets.verify(directory: directory)
        let config = Nemotron3Config.fast32
        let models = try await Nemotron3Models.load(config: config, directory: directory)
        try Task.checkCancellation()
        let diarizer = Nemotron3Diarizer(config: config, models: models)
        var probabilities: [Float] = []
        let totalSamples = try SpeakerAudio.streamMono16k(audioURL) {
            samples, processedSamples, estimatedSamples in
            try Task.checkCancellation()
            try autoreleasepool {
                diarizer.appendAudio(samples)
                for chunk in try diarizer.processBufferedAudio() {
                    probabilities.append(contentsOf: chunk.probabilities)
                }
            }
            progress(
                min(
                    1,
                    Double(processedSamples) / Double(max(1, estimatedSamples))
                )
            )
        }
        guard totalSamples > 0 else { throw SpeakerError.invalidAudio }
        try Task.checkCancellation()
        for chunk in try diarizer.finishStream() {
            probabilities.append(contentsOf: chunk.probabilities)
        }
        progress(1)
        return SpeakerActivity(probabilities: probabilities, frameCount: probabilities.count / 8)
    }
}

/// Bounded native file decoding shared by transcription and diarization.
public enum SpeakerAudio {
    public static let maximumDurationSeconds: Double = 2 * 60 * 60

    /// Bounded, continuous sample-rate conversion. Both networks receive the same samples.
    public static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard duration.isFinite, duration > 0, duration <= maximumDurationSeconds,
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: format, to: target),
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)
        else { throw SpeakerError.invalidAudio }
        converter.sampleRateConverterQuality = Int(AVAudioQuality.high.rawValue)
        let source = Input(file: file, buffer: inputBuffer)
        var samples: [Float] = []
        samples.reserveCapacity(Int(duration * 16000) + 4096)
        while true {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, state in
                source.read(state)
            }
            if let error { throw error }
            if let error = source.error { throw error }
            guard status != .error else { throw SpeakerError.invalidAudio }
            if let values = outputBuffer.floatChannelData {
                samples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: values[0], count: Int(outputBuffer.frameLength)))
            }
            guard samples.count <= 16_000 * Int(maximumDurationSeconds) else {
                throw SpeakerError.invalidAudio
            }
            if status == .endOfStream { break }
            if source.finished && outputBuffer.frameLength == 0 { break }
        }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
            throw SpeakerError.invalidAudio
        }
        return samples
    }

    /// Converts a file to mono 16 kHz in bounded chunks without retaining the
    /// complete waveform. Returns the exact number of emitted samples.
    @discardableResult
    public static func streamMono16k(
        _ url: URL,
        samplesPerChunk: Int = 40_960,
        _ consume: (_ samples: [Float], _ processedSamples: Int, _ estimatedSamples: Int) throws -> Void
    ) throws -> Int {
        guard samplesPerChunk > 0 else { throw SpeakerError.invalidAudio }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard duration.isFinite, duration > 0, duration <= maximumDurationSeconds,
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: format, to: target),
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)
        else { throw SpeakerError.invalidAudio }
        converter.sampleRateConverterQuality = Int(AVAudioQuality.high.rawValue)
        let source = Input(file: file, buffer: inputBuffer)
        let estimatedSamples = max(1, Int(duration * 16_000))
        let maximumSamples = 16_000 * Int(maximumDurationSeconds)
        var pending = [Float]()
        pending.reserveCapacity(samplesPerChunk + 4096)
        var processedSamples = 0

        while true {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, state in
                source.read(state)
            }
            if let error { throw error }
            if let error = source.error { throw error }
            guard status != .error else { throw SpeakerError.invalidAudio }
            if let values = outputBuffer.floatChannelData, outputBuffer.frameLength > 0 {
                pending.append(
                    contentsOf: UnsafeBufferPointer(
                        start: values[0], count: Int(outputBuffer.frameLength)
                    )
                )
            }
            while pending.count >= samplesPerChunk {
                let chunk = Array(pending.prefix(samplesPerChunk))
                guard chunk.allSatisfy(\.isFinite) else { throw SpeakerError.invalidAudio }
                pending.removeFirst(samplesPerChunk)
                processedSamples += chunk.count
                guard processedSamples <= maximumSamples else { throw SpeakerError.invalidAudio }
                try consume(chunk, processedSamples, estimatedSamples)
            }
            if status == .endOfStream { break }
            if source.finished && outputBuffer.frameLength == 0 { break }
        }
        if !pending.isEmpty {
            guard pending.allSatisfy(\.isFinite) else { throw SpeakerError.invalidAudio }
            processedSamples += pending.count
            guard processedSamples <= maximumSamples else { throw SpeakerError.invalidAudio }
            try consume(pending, processedSamples, estimatedSamples)
        }
        guard processedSamples > 0 else { throw SpeakerError.invalidAudio }
        return processedSamples
    }

    /// AVAudioConverter calls its input provider synchronously on the conversion thread.
    private final class Input: @unchecked Sendable {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        var finished = false
        var error: Error?
        init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
            self.file = file
            self.buffer = buffer
        }
        func read(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard !finished, file.framePosition < file.length else {
                finished = true
                state.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(
                    into: buffer,
                    frameCount: AVAudioFrameCount(
                        min(Int64(buffer.frameCapacity), file.length - file.framePosition)))
                if buffer.frameLength > 0 { state.pointee = .haveData; return buffer }
            } catch { self.error = error }
            finished = true
            state.pointee = .endOfStream
            return nil
        }
    }
}
