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
        let seconds = arguments.indices.contains(index + 1)
            ? (Double(arguments[index + 1]) ?? 3) : 3
        let mode = arguments.indices.contains(index + 2)
            ? (VoiceProcessingMode(rawValue: arguments[index + 2]) ?? .disabled)
            : .disabled

        let session = AudioCaptureSession()
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
        print(
            "probe mode=\(mode.rawValue) vp_actif=\(session.voiceProcessingActive) "
                + "echantillons=\(audio.samples.count) "
                + String(format: "rms_moyen=%.6f rms_pic=%.6f", mean, peak)
                + " parole=\(audio.speechDetected)"
        )
        return 0
    }
}
