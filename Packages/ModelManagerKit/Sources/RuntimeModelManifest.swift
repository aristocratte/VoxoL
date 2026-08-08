import Foundation

/// The only roles a model may hold in the VoxoL runtime.
public enum RuntimeModelRole: String, Codable, CaseIterable, Sendable {
    /// Converts audio into a raw transcript.
    case asr

    /// Cleans and formats a raw transcript without changing its meaning.
    case polisher
}

/// The native inference engine assigned to a runtime model.
public enum RuntimeModelEngine: String, Codable, Sendable {
    /// Apple's Core ML runtime.
    case coreML = "core_ml"

    /// Apple's MLX runtime.
    case mlx
}

/// The lifecycle state of a converted model artifact.
public enum RuntimeModelArtifactState: String, Codable, Sendable {
    /// No distributable artifact has passed conversion and verification yet.
    case pendingConversion = "pending_conversion"

    /// Every listed file has a verified checksum and has passed its release gates.
    case ready
}

/// A checksum-protected file in a converted runtime artifact.
public struct RuntimeModelArtifactFile: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case path
        case sha256
        case downloadURL = "download_url"
        case sizeBytes = "size_bytes"
    }

    /// The path relative to the artifact root.
    public let path: String

    /// The lowercase hexadecimal SHA-256 digest of the file.
    public let sha256: String

    /// The HTTPS location of the verified runtime file.
    public let downloadURL: String?

    /// The exact download size used for progress and free-space checks.
    public let sizeBytes: Int64?

    /// Creates a checksum-protected artifact file entry.
    public init(
        path: String,
        sha256: String,
        downloadURL: String? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.path = path
        self.sha256 = sha256
        self.downloadURL = downloadURL
        self.sizeBytes = sizeBytes
    }
}

/// The immutable repository that publishes a converted runtime artifact.
public struct RuntimeModelArtifactProvider: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case repository
        case revision
        case sourceURL = "source_url"
    }

    /// The exact Hugging Face repository identifier for the converted files.
    public let repository: String

    /// The immutable 40-character artifact commit.
    public let revision: String

    /// The public page where users can inspect the converted artifact.
    public let sourceURL: String

    /// Creates immutable artifact-provider metadata.
    public init(repository: String, revision: String, sourceURL: String) {
        self.repository = repository
        self.revision = revision
        self.sourceURL = sourceURL
    }
}

/// Metadata for a converted model artifact without embedding the artifact itself.
public struct RuntimeModelArtifact: Codable, Equatable, Sendable {
    /// Whether the artifact is pending conversion or ready for use.
    public let state: RuntimeModelArtifactState

    /// The conversion format, such as `mlpackage` or `mlx-4bit-text-only`.
    public let format: String

    /// The immutable repository that publishes the converted files.
    public let provider: RuntimeModelArtifactProvider?

    /// Every file that belongs to a ready artifact.
    public let files: [RuntimeModelArtifactFile]

    /// Creates converted artifact metadata.
    public init(
        state: RuntimeModelArtifactState,
        format: String,
        provider: RuntimeModelArtifactProvider? = nil,
        files: [RuntimeModelArtifactFile]
    ) {
        self.state = state
        self.format = format
        self.provider = provider
        self.files = files
    }
}

/// One immutable upstream model selection and its local artifact metadata.
public struct RuntimeModel: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case role
        case repository
        case revision
        case license
        case sourceURL = "source_url"
        case engine
        case artifact
    }

    /// The model's exclusive responsibility in the runtime.
    public let role: RuntimeModelRole

    /// The exact Hugging Face repository identifier.
    public let repository: String

    /// The immutable 40-character upstream Git commit.
    public let revision: String

    /// The upstream SPDX-style license identifier.
    public let license: String

    /// The official HTTPS source page.
    public let sourceURL: String

    /// The native engine that will execute the converted artifact.
    public let engine: RuntimeModelEngine

    /// The converted artifact state and checksums.
    public let artifact: RuntimeModelArtifact

    /// Creates a pinned runtime model entry.
    public init(
        role: RuntimeModelRole,
        repository: String,
        revision: String,
        license: String,
        sourceURL: String,
        engine: RuntimeModelEngine,
        artifact: RuntimeModelArtifact
    ) {
        self.role = role
        self.repository = repository
        self.revision = revision
        self.license = license
        self.sourceURL = sourceURL
        self.engine = engine
        self.artifact = artifact
    }
}

/// Failures that prevent a runtime-model manifest from being trusted.
public enum RuntimeModelManifestError: Error, Equatable, Sendable {
    /// The manifest schema is unknown to this build.
    case unsupportedSchemaVersion(Int)

    /// The manifest does not contain exactly two models.
    case invalidModelCount(Int)

    /// A runtime role appears more than once.
    case duplicateRole(RuntimeModelRole)

    /// A role is assigned to a repository that VoxoL does not allow.
    case unauthorizedRepository(role: RuntimeModelRole, repository: String)

    /// A pinned property differs from the allowed value.
    case unexpectedValue(role: RuntimeModelRole, field: String, value: String)

    /// The upstream revision is not an immutable lowercase Git commit.
    case invalidRevision(role: RuntimeModelRole, revision: String)

    /// A ready artifact contains no checksum-protected files.
    case readyArtifactHasNoFiles(RuntimeModelRole)

    /// A ready artifact does not identify its immutable distribution repository.
    case readyArtifactHasNoProvider(RuntimeModelRole)

    /// A pending artifact already lists files and therefore has an ambiguous state.
    case pendingArtifactHasFiles(RuntimeModelRole)

    /// A pending artifact already identifies a distribution repository.
    case pendingArtifactHasProvider(RuntimeModelRole)

    /// A role is assigned to an artifact provider that VoxoL does not allow.
    case unauthorizedArtifactProvider(role: RuntimeModelRole, repository: String)

    /// The artifact-provider revision is not an immutable lowercase Git commit.
    case invalidArtifactRevision(role: RuntimeModelRole, revision: String)

    /// An artifact file path is empty, absolute or contains traversal components.
    case invalidArtifactPath(role: RuntimeModelRole, path: String)

    /// An artifact path appears more than once.
    case duplicateArtifactPath(role: RuntimeModelRole, path: String)

    /// An artifact checksum is not a lowercase SHA-256 digest.
    case invalidSHA256(role: RuntimeModelRole, path: String)

    /// A ready artifact file cannot be downloaded or measured precisely.
    case missingDownloadMetadata(role: RuntimeModelRole, path: String)

    /// A runtime artifact may only be fetched over HTTPS.
    case invalidDownloadURL(role: RuntimeModelRole, path: String)

    /// A runtime artifact file must declare a positive byte size.
    case invalidArtifactSize(role: RuntimeModelRole, path: String)
}

extension RuntimeModelManifestError: CustomStringConvertible {
    /// A content-free diagnostic suitable for developer tooling.
    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported runtime-model manifest schema: \(version)"
        case .invalidModelCount(let count):
            "Runtime-model manifest must contain exactly two models; found \(count)"
        case .duplicateRole(let role):
            "Runtime-model role appears more than once: \(role.rawValue)"
        case .unauthorizedRepository(let role, let repository):
            "Unauthorized repository for \(role.rawValue): \(repository)"
        case .unexpectedValue(let role, let field, let value):
            "Unexpected \(field) for \(role.rawValue): \(value)"
        case .invalidRevision(let role, let revision):
            "Invalid immutable revision for \(role.rawValue): \(revision)"
        case .readyArtifactHasNoFiles(let role):
            "Ready artifact has no files for \(role.rawValue)"
        case .readyArtifactHasNoProvider(let role):
            "Ready artifact has no provider for \(role.rawValue)"
        case .pendingArtifactHasFiles(let role):
            "Pending artifact unexpectedly lists files for \(role.rawValue)"
        case .pendingArtifactHasProvider(let role):
            "Pending artifact unexpectedly identifies a provider for \(role.rawValue)"
        case .unauthorizedArtifactProvider(let role, let repository):
            "Unauthorized artifact provider for \(role.rawValue): \(repository)"
        case .invalidArtifactRevision(let role, let revision):
            "Invalid artifact revision for \(role.rawValue): \(revision)"
        case .invalidArtifactPath(let role, let path):
            "Invalid artifact path for \(role.rawValue): \(path)"
        case .duplicateArtifactPath(let role, let path):
            "Duplicate artifact path for \(role.rawValue): \(path)"
        case .invalidSHA256(let role, let path):
            "Invalid SHA-256 for \(role.rawValue) artifact: \(path)"
        case .missingDownloadMetadata(let role, let path):
            "Ready artifact is missing download metadata for \(role.rawValue): \(path)"
        case .invalidDownloadURL(let role, let path):
            "Ready artifact has an invalid download URL for \(role.rawValue): \(path)"
        case .invalidArtifactSize(let role, let path):
            "Ready artifact has an invalid size for \(role.rawValue): \(path)"
        }
    }
}

/// The complete, locally verifiable contract for VoxoL's two runtime models.
public struct RuntimeModelManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case models
    }

    /// The only schema version understood by this build.
    public let schemaVersion: Int

    /// The two pinned model entries.
    public let models: [RuntimeModel]

    /// Creates a runtime-model manifest.
    public init(schemaVersion: Int, models: [RuntimeModel]) {
        self.schemaVersion = schemaVersion
        self.models = models
    }

    /// Decodes and validates a manifest without performing network access.
    public static func decodeAndValidate(_ data: Data) throws -> RuntimeModelManifest {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(RuntimeModelManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    /// Loads and validates a manifest from a local file URL.
    public static func loadAndValidate(from url: URL) throws -> RuntimeModelManifest {
        try decodeAndValidate(Data(contentsOf: url))
    }

    /// Enforces the exact model, engine, license, revision and artifact invariants.
    public func validate() throws {
        guard schemaVersion == 2 else {
            throw RuntimeModelManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        guard models.count == RuntimeModelRole.allCases.count else {
            throw RuntimeModelManifestError.invalidModelCount(models.count)
        }

        var seenRoles = Set<RuntimeModelRole>()
        for model in models {
            guard seenRoles.insert(model.role).inserted else {
                throw RuntimeModelManifestError.duplicateRole(model.role)
            }
            try validate(model)
        }
    }
}

private extension RuntimeModelManifest {
    struct AllowedModel {
        let repository: String
        let license: String
        let sourceURL: String
        let engine: RuntimeModelEngine
        let artifactFormat: String
        let artifactRepository: String
        let artifactSourceURL: String
    }

    static let allowedModels: [RuntimeModelRole: AllowedModel] = [
        .asr: AllowedModel(
            repository: "nvidia/parakeet-tdt-0.6b-v3",
            license: "CC-BY-4.0",
            sourceURL: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            engine: .coreML,
            artifactFormat: "mlpackage",
            // VoxoL now publishes its own Core ML conversion rather than
            // consuming a third party's: the shipped encoder carries the
            // French/English fine-tune, and the package also carries
            // `language-penalty.json`, which the upstream conversion has no
            // reason to contain.
            artifactRepository: "arhesstide/voxol-parakeet-tdt-0.6b-v3-coreml",
            artifactSourceURL:
                "https://huggingface.co/arhesstide/voxol-parakeet-tdt-0.6b-v3-coreml"
        ),
        .polisher: AllowedModel(
            repository: "Qwen/Qwen3.5-0.8B",
            license: "Apache-2.0",
            sourceURL: "https://huggingface.co/Qwen/Qwen3.5-0.8B",
            engine: .mlx,
            artifactFormat: "mlx-4bit-qwen3.5",
            artifactRepository: "mlx-community/Qwen3.5-0.8B-4bit",
            artifactSourceURL: "https://huggingface.co/mlx-community/Qwen3.5-0.8B-4bit"
        ),
    ]

    func validate(_ model: RuntimeModel) throws {
        guard let allowed = Self.allowedModels[model.role] else {
            throw RuntimeModelManifestError.unauthorizedRepository(
                role: model.role,
                repository: model.repository
            )
        }
        guard model.repository == allowed.repository else {
            throw RuntimeModelManifestError.unauthorizedRepository(
                role: model.role,
                repository: model.repository
            )
        }
        try require(model.license, equals: allowed.license, field: "license", for: model.role)
        try require(
            model.sourceURL, equals: allowed.sourceURL, field: "source URL", for: model.role)
        try require(
            model.engine.rawValue,
            equals: allowed.engine.rawValue,
            field: "engine",
            for: model.role
        )
        try require(
            model.artifact.format,
            equals: allowed.artifactFormat,
            field: "artifact format",
            for: model.role
        )
        guard isLowercaseHex(model.revision, length: 40) else {
            throw RuntimeModelManifestError.invalidRevision(
                role: model.role,
                revision: model.revision
            )
        }

        switch model.artifact.state {
        case .pendingConversion:
            guard model.artifact.files.isEmpty else {
                throw RuntimeModelManifestError.pendingArtifactHasFiles(model.role)
            }
            guard model.artifact.provider == nil else {
                throw RuntimeModelManifestError.pendingArtifactHasProvider(model.role)
            }
        case .ready:
            guard !model.artifact.files.isEmpty else {
                throw RuntimeModelManifestError.readyArtifactHasNoFiles(model.role)
            }
            guard let provider = model.artifact.provider else {
                throw RuntimeModelManifestError.readyArtifactHasNoProvider(model.role)
            }
            guard provider.repository == allowed.artifactRepository else {
                throw RuntimeModelManifestError.unauthorizedArtifactProvider(
                    role: model.role,
                    repository: provider.repository
                )
            }
            try require(
                provider.sourceURL,
                equals: allowed.artifactSourceURL,
                field: "artifact source URL",
                for: model.role
            )
            guard isLowercaseHex(provider.revision, length: 40) else {
                throw RuntimeModelManifestError.invalidArtifactRevision(
                    role: model.role,
                    revision: provider.revision
                )
            }
        }

        var seenPaths = Set<String>()
        for file in model.artifact.files {
            let pathComponents = file.path.split(separator: "/", omittingEmptySubsequences: false)
            let hasUnsafeComponent = pathComponents.contains { component in
                component.isEmpty || component == "." || component == ".."
            }
            guard !file.path.hasPrefix("/"), !hasUnsafeComponent else {
                throw RuntimeModelManifestError.invalidArtifactPath(
                    role: model.role,
                    path: file.path
                )
            }
            guard seenPaths.insert(file.path).inserted else {
                throw RuntimeModelManifestError.duplicateArtifactPath(
                    role: model.role,
                    path: file.path
                )
            }
            guard isLowercaseHex(file.sha256, length: 64) else {
                throw RuntimeModelManifestError.invalidSHA256(
                    role: model.role,
                    path: file.path
                )
            }
            if model.artifact.state == .ready {
                guard let provider = model.artifact.provider else {
                    throw RuntimeModelManifestError.readyArtifactHasNoProvider(model.role)
                }
                guard let downloadURL = file.downloadURL, let sizeBytes = file.sizeBytes else {
                    throw RuntimeModelManifestError.missingDownloadMetadata(
                        role: model.role,
                        path: file.path
                    )
                }
                let expectedURL =
                    "\(provider.sourceURL)/resolve/\(provider.revision)/\(file.path)?download=true"
                guard URL(string: downloadURL)?.scheme == "https", downloadURL == expectedURL else {
                    throw RuntimeModelManifestError.invalidDownloadURL(
                        role: model.role,
                        path: file.path
                    )
                }
                guard sizeBytes > 0 else {
                    throw RuntimeModelManifestError.invalidArtifactSize(
                        role: model.role,
                        path: file.path
                    )
                }
            }
        }
    }

    func require(
        _ value: String,
        equals expected: String,
        field: String,
        for role: RuntimeModelRole
    ) throws {
        guard value == expected else {
            throw RuntimeModelManifestError.unexpectedValue(
                role: role,
                field: field,
                value: value
            )
        }
    }

    func isLowercaseHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }
}
