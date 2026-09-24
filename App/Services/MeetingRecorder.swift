import AppKit
@preconcurrency import AVFoundation
import Observation
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor @Observable
final class MeetingRecorder: NSObject, AVAudioRecorderDelegate {
    static weak var activeRecorder: MeetingRecorder?
    enum Source: String, CaseIterable { case microphone, call }
    enum State { case idle, preparing, recording, paused, finishing }
    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0
    private(set) var completedURL: URL?
    private(set) var title = ""
    var failure: String?
    @ObservationIgnored private var microphone: AVAudioRecorder?
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: MeetingCallOutput?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var destination: URL?

    var active: Bool { state != .idle }

    func start(title: String, source: Source) async {
        guard !active, completedURL == nil else { return }
        failure = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [source == .call ? .quickTimeMovie : .mpeg4Audio]
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue =
            (clean.isEmpty ? "Meeting" : clean)
            + (source == .call ? ".mov" : ".m4a")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.title = clean.isEmpty ? url.deletingPathExtension().lastPathComponent : clean
        destination = url
        state = .preparing
        Self.activeRecorder = self
        elapsed = 0
        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw RecordingError.microphonePermission
            }
            if source == .microphone {
                let recorder = try AVAudioRecorder(
                    url: url,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 48000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 128000,
                    ])
                recorder.delegate = self
                recorder.isMeteringEnabled = true
                guard recorder.prepareToRecord(), recorder.record() else {
                    throw RecordingError.couldNotStart
                }
                microphone = recorder
            } else {
                // No screen output is attached or persisted: only the two audio streams.
                let content = try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { throw RecordingError.noDisplay }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
                config.capturesAudio = true
                config.captureMicrophone = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
                let sink = try MeetingCallOutput(url: url) { [weak self] message in
                    Task { @MainActor in
                        guard let self else { return }
                        self.failure = message
                        await self.stop()
                    }
                }
                let capture = SCStream(filter: filter, configuration: config, delegate: sink)
                try capture.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                try capture.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
                output = sink
                stream = capture
                try await capture.startCapture()
            }
            state = .recording
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    self.updateMeter()
                    // Both downstream models are bounded to one hour. Leave room for AAC padding.
                    if self.elapsed >= 3598 { await self.stop(); return }
                }
            }
        } catch {
            failure = error.localizedDescription
            if let stream { try? await stream.stopCapture() }
            if let output { try? await output.finish() }
            microphone?.stop()
            microphone = nil
            stream = nil
            output = nil
            state = .idle
            Self.activeRecorder = nil
        }
    }

    func togglePause() {
        switch state {
        case .recording:
            microphone?.pause()
            output?.setPaused(true)
            state = .paused
            level = 0
        case .paused:
            if let microphone, !microphone.record() {
                failure = RecordingError.couldNotStart.localizedDescription
                return
            }
            output?.setPaused(false)
            state = .recording
        default: break
        }
    }

    func stop() async {
        guard state == .recording || state == .paused else { return }
        state = .finishing
        meterTask?.cancel()
        meterTask = nil
        microphone?.stop()
        microphone = nil
        if let stream {
            do { try await stream.stopCapture() } catch { failure = error.localizedDescription }
        }
        if let output {
            do { try await output.finish() } catch { failure = error.localizedDescription }
        }
        stream = nil
        output = nil
        level = 0
        completedURL = destination
        state = .idle
        Self.activeRecorder = nil
    }

    /// Clears the UI, never deletes the user's saved recording.
    func dismissRecording() { completedURL = nil }

    private func updateMeter() {
        guard state == .recording else { return }
        if let microphone {
            microphone.updateMeters()
            elapsed = microphone.currentTime
            level = min(1, pow(10, Double(microphone.averagePower(forChannel: 0)) / 20) * 3)
        } else if let output {
            let snapshot = output.snapshot()
            elapsed = snapshot.duration
            level = snapshot.level
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message =
            error?.localizedDescription ?? RecordingError.couldNotStart.localizedDescription
        Task { @MainActor [weak self] in
            self?.failure = message
            await self?.stop()
        }
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder, successfully flag: Bool
    ) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.destination == url,
                self.state == .recording || self.state == .paused
            else { return }
            if !flag { self.failure = RecordingError.writing.localizedDescription }
            await self.stop()
        }
    }

    enum RecordingError: LocalizedError {
        case microphonePermission, couldNotStart, noDisplay, writing, noAudio
        var errorDescription: String? {
            switch self {
            case .microphonePermission:
                String(localized: "Allow microphone access in System Settings to record a meeting.")
            case .couldNotStart: String(localized: "The microphone recording could not start.")
            case .noDisplay: String(localized: "No display is available for capturing call audio.")
            case .writing:
                String(localized: "Audio could not be saved. Check the available disk space.")
            case .noAudio: String(localized: "No audio was received from the call.")
            }
        }
    }
}

/// ScreenCaptureKit callbacks run off the main actor. The lock serializes lifecycle
/// changes with sample writing; no audio buffer is sent to a UI task.
private final class MeetingCallOutput: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    let queue = DispatchQueue(label: "voxol.meeting.audio", qos: .userInitiated)
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let system: AVAssetWriterInput
    private let mic: AVAssetWriterInput
    private let onFailure: @Sendable (String) -> Void
    private var paused = false
    private var resumePending = false
    private var finished = false
    private var started = false
    private var firstTime = CMTime.zero
    private var lastEnd = CMTime.zero
    private var offset = CMTime.zero
    private var power = 0.0
    private var failureSent = false

    init(url: URL, onFailure: @escaping @Sendable (String) -> Void) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        system = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000,
            ])
        mic = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000,
            ])
        self.onFailure = onFailure
        super.init()
        for input in [system, mic] {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw MeetingRecorder.RecordingError.writing }
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw writer.error ?? MeetingRecorder.RecordingError.writing
        }
    }

    func setPaused(_ value: Bool) {
        lock.withLock {
            if paused && !value { resumePending = true }
            paused = value
        }
    }

    func snapshot() -> (duration: Double, level: Double) {
        lock.withLock { (started ? max(0, (lastEnd - firstTime).seconds) : 0, power) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure(error.localizedDescription)
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        append(buffer, type: type)
    }

    func append(_ buffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard type == .audio || type == .microphone, buffer.isValid,
            CMSampleBufferDataIsReady(buffer)
        else { return }
        lock.withLock {
            guard !finished, !paused, !failureSent else { return }
            let time = buffer.presentationTimeStamp
            guard time.isValid else { return }
            if resumePending {
                offset = time - lastEnd
                resumePending = false
            }
            let adjusted = time - offset
            if !started {
                firstTime = adjusted
                lastEnd = adjusted
                writer.startSession(atSourceTime: adjusted)
                started = true
            }
            // A later-arriving buffer from the other stream may precede the session boundary.
            guard adjusted >= firstTime else { return }
            var count = 0
            guard
                CMSampleBufferGetSampleTimingInfoArray(
                    buffer, entryCount: 0, arrayToFill: nil,
                    entriesNeededOut: &count) == noErr
            else { return }
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
            guard
                CMSampleBufferGetSampleTimingInfoArray(
                    buffer, entryCount: count, arrayToFill: &timing,
                    entriesNeededOut: &count) == noErr
            else { return }
            for index in timing.indices {
                timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - offset
                if timing[index].decodeTimeStamp.isValid {
                    timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - offset
                }
            }
            var copy: CMSampleBuffer?
            guard
                CMSampleBufferCreateCopyWithNewTiming(
                    allocator: kCFAllocatorDefault,
                    sampleBuffer: buffer, sampleTimingEntryCount: count, sampleTimingArray: &timing,
                    sampleBufferOut: &copy) == noErr, let copy
            else { return }
            let input = type == .audio ? system : mic
            guard input.isReadyForMoreMediaData, input.append(copy) else {
                failureSent = true
                onFailure(
                    writer.error?.localizedDescription
                        ?? MeetingRecorder.RecordingError.writing.localizedDescription)
                return
            }
            let duration = buffer.duration.isValid ? buffer.duration : .zero
            lastEnd = max(lastEnd, adjusted + duration)
            if let data = buffer.dataBuffer, let format = buffer.formatDescription,
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
                asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                asbd.pointee.mBitsPerChannel == 32
            {
                var bytes = [Float](repeating: 0, count: min(512, data.dataLength / 4))
                let length = bytes.count * 4
                guard length > 0 else { return }
                let status = bytes.withUnsafeMutableBytes {
                    guard let address = $0.baseAddress else { return OSStatus(-1) }
                    return CMBlockBufferCopyDataBytes(
                        data, atOffset: 0, dataLength: length, destination: address)
                }
                if status == noErr, !bytes.isEmpty {
                    power = min(
                        1, sqrt(bytes.reduce(0) { $0 + Double($1 * $1) } / Double(bytes.count)) * 3)
                }
            }
        }
    }

    func finish() async throws {
        let hasAudio = lock.withLock {
            finished = true
            if started {
                system.markAsFinished()
                mic.markAsFinished()
            }
            return started
        }
        guard hasAudio else {
            writer.cancelWriting()
            throw MeetingRecorder.RecordingError.noAudio
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? MeetingRecorder.RecordingError.writing
        }
    }
}
