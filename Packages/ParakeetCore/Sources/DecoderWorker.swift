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
    let fusedDecoderJoint: MLModel?

    let inputIds: MLMultiArray
    let hidden: MLMultiArray
    let cell: MLMultiArray
    let candidateHidden: MLMultiArray
    let candidateCell: MLMultiArray
    let encoderFrame: MLMultiArray
    let decoderState: MLMultiArray

    let decoderInputs: FeatureBag
    let jointInputs: FeatureBag
    private lazy var fusedDecoderJointInputs: FeatureBag? = {
        guard fusedDecoderJoint != nil else { return nil }
        return FeatureBag([
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "hidden": MLFeatureValue(multiArray: hidden),
            "cell": MLFeatureValue(multiArray: cell),
            "encoder_frame": MLFeatureValue(multiArray: encoderFrame),
        ])
    }()
    let predictionOptions = MLPredictionOptions()
    let decoderPredictionOptions: MLPredictionOptions
    let jointPredictionOptions: MLPredictionOptions
    private let decoderHiddenBacking: MLMultiArray?
    private let nextHiddenBacking: MLMultiArray?
    private let nextCellBacking: MLMultiArray?
    private let tokenLogitsBacking: MLMultiArray?
    private let durationLogitsBacking: MLMultiArray?
    private let traceDecoderStages =
        ProcessInfo.processInfo.environment["VOXOL_ASR_DECODER_STAGE_TRACE"] == "1"
    private let traceOutputBackings =
        ProcessInfo.processInfo.environment["VOXOL_ASR_DECODER_OUTPUT_BACKINGS_TRACE"] == "1"
    private let useDirectOutputBackings =
        ProcessInfo.processInfo.environment["VOXOL_ASR_DIRECT_OUTPUT_BACKINGS"] == "1"
    private var didTraceDecoderOutputBackings = false
    private var didTraceJointOutputBackings = false

    let decoderHiddenLayers: Int
    let decoderHiddenSize: Int

    init(
        decoder: MLModel,
        joint: MLModel,
        fusedDecoderJoint: MLModel? = nil,
        decoderHiddenLayers: Int,
        decoderHiddenSize: Int
    ) throws {
        self.decoder = decoder
        self.joint = joint
        self.fusedDecoderJoint = fusedDecoderJoint
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

        self.decoderHiddenBacking = try Self.makeOutputBacking(
            for: decoder, outputName: "decoder_hidden"
        )
        self.nextHiddenBacking = try Self.makeOutputBacking(
            for: decoder, outputName: "next_hidden"
        )
        self.nextCellBacking = try Self.makeOutputBacking(
            for: decoder, outputName: "next_cell"
        )
        self.tokenLogitsBacking = try Self.makeOutputBacking(
            for: joint, outputName: "token_logits"
        )
        self.durationLogitsBacking = try Self.makeOutputBacking(
            for: joint, outputName: "duration_logits"
        )

        let decoderPredictionOptions = MLPredictionOptions()
        if let decoderHiddenBacking, let nextHiddenBacking, let nextCellBacking {
            decoderPredictionOptions.outputBackings = [
                "decoder_hidden": decoderHiddenBacking,
                "next_hidden": nextHiddenBacking,
                "next_cell": nextCellBacking,
            ]
        }
        self.decoderPredictionOptions = decoderPredictionOptions

        let jointPredictionOptions = MLPredictionOptions()
        if let tokenLogitsBacking, let durationLogitsBacking {
            jointPredictionOptions.outputBackings = [
                "token_logits": tokenLogitsBacking,
                "duration_logits": durationLogitsBacking,
            ]
        }
        self.jointPredictionOptions = jointPredictionOptions

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

    var hasFusedDecoderJoint: Bool {
        fusedDecoderJoint != nil
    }

    func runDecoderStep(useOutputBackings: Bool = false) throws -> (
        decoderHidden: MLMultiArray,
        nextHidden: MLMultiArray,
        nextCell: MLMultiArray
    ) {
        if traceDecoderStages {
            return try runDecoderStepTraced(useOutputBackings: useOutputBackings)
        }
        let options = useOutputBackings ? decoderPredictionOptions : predictionOptions
        let out = try decoder.prediction(
            from: decoderInputs, options: options
        )
        if useOutputBackings, useDirectOutputBackings, !traceOutputBackings,
           let dh = decoderHiddenBacking,
           let nh = nextHiddenBacking,
           let nc = nextCellBacking
        {
            return (dh, nh, nc)
        }
        guard let dh = out.featureValue(for: "decoder_hidden")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "decoder_hidden") }
        guard let nh = out.featureValue(for: "next_hidden")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "next_hidden") }
        guard let nc = out.featureValue(for: "next_cell")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "next_cell") }
        if useOutputBackings {
            traceDecoderOutputBackingIdentity(
                decoderHidden: dh, nextHidden: nh, nextCell: nc
            )
        }
        return (dh, nh, nc)
    }

    private func runDecoderStepTraced(useOutputBackings: Bool) throws -> (
        decoderHidden: MLMultiArray,
        nextHidden: MLMultiArray,
        nextCell: MLMultiArray
    ) {
        let clock = ContinuousClock()
        let predictionStart = clock.now
        let options = useOutputBackings ? decoderPredictionOptions : predictionOptions
        let out = try decoder.prediction(
            from: decoderInputs, options: options
        )
        let outputStart = clock.now
        guard let dh = out.featureValue(for: "decoder_hidden")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "decoder_hidden") }
        guard let nh = out.featureValue(for: "next_hidden")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "next_hidden") }
        guard let nc = out.featureValue(for: "next_cell")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "next_cell") }
        if useOutputBackings {
            traceDecoderOutputBackingIdentity(
                decoderHidden: dh, nextHidden: nh, nextCell: nc
            )
        }
        let end = clock.now
        Self.emitStageTrace(
            stage: "decoder",
            predictionMilliseconds: Self.milliseconds(
                predictionStart.duration(to: outputStart)
            ),
            outputMilliseconds: Self.milliseconds(outputStart.duration(to: end))
        )
        return (dh, nh, nc)
    }

    func runJoint(useOutputBackings: Bool = false) throws -> (
        tokenLogits: MLMultiArray,
        durationLogits: MLMultiArray
    ) {
        if traceDecoderStages {
            return try runJointTraced(useOutputBackings: useOutputBackings)
        }
        let options = useOutputBackings ? jointPredictionOptions : predictionOptions
        let out = try joint.prediction(
            from: jointInputs, options: options
        )
        if useOutputBackings, useDirectOutputBackings, !traceOutputBackings,
           let tl = tokenLogitsBacking,
           let dl = durationLogitsBacking
        {
            return (tl, dl)
        }
        guard let tl = out.featureValue(for: "token_logits")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "token_logits") }
        guard let dl = out.featureValue(for: "duration_logits")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "duration_logits") }
        if useOutputBackings {
            traceJointOutputBackingIdentity(tokenLogits: tl, durationLogits: dl)
        }
        return (tl, dl)
    }

    private func runJointTraced(useOutputBackings: Bool) throws -> (
        tokenLogits: MLMultiArray,
        durationLogits: MLMultiArray
    ) {
        let clock = ContinuousClock()
        let predictionStart = clock.now
        let options = useOutputBackings ? jointPredictionOptions : predictionOptions
        let out = try joint.prediction(
            from: jointInputs, options: options
        )
        let outputStart = clock.now
        guard let tl = out.featureValue(for: "token_logits")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "token_logits") }
        guard let dl = out.featureValue(for: "duration_logits")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "duration_logits") }
        if useOutputBackings {
            traceJointOutputBackingIdentity(tokenLogits: tl, durationLogits: dl)
        }
        let end = clock.now
        Self.emitStageTrace(
            stage: "joint",
            predictionMilliseconds: Self.milliseconds(
                predictionStart.duration(to: outputStart)
            ),
            outputMilliseconds: Self.milliseconds(outputStart.duration(to: end))
        )
        return (tl, dl)
    }

    func runFusedDecoderJoint() throws -> (
        decoderHidden: MLMultiArray,
        nextHidden: MLMultiArray,
        nextCell: MLMultiArray,
        tokenLogits: MLMultiArray,
        durationLogits: MLMultiArray
    ) {
        guard let fusedDecoderJoint, let fusedDecoderJointInputs else {
            throw ParakeetError.runtimeUnavailable
        }
        let predictionStart = ContinuousClock().now
        let out = try fusedDecoderJoint.prediction(
            from: fusedDecoderJointInputs, options: predictionOptions
        )
        let outputStart = ContinuousClock().now
        guard let dh = out.featureValue(for: "decoder_hidden")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "decoder_hidden") }
        guard let nh = out.featureValue(for: "next_hidden")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "next_hidden") }
        guard let nc = out.featureValue(for: "next_cell")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "next_cell") }
        guard let tl = out.featureValue(for: "token_logits")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "token_logits") }
        guard let dl = out.featureValue(for: "duration_logits")?.multiArrayValue
        else { throw ParakeetError.missingOutput(name: "duration_logits") }
        if traceDecoderStages {
            let end = ContinuousClock().now
            Self.emitStageTrace(
                stage: "fused",
                predictionMilliseconds: Self.milliseconds(
                    predictionStart.duration(to: outputStart)
                ),
                outputMilliseconds: Self.milliseconds(outputStart.duration(to: end))
            )
        }
        return (dh, nh, nc, tl, dl)
    }

    private static func makeOutputBacking(
        for model: MLModel,
        outputName: String
    ) throws -> MLMultiArray {
        guard
            let description = model.modelDescription.outputDescriptionsByName[outputName],
            let constraint = description.multiArrayConstraint
        else {
            throw ParakeetError.missingOutput(name: outputName)
        }
        let backing = try MLMultiArray(
            shape: constraint.shape,
            dataType: constraint.dataType
        )
        guard description.isAllowedValue(MLFeatureValue(multiArray: backing)) else {
            throw ParakeetError.runtimeUnavailable
        }
        return backing
    }

    private func traceDecoderOutputBackingIdentity(
        decoderHidden: MLMultiArray,
        nextHidden: MLMultiArray,
        nextCell: MLMultiArray
    ) {
        guard traceOutputBackings, !didTraceDecoderOutputBackings else { return }
        didTraceDecoderOutputBackings = true
        Self.emitOutputBackingTrace(
            stage: "decoder",
            identities: [
                ("decoder_hidden", decoderHiddenBacking.map { decoderHidden === $0 } ?? false),
                ("next_hidden", nextHiddenBacking.map { nextHidden === $0 } ?? false),
                ("next_cell", nextCellBacking.map { nextCell === $0 } ?? false),
            ]
        )
    }

    private func traceJointOutputBackingIdentity(
        tokenLogits: MLMultiArray,
        durationLogits: MLMultiArray
    ) {
        guard traceOutputBackings, !didTraceJointOutputBackings else { return }
        didTraceJointOutputBackings = true
        Self.emitOutputBackingTrace(
            stage: "joint",
            identities: [
                ("token_logits", tokenLogitsBacking.map { tokenLogits === $0 } ?? false),
                (
                    "duration_logits",
                    durationLogitsBacking.map { durationLogits === $0 } ?? false
                ),
            ]
        )
    }

    private static func emitOutputBackingTrace(
        stage: String,
        identities: [(String, Bool)]
    ) {
        let fields = identities.map { "\($0.0)=\($0.1 ? 1 : 0)" }.joined(separator: " ")
        FileHandle.standardError.write(
            Data("output_backings stage=\(stage) \(fields)\n".utf8)
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }

    private static func emitStageTrace(
        stage: String,
        predictionMilliseconds: Double,
        outputMilliseconds: Double
    ) {
        let line = String(
            format: "%@_stage prediction_ms=%.4f output_ms=%.4f\n",
            stage,
            predictionMilliseconds,
            outputMilliseconds
        )
        FileHandle.standardError.write(Data(line.utf8))
    }
}
