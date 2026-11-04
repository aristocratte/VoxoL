// Adapted for VoxoL from parakeet-coreml-swift commit 75aec2a1c991319657ff4dec5f602c12da6c5012.
// Changes are documented in Packages/ParakeetCore/NOTICE.md.
@preconcurrency import AVFoundation
import Foundation

/// Loads any AVFoundation-readable audio (wav / flac / mp3 / m4a / ...) into
/// a 16 kHz mono `[Float]` waveform in [-1, 1].
///
/// Uses `AVAudioConverter` so resampling + channel down-mix + bit-depth
/// conversion all happen in one pass.
enum AudioLoader {
    struct MappedMono16k: Sendable {
        let data: Data
        let sampleCount: Int
    }

    static func loadMono16k(at url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ParakeetError.audioLoadFailed(url: url, underlying: error)
        }

        let inFormat = file.processingFormat
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        else {
            throw ParakeetError.audioLoadFailed(
                url: url,
                underlying: AudioLoaderError.bufferAllocationFailed
            )
        }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw ParakeetError.audioLoadFailed(
                url: url,
                underlying: AudioLoaderError.bufferAllocationFailed
            )
        }
        converter.sampleRateConverterQuality = Int(AVAudioQuality.high.rawValue)

        let framesPerChunk: AVAudioFrameCount = 4096
        guard
            let inBuffer = AVAudioPCMBuffer(
                pcmFormat: inFormat, frameCapacity: framesPerChunk
            ),
            let outBuffer = AVAudioPCMBuffer(
                pcmFormat: outFormat,
                frameCapacity: AVAudioFrameCount(
                    ceil(Double(framesPerChunk) * outFormat.sampleRate / inFormat.sampleRate)
                ) + 64
            )
        else {
            throw ParakeetError.audioLoadFailed(
                url: url,
                underlying: AudioLoaderError.bufferAllocationFailed
            )
        }

        var output = [Float]()
        output.reserveCapacity(Int(file.length) * 16_000 / Int(inFormat.sampleRate) + 1024)

        let input = AudioInputProvider(file: file, buffer: inBuffer)
        while true {
            // AVAudioConverter invokes this provider synchronously and serially.
            let inputBlock: AVAudioConverterInputBlock = { _, statusPtr in
                input.next(status: statusPtr)
            }

            var converterError: NSError?
            let status =
                converter.convert(
                    to: outBuffer, error: &converterError, withInputFrom: inputBlock
                )

            if let err = converterError {
                throw ParakeetError.audioLoadFailed(url: url, underlying: err)
            }
            if let err = input.error {
                throw ParakeetError.audioLoadFailed(url: url, underlying: err)
            }

            if outBuffer.frameLength > 0, let ch = outBuffer.floatChannelData {
                let ptr = ch[0]
                let count = Int(outBuffer.frameLength)
                output.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
            }

            if status == .endOfStream || status == .error {
                break
            }
            if input.reachedEnd && outBuffer.frameLength == 0 {
                break
            }
        }

        if output.isEmpty {
            throw ParakeetError.audioEmpty(url: url)
        }
        return output
    }

    /// Converts audio once into a temporary native Float32 PCM file and maps it
    /// read-only. Long-form inference can then materialize only the current
    /// encoder window instead of retaining the complete waveform in heap memory.
    static func mapMono16k(
        at url: URL,
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) throws -> MappedMono16k {
        try cancellationCheck()
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ParakeetError.audioLoadFailed(url: url, underlying: error)
        }
        let inFormat = file.processingFormat
        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else {
            throw ParakeetError.audioLoadFailed(
                url: url,
                underlying: AudioLoaderError.bufferAllocationFailed
            )
        }
        converter.sampleRateConverterQuality = Int(AVAudioQuality.high.rawValue)

        let framesPerChunk: AVAudioFrameCount = 4096
        guard
            let inBuffer = AVAudioPCMBuffer(
                pcmFormat: inFormat, frameCapacity: framesPerChunk
            ),
            let outBuffer = AVAudioPCMBuffer(
                pcmFormat: outFormat,
                frameCapacity: AVAudioFrameCount(
                    ceil(Double(framesPerChunk) * outFormat.sampleRate / inFormat.sampleRate)
                ) + 64
            )
        else {
            throw ParakeetError.audioLoadFailed(
                url: url,
                underlying: AudioLoaderError.bufferAllocationFailed
            )
        }
        let input = AudioInputProvider(file: file, buffer: inBuffer)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxol-mono16k-\(UUID().uuidString).f32")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw ParakeetError.audioLoadFailed(
                url: url,
                underlying: AudioLoaderError.bufferAllocationFailed
            )
        }
        let handle = try FileHandle(forWritingTo: temporary)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }

        var sampleCount = 0
        while true {
            try cancellationCheck()
            let inputBlock: AVAudioConverterInputBlock = { _, statusPtr in
                input.next(status: statusPtr)
            }
            var converterError: NSError?
            let status = converter.convert(
                to: outBuffer,
                error: &converterError,
                withInputFrom: inputBlock
            )
            if let err = converterError {
                throw ParakeetError.audioLoadFailed(url: url, underlying: err)
            }
            if let err = input.error {
                throw ParakeetError.audioLoadFailed(url: url, underlying: err)
            }
            if outBuffer.frameLength > 0, let channels = outBuffer.floatChannelData {
                let count = Int(outBuffer.frameLength)
                let bytes = Data(
                    bytes: channels[0],
                    count: count * MemoryLayout<Float>.size
                )
                try handle.write(contentsOf: bytes)
                sampleCount += count
            }
            if status == .endOfStream || status == .error {
                break
            }
            if input.reachedEnd && outBuffer.frameLength == 0 {
                break
            }
        }
        try cancellationCheck()
        guard sampleCount > 0 else { throw ParakeetError.audioEmpty(url: url) }
        try handle.synchronize()
        let data = try Data(contentsOf: temporary, options: .alwaysMapped)
        guard data.count == sampleCount * MemoryLayout<Float>.size else {
            throw ParakeetError.audioLoadFailed(
                url: url,
                underlying: AudioLoaderError.bufferAllocationFailed
            )
        }
        return MappedMono16k(data: data, sampleCount: sampleCount)
    }
}

private enum AudioLoaderError: Error {
    case bufferAllocationFailed
}

private final class AudioInputProvider: @unchecked Sendable {
    let file: AVAudioFile
    let buffer: AVAudioPCMBuffer
    private(set) var reachedEnd = false
    private(set) var error: Error?

    init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
        self.file = file
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !reachedEnd, file.framePosition < file.length else {
            status.pointee = .endOfStream
            reachedEnd = true
            return nil
        }
        do {
            try file.read(
                into: buffer,
                frameCount: AVAudioFrameCount(
                    min(
                        Int64(buffer.frameCapacity),
                        file.length - file.framePosition
                    )
                )
            )
        } catch {
            self.error = error
            status.pointee = .endOfStream
            reachedEnd = true
            return nil
        }
        guard buffer.frameLength > 0 else {
            status.pointee = .endOfStream
            reachedEnd = true
            return nil
        }
        status.pointee = .haveData
        return buffer
    }
}
