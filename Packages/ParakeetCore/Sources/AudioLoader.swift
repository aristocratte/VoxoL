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

            // Convert in blocks sized to the output rate so rate conversion is steady.
            let outCapacity =
                AVAudioFrameCount(
                    ceil(Double(framesPerChunk) * outFormat.sampleRate / inFormat.sampleRate)
                ) + 64
            guard
                let outBuffer = AVAudioPCMBuffer(
                    pcmFormat: outFormat, frameCapacity: outCapacity
                )
            else {
                throw ParakeetError.audioLoadFailed(
                    url: url,
                    underlying: AudioLoaderError.bufferAllocationFailed
                )
            }

            var converterError: NSError?
            let status =
                converter.convert(
                    to: outBuffer, error: &converterError, withInputFrom: inputBlock
                )

            if let err = converterError {
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
}

private enum AudioLoaderError: Error {
    case bufferAllocationFailed
}

private final class AudioInputProvider: @unchecked Sendable {
    let file: AVAudioFile
    let buffer: AVAudioPCMBuffer
    private(set) var reachedEnd = false

    init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
        self.file = file
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !reachedEnd else {
            status.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
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
