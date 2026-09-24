@preconcurrency import AVFoundation
import Darwin
import Foundation

/// Records a few seconds headless and prints what the capture path delivered.
///
/// The voice-processing regression was invisible from code: everything
/// compiled, the engine started, the tap fired — and the samples were
/// silence. The only way to see that class of failure is to measure the
/// samples themselves, and asking a human to dictate for every experiment
/// makes the loop hours long. This probe runs the exact production capture
/// (same session, same converter, same processing switch), for either mode,
/// and prints the numbers that distinguish a live room from a dead path: a
/// working microphone in a quiet room floors around 1e-4..1e-3 RMS; the
/// full-duplex silence bug floors at zero.
enum CaptureProbeRunner {
    static let argument = "--capture-probe"

    static func runAndExit(arguments: [String]) async -> Never {
        let code = await run(arguments: arguments)
        fflush(stdout)
        Darwin.exit(code)
    }

    @MainActor
    private static func run(arguments: [String]) async -> Int32 {
        guard let index = arguments.firstIndex(of: argument) else { return 2 }
        let seconds =
            arguments.indices.contains(index + 1)
            ? (Double(arguments[index + 1]) ?? 3) : 3
        let mode =
            arguments.indices.contains(index + 2)
            ? (VoiceProcessingMode(rawValue: arguments[index + 2]) ?? .disabled)
            : .disabled

        let outputIndex = arguments.firstIndex(of: "--output-directory")
        let outputDirectory: URL?
        if let outputIndex {
            guard arguments.indices.contains(outputIndex + 1), seconds > 0, seconds <= 15 else {
                print("probe: une comparaison native doit durer entre 0 et 15 secondes")
                return 2
            }
            let directory = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                print("probe: le dossier de sortie existe déjà ; aucune capture démarrée")
                return 2
            }
            outputDirectory = directory
        } else {
            outputDirectory = nil
        }
        let session = AudioCaptureSession(
            maximumDurationSeconds: outputDirectory == nil ? 180 : 15,
            retainsNativeAudio: outputDirectory != nil)
        session.preferredInputUID = UserDefaults.standard.string(forKey: "voxol.inputDeviceUID")
        session.voiceProcessingMode = mode
        session.allowsExperimentalVoiceProcessing = true
        do {
            try session.start()
        } catch {
            print("probe: démarrage impossible — \(error.localizedDescription)")
            return 1
        }
        try? await Task.sleep(for: .seconds(seconds))
        guard let audio = session.stop() else {
            print("probe: aucune capture")
            return 1
        }
        var floorSum: Float = 0
        var peak: Float = 0
        let frame = 320
        var frames = 0
        var index2 = 0
        while index2 + frame <= audio.samples.count {
            var sum: Float = 0
            for sample in audio.samples[index2..<(index2 + frame)] {
                sum += sample * sample
            }
            let rms = (sum / Float(frame)).squareRoot()
            floorSum += rms
            peak = max(peak, rms)
            frames += 1
            index2 += frame
        }
        let mean = frames > 0 ? floorSum / Float(frames) : 0
        if let outputDirectory {
            guard let native = audio.nativeAudio, !native.channels.isEmpty else {
                print("probe: la capture native n'est pas disponible")
                return 1
            }
            do {
                try FileManager.default.createDirectory(
                    at: outputDirectory, withIntermediateDirectories: true)
                try writeWAV(
                    channels: native.channels, rate: native.sampleRate,
                    to: outputDirectory.appendingPathComponent("native.wav"))
                try writeWAV(
                    channels: [audio.samples], rate: audio.sampleRate,
                    to: outputDirectory.appendingPathComponent("asr.wav"))
                let metadata: [String: Any] = [
                    "schemaVersion": 1,
                    "nativeSampleRate": native.sampleRate,
                    "nativeChannels": native.channels.count,
                    "nativeFrames": native.channels.first?.count ?? 0,
                    "asrSampleRate": audio.sampleRate,
                    "asrFrames": audio.samples.count,
                    "nativeDroppedFrames": native.droppedFrameCount,
                    "asrDroppedSamples": audio.droppedSampleCount,
                    "deviceUID": session.activeInputUID ?? "unknown",
                    "voiceProcessingActive": session.voiceProcessingActive,
                    "conversionQuality": AudioCaptureSession.sampleRateConverterQuality,
                    "pcmBitDepth": 32,
                    "encoding": "IEEE Float32 WAV, no lossy compression",
                    "purpose":
                        "Same-take native input versus production ASR signal, not a quality reference",
                ]
                try JSONSerialization.data(
                    withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]
                )
                .write(to: outputDirectory.appendingPathComponent("capture.json"))
            } catch {
                print("probe: sauvegarde impossible — \(error.localizedDescription)")
                return 1
            }
        }
        print(
            "probe mode=\(mode.rawValue) vp_actif=\(session.voiceProcessingActive) "
                + "echantillons=\(audio.samples.count) "
                + String(format: "rms_moyen=%.6f rms_pic=%.6f", mean, peak)
                + " parole=\(audio.speechDetected)"
        )
        return 0
    }

    private static func writeWAV(channels: [[Float]], rate: Double, to url: URL) throws {
        let count = channels.first?.count ?? 0
        guard count > 0, channels.allSatisfy({ $0.count == count }),
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate,
                channels: AVAudioChannelCount(channels.count), interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
            let bufferChannels = buffer.floatChannelData
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(count)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                bufferChannels[index].update(from: base, count: count)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
