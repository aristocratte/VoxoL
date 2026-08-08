import Foundation
import ParakeetCore

@main
struct ASRSmokeCLI {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 || arguments.count == 5 else {
            throw CLIError.invalidArguments
        }
        guard arguments[0] == "--model-root" else {
            throw CLIError.invalidArguments
        }

        let computeUnits: ParakeetComputeUnits
        let audioPath: String
        if arguments.count == 5 {
            guard
                arguments[2] == "--compute-units",
                let requestedUnits = ParakeetComputeUnits(rawValue: arguments[3])
            else {
                throw CLIError.invalidArguments
            }
            computeUnits = requestedUnits
            audioPath = arguments[4]
        } else {
            computeUnits = .gpu
            audioPath = arguments[2]
        }

        let modelRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let audioURL = URL(fileURLWithPath: audioPath)
        let environment = ProcessInfo.processInfo.environment
        let productionSegmentation = ParakeetSegmentationConfiguration.production
        let maximumSegmentSeconds =
            Double(environment["VOXOL_ASR_SEGMENT_SECONDS"] ?? "")
            ?? productionSegmentation.maximumSegmentDurationSeconds
        let overlapSeconds =
            Double(environment["VOXOL_ASR_OVERLAP_SECONDS"] ?? "")
            ?? productionSegmentation.overlapDurationSeconds
        let segmentationThresholdSeconds =
            Double(environment["VOXOL_ASR_SEGMENTATION_THRESHOLD_SECONDS"] ?? "")
            ?? (environment["VOXOL_ASR_SEGMENT_SECONDS"] == nil
                ? productionSegmentation.segmentationThresholdDurationSeconds
                : maximumSegmentSeconds)
        guard
            maximumSegmentSeconds.isFinite,
            maximumSegmentSeconds > 0,
            overlapSeconds.isFinite,
            overlapSeconds >= 0,
            overlapSeconds < maximumSegmentSeconds,
            segmentationThresholdSeconds.isFinite,
            segmentationThresholdSeconds >= maximumSegmentSeconds
        else {
            throw CLIError.invalidArguments
        }
        let loadStart = ContinuousClock.now
        let retryConfiguration: ParakeetRetryConfiguration? =
            environment["VOXOL_ASR_CONFIDENCE_RETRY"] == "0"
            ? nil : .production
        let transcriber = try ParakeetTranscriber(
            modelsRoot: modelRoot,
            computeUnits: computeUnits,
            segmentation: ParakeetSegmentationConfiguration(
                maximumSegmentDurationSeconds: maximumSegmentSeconds,
                overlapDurationSeconds: overlapSeconds,
                segmentationThresholdDurationSeconds: segmentationThresholdSeconds
            ),
            retryConfiguration: retryConfiguration
        )
        let loadDuration = loadStart.duration(to: .now)
        let iterations = max(
            1,
            Int(ProcessInfo.processInfo.environment["VOXOL_ASR_ITERATIONS"] ?? "1") ?? 1
        )
        var finalResult: Transcription?
        for iteration in 1...iterations {
            let result = try transcriber.transcribe(audioURL: audioURL)
            finalResult = result
            let metrics = String(
                format:
                    "iteration=%d load_ms=%.1f inference_ms=%.1f mel_ms=%.1f encoder_ms=%.1f decoder_ms=%.1f rtfx=%.1f mean_margin=%.3f p10_margin=%.3f min_overlap=%.3f attempts=%d fallback=%d\n",
                iteration,
                loadDuration.milliseconds,
                result.inferenceDurationSeconds * 1_000,
                result.timing.melExtract * 1_000,
                result.timing.encoder * 1_000,
                result.timing.decoderLoop * 1_000,
                result.rtfx,
                result.confidence.meanTokenLogitMargin,
                result.confidence.lowerDecileTokenLogitMargin,
                result.confidence.minimumOverlapTokenAgreement ?? -1,
                result.inferenceAttemptCount,
                result.usedFallbackSegmentation ? 1 : 0
            )
            FileHandle.standardError.write(Data(metrics.utf8))
        }
        print(finalResult?.text ?? "")
    }
}

private enum CLIError: LocalizedError {
    case invalidArguments

    var errorDescription: String? {
        """
        Usage: voxol-asr-smoke --model-root <directory> \
        [--compute-units ane|gpu|cpu|all] <audio-file>

        Optional environment: VOXOL_ASR_SEGMENT_SECONDS, VOXOL_ASR_OVERLAP_SECONDS,
        VOXOL_ASR_SEGMENTATION_THRESHOLD_SECONDS, VOXOL_ASR_CONFIDENCE_RETRY=0
        """
    }
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
