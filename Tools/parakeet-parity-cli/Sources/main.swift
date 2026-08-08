import CryptoKit
import Foundation
import ParakeetCore

@main
struct ParakeetParityCLI {
    static func main() throws {
        let arguments = try Arguments(CommandLine.arguments.dropFirst())
        let outputURL = URL(fileURLWithPath: arguments.outputPath, isDirectory: true)
        try prepareEmptyDirectory(outputURL)

        let transcriber = try ParakeetTranscriber(
            modelsRoot: URL(
                fileURLWithPath: arguments.modelRoot,
                isDirectory: true
            ),
            computeUnits: arguments.computeUnits,
            retryConfiguration: nil
        )
        let audioURL = URL(fileURLWithPath: arguments.audioPath)
        let snapshot = try transcriber.paritySnapshot(
            audioURL: audioURL,
            sourceCompatibleFeatures: arguments.sourceCompatibleFeatures
        )

        let audioFile = try write(
            floatValues: snapshot.audioSamples,
            named: "audio_samples.f32le",
            under: outputURL
        )
        let powerFile = try write(
            floatValues: snapshot.powerSpectrogram.values,
            named: "power_spectrogram.f32le",
            under: outputURL
        )
        let featureFile = try write(
            floatValues: snapshot.inputFeatures.values,
            named: "input_features.f32le",
            under: outputURL
        )
        let unnormalizedFeatureFile = try write(
            floatValues: snapshot.unnormalizedLogMel.values,
            named: "unnormalized_log_mel.f32le",
            under: outputURL
        )
        let attentionMaskFile = try write(
            int32Values: snapshot.attentionMask,
            named: "attention_mask.i32le",
            under: outputURL
        )
        let encoderFile = try write(
            floatValues: snapshot.encoderHidden.values,
            named: "encoder_hidden.f32le",
            under: outputURL
        )
        let encoderMaskFile = try write(
            int32Values: snapshot.encoderMask,
            named: "encoder_mask.i32le",
            under: outputURL
        )

        let metadata = ParityMetadata(
            schemaVersion: 3,
            runtime: "voxol-coreml",
            computeUnits: arguments.computeUnits.rawValue,
            sampleRate: snapshot.sampleRate,
            sampleCount: snapshot.audioSamples.count,
            audioSHA256: try digest(Data(contentsOf: audioURL)),
            tensors: [
                TensorMetadata(
                    name: "audio_samples",
                    shape: [snapshot.audioSamples.count],
                    scalarType: "float32",
                    file: audioFile
                ),
                TensorMetadata(
                    name: "power_spectrogram",
                    shape: snapshot.powerSpectrogram.shape,
                    scalarType: "float32",
                    file: powerFile
                ),
                TensorMetadata(
                    name: "unnormalized_log_mel",
                    shape: snapshot.unnormalizedLogMel.shape,
                    scalarType: "float32",
                    file: unnormalizedFeatureFile
                ),
                TensorMetadata(
                    name: "input_features",
                    shape: snapshot.inputFeatures.shape,
                    scalarType: "float32",
                    file: featureFile
                ),
                TensorMetadata(
                    name: "attention_mask",
                    shape: [1, snapshot.attentionMask.count],
                    scalarType: "int32",
                    file: attentionMaskFile
                ),
                TensorMetadata(
                    name: "encoder_hidden",
                    shape: snapshot.encoderHidden.shape,
                    scalarType: "float32",
                    file: encoderFile
                ),
                TensorMetadata(
                    name: "encoder_mask",
                    shape: [1, snapshot.encoderMask.count],
                    scalarType: "int32",
                    file: encoderMaskFile
                ),
            ],
            transcript: snapshot.transcript,
            tokenIDs: snapshot.tokenIDs,
            frameIndices: snapshot.frameIndices,
            durations: snapshot.durations,
            decisions: snapshot.decisions
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(metadata).write(
            to: outputURL.appendingPathComponent("snapshot.json"),
            options: .atomic
        )
        print(outputURL.path)
    }
}

private struct Arguments {
    let modelRoot: String
    let outputPath: String
    let computeUnits: ParakeetComputeUnits
    let sourceCompatibleFeatures: Bool
    let audioPath: String

    init(_ rawArguments: ArraySlice<String>) throws {
        let arguments = Array(rawArguments)
        guard
            let modelRoot = Self.value(after: "--model-root", in: arguments),
            let outputPath = Self.value(after: "--output", in: arguments),
            let audioPath = arguments.last,
            !audioPath.hasPrefix("--")
        else {
            throw CLIError.invalidArguments
        }
        let requestedUnits = Self.value(after: "--compute-units", in: arguments) ?? "cpu"
        guard let computeUnits = ParakeetComputeUnits(rawValue: requestedUnits) else {
            throw CLIError.invalidArguments
        }
        self.modelRoot = modelRoot
        self.outputPath = outputPath
        self.computeUnits = computeUnits
        sourceCompatibleFeatures = arguments.contains("--source-compatible-features")
        self.audioPath = audioPath
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard
            let index = arguments.firstIndex(of: flag),
            arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }
}

private struct ParityMetadata: Codable {
    let schemaVersion: Int
    let runtime: String
    let computeUnits: String
    let sampleRate: Int
    let sampleCount: Int
    let audioSHA256: String
    let tensors: [TensorMetadata]
    let transcript: String
    let tokenIDs: [Int]
    let frameIndices: [Int]
    let durations: [Int]
    let decisions: [ParakeetParityDecision]
}

private struct TensorMetadata: Codable {
    let name: String
    let shape: [Int]
    let scalarType: String
    let byteOrder: String
    let file: BinaryFileMetadata

    init(
        name: String,
        shape: [Int],
        scalarType: String,
        file: BinaryFileMetadata
    ) {
        self.name = name
        self.shape = shape
        self.scalarType = scalarType
        byteOrder = "little-endian"
        self.file = file
    }
}

private struct BinaryFileMetadata: Codable {
    let path: String
    let sizeBytes: Int
    let sha256: String
}

private enum CLIError: LocalizedError {
    case invalidArguments
    case outputDirectoryNotEmpty(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            """
            Usage: voxol-parakeet-parity --model-root <directory> --output <directory> \
            [--compute-units ane|gpu|cpu|all] [--source-compatible-features] <audio-file>
            """
        case .outputDirectoryNotEmpty(let path):
            "Parity output directory must be absent or empty: \(path)"
        }
    }
}

private func prepareEmptyDirectory(_ url: URL) throws {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        guard
            isDirectory.boolValue,
            try fileManager.contentsOfDirectory(atPath: url.path).isEmpty
        else {
            throw CLIError.outputDirectoryNotEmpty(url.path)
        }
        return
    }
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
}

private func write(
    floatValues: [Float],
    named name: String,
    under directory: URL
) throws -> BinaryFileMetadata {
    let words = floatValues.map { $0.bitPattern.littleEndian }
    let data = words.withUnsafeBytes { Data($0) }
    return try write(data: data, named: name, under: directory)
}

private func write(
    int32Values: [Int32],
    named name: String,
    under directory: URL
) throws -> BinaryFileMetadata {
    let words = int32Values.map(\.littleEndian)
    let data = words.withUnsafeBytes { Data($0) }
    return try write(data: data, named: name, under: directory)
}

private func write(
    data: Data,
    named name: String,
    under directory: URL
) throws -> BinaryFileMetadata {
    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    return BinaryFileMetadata(
        path: name,
        sizeBytes: data.count,
        sha256: digest(data)
    )
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
