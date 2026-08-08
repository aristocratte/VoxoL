// Adapted for VoxoL from parakeet-coreml-swift commit 75aec2a1c991319657ff4dec5f602c12da6c5012.
// Changes are documented in Packages/ParakeetCore/NOTICE.md.
import CoreML
import Foundation

/// Self-contained decode context: the decoder + joint MLModels (shared
/// between workers, `MLModel.prediction(from:)` is thread-safe) plus a
/// private set of input buffers and pre-built ``FeatureBag``s.
///
/// We instantiate N of these behind ``ModelRunner`` so the pipeline's
/// decode stage can process multiple chunks concurrently without buffer
/// aliasing. With decoder + joint being small CPU-resident models, the
/// dominant cost per step is Core ML's per-prediction dispatch, so
/// running two workers in parallel essentially halves decode wall time
/// on GPU builds where the encoder isn't the bottleneck.
final class DecoderWorker: @unchecked Sendable {
    let decoder: MLModel
    let joint: MLModel

    let inputIds: MLMultiArray
    let hidden: MLMultiArray
    let cell: MLMultiArray
    let candidateHidden: MLMultiArray
    let candidateCell: MLMultiArray
    let encoderFrame: MLMultiArray
    let decoderState: MLMultiArray

    let decoderInputs: FeatureBag
    let jointInputs: FeatureBag
    let predictionOptions = MLPredictionOptions()

    let decoderHiddenLayers: Int
    let decoderHiddenSize: Int

    init(
        decoder: MLModel,
        joint: MLModel,
        decoderHiddenLayers: Int,
        decoderHiddenSize: Int
    ) throws {
        self.decoder = decoder
        self.joint = joint
        self.decoderHiddenLayers = decoderHiddenLayers
        self.decoderHiddenSize = decoderHiddenSize

        self.inputIds = try MLMultiArray(shape: [1, 1], dataType: .int32)
        self.hidden = try MLMultiArray(
            shape: [
                NSNumber(value: decoderHiddenLayers), 1,
                NSNumber(value: decoderHiddenSize),
            ],
            dataType: .float32
        )
        self.cell = try MLMultiArray(
            shape: [
                NSNumber(value: decoderHiddenLayers), 1,
                NSNumber(value: decoderHiddenSize),
            ],
            dataType: .float32
        )
        self.candidateHidden = try MLMultiArray(
            shape: [
                NSNumber(value: decoderHiddenLayers), 1,
                NSNumber(value: decoderHiddenSize),
            ],
            dataType: .float32
        )
        self.candidateCell = try MLMultiArray(
            shape: [
                NSNumber(value: decoderHiddenLayers), 1,
                NSNumber(value: decoderHiddenSize),
            ],
            dataType: .float32
        )
        self.encoderFrame = try MLMultiArray(
            shape: [1, NSNumber(value: decoderHiddenSize)],
            dataType: .float32
        )
        self.decoderState = try MLMultiArray(
            shape: [1, NSNumber(value: decoderHiddenSize)],
            dataType: .float32
        )

        self.decoderInputs = FeatureBag([
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "hidden": MLFeatureValue(multiArray: hidden),
            "cell": MLFeatureValue(multiArray: cell),
        ])
        self.jointInputs = FeatureBag([
            "encoder_frame": MLFeatureValue(multiArray: encoderFrame),
            "decoder_state": MLFeatureValue(multiArray: decoderState),
        ])
    }

    func runDecoderStep() throws -> (
        decoderHidden: MLMultiArray,
        nextHidden: MLMultiArray,
        nextCell: MLMultiArray
    ) {
        let out = try decoder.prediction(
            from: decoderInputs, options: predictionOptions
        )
        guard let dh = out.featureValue(for: "decoder_hidden")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "decoder_hidden") }
        guard let nh = out.featureValue(for: "next_hidden")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "next_hidden") }
        guard let nc = out.featureValue(for: "next_cell")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "next_cell") }
        return (dh, nh, nc)
    }

    func runJoint() throws -> (
        tokenLogits: MLMultiArray,
        durationLogits: MLMultiArray
    ) {
        let out = try joint.prediction(
            from: jointInputs, options: predictionOptions
        )
        guard let tl = out.featureValue(for: "token_logits")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "token_logits") }
        guard let dl = out.featureValue(for: "duration_logits")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "duration_logits") }
        return (tl, dl)
    }
}
