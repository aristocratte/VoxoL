// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
import Foundation

/// One ranked decoder alternative captured only by the offline parity harness.
public struct ParakeetLogitCandidate: Codable, Equatable, Sendable {
    public let index: Int
    public let logit: Float
}

/// One TDT joint decision captured only by the offline parity harness.
public struct ParakeetParityDecision: Codable, Equatable, Sendable {
    public let frameIndex: Int
    public let selectedTokenID: Int
    public let selectedDurationIndex: Int
    public let selectedDurationFrames: Int
    public let emittedToken: Bool
    public let tokenTopCandidates: [ParakeetLogitCandidate]
    public let durationTopCandidates: [ParakeetLogitCandidate]
}

/// Dense tensor copied out of a parity run before Core ML recycles its buffers.
public struct ParakeetParityTensor: Sendable {
    public let shape: [Int]
    public let values: [Float]
}

/// Stage-level data used to compare the official source model and the Core ML port.
public struct ParakeetParitySnapshot: Sendable {
    public let sampleRate: Int
    public let audioSamples: [Float]
    public let powerSpectrogram: ParakeetParityTensor
    public let unnormalizedLogMel: ParakeetParityTensor
    public let inputFeatures: ParakeetParityTensor
    public let attentionMask: [Int32]
    public let encoderHidden: ParakeetParityTensor
    public let encoderMask: [Int32]
    public let transcript: String
    public let tokenIDs: [Int]
    public let frameIndices: [Int]
    public let durations: [Int]
    public let decisions: [ParakeetParityDecision]
}
