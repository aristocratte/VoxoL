@preconcurrency import AVFoundation
import Foundation
import Synchronization

#if canImport(EndpointingKit)
    import EndpointingKit
#endif

/// A content-free snapshot of an active capture.
public struct AudioCaptureStatus: Equatable, Sendable {
    /// Samples safely retained in the bounded ring buffer.
    public let retainedSampleCount: Int
    /// Samples discarded after the bounded buffer reached capacity.
    public let droppedSampleCount: Int
    /// Whether deterministic endpointing observed speech-like frames.
    public let speechDetected: Bool
    /// Root-mean-square level measured in the latest converted audio buffer.
    public let currentRootMeanSquare: Float
    /// Highest root-mean-square level measured during this capture.
    public let maximumRootMeanSquare: Float

    /// Creates a content-free capture snapshot.
    public init(
        retainedSampleCount: Int,
        droppedSampleCount: Int,
        speechDetected: Bool,
        currentRootMeanSquare: Float = 0,
        maximumRootMeanSquare: Float = 0
    ) {
        self.retainedSampleCount = retainedSampleCount
        self.droppedSampleCount = droppedSampleCount
        self.speechDetected = speechDetected
        self.currentRootMeanSquare = currentRootMeanSquare
        self.maximumRootMeanSquare = maximumRootMeanSquare
    }

    /// Duration represented by retained 16 kHz samples.
    public var durationSeconds: TimeInterval {
        Double(retainedSampleCount) / 16_000
    }
}

/// Mono Float32 audio returned after capture stops.
public struct CapturedAudio: Sendable {
    /// Normalized mono samples in chronological order.
    public let samples: [Float]
    /// Sample rate for `samples`.
    public let sampleRate: Double
    /// Whether endpointing observed speech during this capture.
    public let speechDetected: Bool
    /// Samples omitted because the bounded capture buffer was full.
    public let droppedSampleCount: Int
    /// Highest root-mean-square level measured during this capture.
    public let maximumRootMeanSquare: Float

    /// Creates a completed capture result.
    public init(
        samples: [Float],
        sampleRate: Double = 16_000,
        speechDetected: Bool,
        droppedSampleCount: Int,
        maximumRootMeanSquare: Float = 0
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.speechDetected = speechDetected
        self.droppedSampleCount = droppedSampleCount
        self.maximumRootMeanSquare = maximumRootMeanSquare
    }

    /// Duration represented by the returned samples.
    public var durationSeconds: TimeInterval {
        Double(samples.count) / sampleRate
    }
}

/// Failures that prevent microphone capture from starting.
public enum AudioCaptureError: Error, Equatable, LocalizedError, Sendable {
    case inputUnavailable
    case converterUnavailable
    case alreadyRecording

    /// A user-readable reason capture could not start.
    public var errorDescription: String? {
        switch self {
        case .inputUnavailable:
            "No microphone input is available."
        case .converterUnavailable:
            "The microphone format cannot be converted to 16 kHz mono audio."
        case .alreadyRecording:
            "An audio capture is already running."
        }
    }
}

/// Main-thread capture control with a bounded, preallocated audio callback path.
@MainActor
public final class AudioCaptureSession {
    /// Sample rate produced by every successful capture.
    public nonisolated static let sampleRate: Double = 16_000

    private let maximumDurationSeconds: Int
    private var engine: AVAudioEngine?
    private var processor: AudioTapProcessor?

    /// The input the next capture should use, as a CoreAudio device UID.
    ///
    /// `nil` follows whatever macOS has as its default input, which is what most people want and
    /// what VoxoL did before this existed. A UID that is no longer connected also falls back to
    /// the default rather than failing to record.
    public var preferredInputUID: String?

    /// The device the last successful `start()` actually recorded from, so the interface can say
    /// so instead of guessing.
    public private(set) var activeInputUID: String?

    /// Creates a capture session with bounded in-memory retention.
    public init(maximumDurationSeconds: Int = 180) {
        self.maximumDurationSeconds = maximumDurationSeconds
    }

    /// Whether the underlying audio engine is currently running.
    public var isRecording: Bool {
        engine?.isRunning == true
    }

    /// Latest content-free capture counters, safe to poll from the UI.
    public var status: AudioCaptureStatus {
        processor?.status
            ?? AudioCaptureStatus(
                retainedSampleCount: 0,
                droppedSampleCount: 0,
                speechDetected: false,
                currentRootMeanSquare: 0,
                maximumRootMeanSquare: 0
            )
    }

    /// Starts microphone capture and conversion to mono 16 kHz Float32 audio.
    public func start() throws {
        guard engine == nil else {
            throw AudioCaptureError.alreadyRecording
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // The device has to be set before the format is read: the engine reports the format of
        // whichever device it is bound to, and binding after the tap is installed would leave the
        // converter configured for the wrong input.
        activeInputUID = nil
        if let preferredInputUID,
            let deviceID = AudioInputDevices.deviceID(forUID: preferredInputUID)
        {
            if (try? inputNode.auAudioUnit.setDeviceID(deviceID)) != nil {
                activeInputUID = preferredInputUID
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.inputUnavailable
        }

        let ringCapacity = maximumDurationSeconds * Int(Self.sampleRate)
        guard
            let processor = AudioTapProcessor(
                inputFormat: inputFormat,
                ringCapacity: ringCapacity
            )
        else {
            throw AudioCaptureError.converterUnavailable
        }

        let tapBlock = Self.makeTapBlock(processor: processor)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat,
            block: tapBlock
        )

        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.processor = processor
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    /// Stops capture and returns all retained samples, or `nil` when idle.
    public func stop() -> CapturedAudio? {
        guard let engine, let processor else {
            return nil
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.processor = nil

        let status = processor.status
        return CapturedAudio(
            samples: processor.drainSamples(),
            speechDetected: status.speechDetected,
            droppedSampleCount: status.droppedSampleCount,
            maximumRootMeanSquare: status.maximumRootMeanSquare
        )
    }

    /// Returns a non-consuming snapshot for partial transcription.
    public func snapshotSamples(maximumCount: Int) -> [Float] {
        processor?.snapshotSamples(maximumCount: maximumCount) ?? []
    }

    private nonisolated static func makeTapBlock(
        processor: AudioTapProcessor
    ) -> AVAudioNodeTapBlock {
        { [processor] buffer, _ in
            processor.consume(buffer)
        }
    }
}

private final class AudioTapProcessor: @unchecked Sendable {
    private static let frameSampleCount = 320

    private let converter: AVAudioConverter
    private let conversionBuffer: AVAudioPCMBuffer
    private let ringBuffer: AudioRingBuffer
    private let retainedSampleCount = Atomic<Int>(0)
    private let droppedSampleCount = Atomic<Int>(0)
    private let detectedSpeech = Atomic<Bool>(false)
    private let currentRootMeanSquareBits = Atomic<UInt32>(0)
    private let maximumRootMeanSquareBits = Atomic<UInt32>(0)

    private var endpointDetector = DeterministicEndpointDetector()
    private var endpointFrame = [Float](repeating: 0, count: frameSampleCount)
    private var endpointFrameCount = 0
    private var dcEstimate: Float = 0
    private var converterInputBuffer: AVAudioPCMBuffer?
    private var providedConverterInput = false

    init?(inputFormat: AVAudioFormat, ringCapacity: Int) {
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioCaptureSession.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat),
            let conversionBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: 4_096
            )
        else {
            return nil
        }

        self.converter = converter
        self.conversionBuffer = conversionBuffer
        ringBuffer = AudioRingBuffer(capacity: ringCapacity)
    }

    var status: AudioCaptureStatus {
        AudioCaptureStatus(
            retainedSampleCount: retainedSampleCount.load(ordering: .relaxed),
            droppedSampleCount: droppedSampleCount.load(ordering: .relaxed),
            speechDetected: detectedSpeech.load(ordering: .relaxed),
            currentRootMeanSquare: Float(
                bitPattern: currentRootMeanSquareBits.load(ordering: .relaxed)
            ),
            maximumRootMeanSquare: Float(
                bitPattern: maximumRootMeanSquareBits.load(ordering: .relaxed)
            )
        )
    }

    func consume(_ inputBuffer: AVAudioPCMBuffer) {
        conversionBuffer.frameLength = 0
        converterInputBuffer = inputBuffer
        providedConverterInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(
            to: conversionBuffer,
            error: &conversionError
        ) { [self] _, inputStatus in
            guard !providedConverterInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            providedConverterInput = true
            inputStatus.pointee = .haveData
            return converterInputBuffer
        }
        converterInputBuffer = nil

        guard
            conversionError == nil,
            conversionStatus != .error,
            conversionBuffer.frameLength > 0,
            let channel = conversionBuffer.floatChannelData?[0]
        else {
            return
        }

        let count = Int(conversionBuffer.frameLength)
        var squareSum: Float = 0
        for index in 0..<count {
            let input = channel[index]
            dcEstimate = dcEstimate * 0.995 + input * 0.005
            let sample = min(0.98, max(-0.98, (input - dcEstimate) * 1.15))
            channel[index] = sample
            squareSum += sample * sample
        }

        let rootMeanSquare = sqrt(squareSum / Float(count))
        currentRootMeanSquareBits.store(rootMeanSquare.bitPattern, ordering: .relaxed)
        let previousMaximum = Float(
            bitPattern: maximumRootMeanSquareBits.load(ordering: .relaxed)
        )
        if rootMeanSquare > previousMaximum {
            maximumRootMeanSquareBits.store(rootMeanSquare.bitPattern, ordering: .relaxed)
        }

        let samples = UnsafeBufferPointer(start: channel, count: count)
        let written = ringBuffer.write(samples)
        _ = retainedSampleCount.wrappingAdd(written, ordering: .relaxed)
        if written < count {
            _ = droppedSampleCount.wrappingAdd(count - written, ordering: .relaxed)
        }

        for sample in samples {
            endpointFrame[endpointFrameCount] = sample
            endpointFrameCount += 1
            guard endpointFrameCount == Self.frameSampleCount else {
                continue
            }

            let event = endpointFrame.withUnsafeBufferPointer {
                endpointDetector.process($0)
            }
            if event == .speechStarted || event == .speechContinued {
                detectedSpeech.store(true, ordering: .relaxed)
            }
            endpointFrameCount = 0
        }
    }

    func drainSamples() -> [Float] {
        ringBuffer.readAll()
    }

    func snapshotSamples(maximumCount: Int) -> [Float] {
        ringBuffer.snapshotLatest(maximumCount: maximumCount)
    }
}

// MARK: - Input devices

/// One audio input macOS can record from.
public struct AudioInputDevice: Identifiable, Equatable, Sendable {
    /// The CoreAudio device UID, stable across reboots and safe to persist.
    public let id: String
    /// The name macOS shows for the device.
    public let name: String
    /// Whether this is the system's current default input.
    public let isDefault: Bool

    /// Creates a description of one input device.
    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// Enumerates the machine's audio inputs.
///
/// Read on demand rather than cached: a headset can be plugged in at any moment, and a stale list
/// would offer a device that is no longer there.
public enum AudioInputDevices {
    /// Every device that currently exposes at least one input channel, default first.
    public static func available() -> [AudioInputDevice] {
        let defaultUID = uid(for: defaultInputDeviceID())
        let devices = allDeviceIDs().compactMap { deviceID -> AudioInputDevice? in
            guard inputChannelCount(of: deviceID) > 0,
                let uid = uid(for: deviceID),
                let name = name(of: deviceID)
            else {
                return nil
            }
            return AudioInputDevice(id: uid, name: name, isDefault: uid == defaultUID)
        }
        return devices.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Resolves a stored UID back to the live device, or nil when it is no longer connected.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
            ) == noErr
        else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
            ) == noErr
        else {
            return []
        }
        return deviceIDs
    }

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
            size > 0
        else {
            return 0
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func uid(for deviceID: AudioDeviceID) -> String? {
        string(from: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func name(of deviceID: AudioDeviceID) -> String? {
        string(from: deviceID, selector: kAudioObjectPropertyName)
    }

    private static func string(
        from deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
