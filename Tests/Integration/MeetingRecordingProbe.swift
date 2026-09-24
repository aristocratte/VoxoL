// Appended to the production MeetingRecorder.swift by check-meeting-recording.py.
// Synthetic PCM only: never asks for microphone, screen or calendar permissions.
@main struct MeetingRecordingProbe {
    static func sample(at seconds: Double, frequency: Double) throws -> CMSampleBuffer {
        let frames = 480
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32,
            mReserved: 0)
        var format: CMAudioFormatDescription?
        precondition(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &format) == noErr)
        var data: CMBlockBuffer?
        precondition(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil, blockLength: frames * 4, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: frames * 4, flags: 0,
                blockBufferOut: &data) == noErr)
        let values = (0..<frames).map {
            Float(sin(2 * .pi * frequency * (seconds + Double($0) / 48000))) * 0.1
        }
        guard let data else { preconditionFailure("Missing block buffer") }
        values.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else {
                preconditionFailure("Missing audio bytes")
            }
            precondition(
                CMBlockBufferReplaceDataBytes(
                    with: address, blockBuffer: data,
                    offsetIntoDestination: 0, dataLength: frames * 4) == noErr)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48000),
            decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        precondition(
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: data,
                formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &buffer) == noErr)
        guard let buffer else { preconditionFailure("Missing sample buffer") }
        return buffer
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let url = root.appendingPathComponent("synthetic-call.mov")
        let sink = try MeetingCallOutput(url: url) { message in
            FileHandle.standardError.write(Data(("WRITER FAILURE: " + message + "\n").utf8))
        }
        // One second, then two seconds paused, then another second. Two concurrent voices.
        for index in 0..<100 {
            sink.append(try sample(at: 10 + Double(index) / 100, frequency: 440), type: .audio)
            sink.append(try sample(at: 10 + Double(index) / 100, frequency: 880), type: .microphone)
            try await Task.sleep(for: .milliseconds(10))
        }
        sink.setPaused(true)
        sink.append(try sample(at: 12, frequency: 1600), type: .audio)
        sink.setPaused(false)
        for index in 0..<100 {
            sink.append(try sample(at: 13 + Double(index) / 100, frequency: 440), type: .audio)
            sink.append(try sample(at: 13 + Double(index) / 100, frequency: 880), type: .microphone)
            try await Task.sleep(for: .milliseconds(10))
        }
        let measured = sink.snapshot()
        precondition(abs(measured.duration - 2) < 0.01, "Pause must not add silence to recording")
        try await sink.finish()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        precondition(tracks.count == 2 && video.isEmpty)
        precondition(abs(duration - 2) < 0.1)
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
                ])
            reader.add(output)
            precondition(reader.startReading())
            var frames = 0
            while let buffer = output.copyNextSampleBuffer() { frames += buffer.numSamples }
            precondition(reader.status == .completed && frames > 90000)
        }
        print(
            "PASS: two audio tracks, no video, both tails readable, pause removed; duration=\(duration)s, level=\(measured.level)"
        )
    }
}
