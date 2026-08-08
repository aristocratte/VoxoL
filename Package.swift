// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VoxoL",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AppCoreKit", targets: ["AppCoreKit"]),
        .library(name: "ASRBenchmarkKit", targets: ["ASRBenchmarkKit"]),
        .library(name: "AudioCaptureKit", targets: ["AudioCaptureKit"]),
        .library(name: "ContextKit", targets: ["ContextKit"]),
        .library(name: "DatasetKit", targets: ["DatasetKit"]),
        .library(name: "FidelityKit", targets: ["FidelityKit"]),
        .library(name: "EndpointingKit", targets: ["EndpointingKit"]),
        .library(name: "InjectionKit", targets: ["InjectionKit"]),
        .library(name: "ModelManagerKit", targets: ["ModelManagerKit"]),
        .library(name: "ObservabilityKit", targets: ["ObservabilityKit"]),
        .library(name: "ParakeetCore", targets: ["ParakeetCore"]),
        .library(name: "PersonalizationKit", targets: ["PersonalizationKit"]),
        .library(name: "QwenPolisher", targets: ["QwenPolisher"]),
        .library(name: "TextProcessingKit", targets: ["TextProcessingKit"]),
        .executable(name: "voxol-benchmark", targets: ["BenchmarkCLI"]),
        .executable(name: "voxol-asr-smoke", targets: ["ASRSmokeCLI"]),
        .executable(name: "voxol-polisher-smoke", targets: ["PolisherSmokeCLI"]),
        .executable(name: "voxol-dataset-builder", targets: ["DatasetBuilderCLI"]),
        .executable(name: "voxol-reference-eval", targets: ["ReferenceEvalCLI"]),
        .executable(name: "voxol-parakeet-parity", targets: ["ParakeetParityCLI"]),
        .executable(name: "voxol-asr-benchmark", targets: ["ASRBenchmarkCLI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            exact: "2.31.3"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            exact: "0.31.6"
        ),
    ],
    targets: [
        .target(
            name: "AppCoreKit",
            path: "Packages/AppCoreKit/Sources"
        ),
        .target(
            name: "ASRBenchmarkKit",
            path: "Packages/ASRBenchmarkKit/Sources"
        ),
        .target(
            name: "EndpointingKit",
            path: "Packages/EndpointingKit/Sources"
        ),
        .target(
            name: "AudioCaptureKit",
            dependencies: ["EndpointingKit"],
            path: "Packages/AudioCaptureKit/Sources"
        ),
        .target(
            name: "ContextKit",
            path: "Packages/ContextKit/Sources"
        ),
        .target(
            name: "PersonalizationKit",
            path: "Packages/PersonalizationKit/Sources",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "TextProcessingKit",
            dependencies: ["PersonalizationKit"],
            path: "Packages/TextProcessingKit/Sources"
        ),
        .target(
            name: "FidelityKit",
            dependencies: ["TextProcessingKit"],
            path: "Packages/FidelityKit/Sources"
        ),
        .target(
            name: "DatasetKit",
            dependencies: ["FidelityKit", "PersonalizationKit", "TextProcessingKit"],
            path: "Packages/DatasetKit/Sources"
        ),
        .target(
            name: "QwenPolisher",
            dependencies: [
                "TextProcessingKit",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Packages/QwenPolisher/Sources"
        ),
        .target(
            name: "InjectionKit",
            path: "Packages/InjectionKit/Sources"
        ),
        .target(
            name: "ModelManagerKit",
            path: "Packages/ModelManagerKit/Sources"
        ),
        .target(
            name: "ObservabilityKit",
            path: "Packages/ObservabilityKit/Sources"
        ),
        .target(
            name: "ParakeetCore",
            path: "Packages/ParakeetCore/Sources",
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "BenchmarkCLI",
            dependencies: ["ModelManagerKit", "ObservabilityKit"],
            path: "Tools/benchmark-cli/Sources"
        ),
        .executableTarget(
            name: "ASRSmokeCLI",
            dependencies: ["ParakeetCore"],
            path: "Tools/asr-smoke-cli/Sources"
        ),
        .executableTarget(
            name: "PolisherSmokeCLI",
            dependencies: ["FidelityKit", "QwenPolisher", "TextProcessingKit"],
            path: "Tools/polisher-smoke-cli/Sources"
        ),
        .executableTarget(
            name: "DatasetBuilderCLI",
            dependencies: ["DatasetKit", "FidelityKit"],
            path: "Tools/dataset-builder/Sources"
        ),
        .executableTarget(
            name: "ReferenceEvalCLI",
            dependencies: [
                "FidelityKit",
                "ParakeetCore",
                "PersonalizationKit",
                "QwenPolisher",
                "TextProcessingKit",
            ],
            path: "Tools/reference-eval/Sources"
        ),
        .executableTarget(
            name: "ParakeetParityCLI",
            dependencies: ["ParakeetCore"],
            path: "Tools/parakeet-parity-cli/Sources"
        ),
        .executableTarget(
            name: "ASRBenchmarkCLI",
            dependencies: [
                "ASRBenchmarkKit", "AudioCaptureKit", "ParakeetCore",
                // The benchmark measured the recogniser alone: rawText and
                // finalText were the same string on every clip. The product a
                // user runs includes deterministic cleanup and the polisher,
                // so comparing it to a competitor's edited output needs them
                // in the loop.
                "TextProcessingKit", "QwenPolisher", "FidelityKit",
            ],
            path: "Tools/asr-benchmark-cli/Sources"
        ),
        .testTarget(
            name: "AppCoreKitTests",
            dependencies: ["AppCoreKit"],
            path: "Tests/Unit/AppCoreKitTests"
        ),
        .testTarget(
            name: "ASRBenchmarkKitTests",
            dependencies: ["ASRBenchmarkKit"],
            path: "Tests/Unit/ASRBenchmarkKitTests"
        ),
        .testTarget(
            name: "EndpointingKitTests",
            dependencies: ["EndpointingKit"],
            path: "Tests/Unit/EndpointingKitTests"
        ),
        .testTarget(
            name: "AudioCaptureKitTests",
            dependencies: ["AudioCaptureKit"],
            path: "Tests/Unit/AudioCaptureKitTests"
        ),
        .testTarget(
            name: "ContextKitTests",
            dependencies: ["ContextKit"],
            path: "Tests/Unit/ContextKitTests"
        ),
        .testTarget(
            name: "PersonalizationKitTests",
            dependencies: ["PersonalizationKit"],
            path: "Tests/Unit/PersonalizationKitTests"
        ),
        .testTarget(
            name: "TextProcessingKitTests",
            dependencies: ["TextProcessingKit"],
            path: "Tests/Unit/TextProcessingKitTests"
        ),
        .testTarget(
            name: "FidelityKitTests",
            dependencies: ["FidelityKit", "TextProcessingKit"],
            path: "Tests/Unit/FidelityKitTests"
        ),
        .testTarget(
            name: "DatasetKitTests",
            dependencies: ["DatasetKit"],
            path: "Tests/Unit/DatasetKitTests"
        ),
        .testTarget(
            name: "QwenPolisherTests",
            dependencies: ["QwenPolisher", "TextProcessingKit"],
            path: "Tests/Unit/QwenPolisherTests"
        ),
        .testTarget(
            name: "InjectionKitTests",
            dependencies: ["InjectionKit"],
            path: "Tests/Unit/InjectionKitTests"
        ),
        .testTarget(
            name: "ModelManagerKitTests",
            dependencies: ["ModelManagerKit"],
            path: "Tests/Unit/ModelManagerKitTests"
        ),
        .testTarget(
            name: "ObservabilityKitTests",
            dependencies: ["ObservabilityKit"],
            path: "Tests/Unit/ObservabilityKitTests"
        ),
        .testTarget(
            name: "ParakeetCoreTests",
            dependencies: ["ParakeetCore"],
            path: "Tests/Unit/ParakeetCoreTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
