import CryptoKit
import CoreML
import Foundation
import Observation

enum ModelInstallationPhase: Equatable {
    case loading
    case awaitingVerifiedArtifact
    case readyToDownload
    case downloading
    case paused
    case verifying
    case installed
    case failed
}

struct ModelInstallationItem: Identifiable, Equatable {
    let model: RuntimeModel
    var phase: ModelInstallationPhase
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var failureReason: String?

    var id: RuntimeModelRole { model.role }

    var progress: Double {
        guard totalBytes > 0 else {
            return 0
        }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }
}

@MainActor
@Observable
final class ModelInstallationStore {
    private(set) var items: [ModelInstallationItem] = []
    private(set) var isLoading = false
    private(set) var manifestLoadFailed = false

    private var installationTasks: [RuntimeModelRole: Task<Void, Never>] = [:]

    var installedCount: Int {
        items.count { $0.phase == .installed }
    }

    var allInstalled: Bool {
        !items.isEmpty && installedCount == items.count
    }

    func installedDirectory(for role: RuntimeModelRole) -> URL? {
        if let override = Self.developmentOverrideDirectory(for: role) {
            return override
        }
        guard
            let item = items.first(where: { $0.id == role }),
            item.phase == .installed
        else {
            return nil
        }
        return try? Self.installationDirectory(for: item.model)
    }

    func load() async {
        guard !isLoading else {
            return
        }
        isLoading = true
        manifestLoadFailed = false
        defer { isLoading = false }

        do {
            guard
                let manifestURL = Bundle.main.url(
                    forResource: "runtime-models",
                    withExtension: "json"
                )
            else {
                throw ModelInstallationError.manifestMissing
            }
            let manifest = try RuntimeModelManifest.loadAndValidate(from: manifestURL)
            var loadedItems: [ModelInstallationItem] = []
            var rolesToResume: [RuntimeModelRole] = []
            for model in manifest.models {
                let totalBytes = model.artifact.files.compactMap(\.sizeBytes).reduce(0, +)
                let installed = await Self.isInstalled(model)
                let resumableBytes = installed ? totalBytes : Self.resumableBytes(for: model)
                let phase: ModelInstallationPhase
                if installed {
                    phase = .installed
                    Self.setAutomaticResume(false, for: model.role)
                } else if model.artifact.state != .ready {
                    phase = .awaitingVerifiedArtifact
                } else if resumableBytes > 0 {
                    phase = .paused
                } else {
                    phase = .readyToDownload
                }
                loadedItems.append(
                    ModelInstallationItem(
                        model: model,
                        phase: phase,
                        downloadedBytes: resumableBytes,
                        totalBytes: totalBytes
                    )
                )
                if !installed, model.artifact.state == .ready,
                    Self.shouldResumeAutomatically(model.role)
                {
                    rolesToResume.append(model.role)
                }
            }
            items = loadedItems
            for role in rolesToResume {
                install(role)
            }
        } catch {
            items = []
            manifestLoadFailed = true
        }
    }

    func install(_ role: RuntimeModelRole) {
        guard installationTasks[role] == nil else {
            return
        }
        guard let item = items.first(where: { $0.id == role }),
            item.phase == .readyToDownload || item.phase == .paused || item.phase == .failed
        else {
            return
        }

        Self.setAutomaticResume(true, for: role)
        installationTasks[role] = Task { [weak self] in
            guard let self else {
                return
            }
            await performInstallation(item.model)
            installationTasks[role] = nil
        }
    }

    func pause(_ role: RuntimeModelRole) {
        Self.setAutomaticResume(false, for: role)
        installationTasks[role]?.cancel()
        update(role) { item in
            item.phase = .paused
            item.failureReason = nil
        }
    }

    private func performInstallation(_ model: RuntimeModel) async {
        update(model.role) { item in
            item.phase = .downloading
            item.downloadedBytes = Self.resumableBytes(for: model)
            item.failureReason = nil
        }

        do {
            let downloadDirectory = try Self.makeDownloadDirectory(for: model)
            let alreadyDownloaded = Self.resumableBytes(for: model)
            try Self.ensureAvailableDiskSpace(
                for: model,
                downloadedBytes: alreadyDownloaded,
                at: downloadDirectory
            )

            var completedBytes: Int64 = 0
            for file in model.artifact.files {
                try Task.checkCancellation()
                guard let source = file.downloadURL.flatMap(URL.init(string:)),
                    let expectedSize = file.sizeBytes
                else {
                    throw ModelInstallationError.missingDownloadURL
                }
                let destination = downloadDirectory.appendingPathComponent(file.path)
                let partial = Self.partialURL(for: destination)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if Self.fileSize(at: destination) == expectedSize {
                    update(model.role) { $0.phase = .verifying }
                    let checksum = try await Task.detached {
                        try Self.sha256(of: destination)
                    }.value
                    if checksum == file.sha256 {
                        try? FileManager.default.removeItem(at: partial)
                        completedBytes += expectedSize
                        update(model.role) { item in
                            item.phase = .downloading
                            item.downloadedBytes = completedBytes
                        }
                        continue
                    }
                    try FileManager.default.removeItem(at: destination)
                } else if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }

                if Self.fileSize(at: partial) != expectedSize {
                    let completedBeforeFile = completedBytes
                    let download = try ResumableFileDownload(
                        sourceURL: source,
                        partialURL: partial,
                        expectedSize: expectedSize
                    ) { [weak self] received in
                        Task { @MainActor in
                            self?.update(model.role) { item in
                                item.downloadedBytes = min(
                                    item.totalBytes,
                                    completedBeforeFile + received
                                )
                            }
                        }
                    }
                    try await download.start()
                }

                guard Self.fileSize(at: partial) == expectedSize else {
                    throw ModelInstallationError.downloadSizeMismatch
                }
                try FileManager.default.moveItem(at: partial, to: destination)

                update(model.role) { $0.phase = .verifying }
                let checksum = try await Task.detached {
                    try Self.sha256(of: destination)
                }.value
                guard checksum == file.sha256 else {
                    try? FileManager.default.removeItem(at: destination)
                    throw ModelInstallationError.checksumMismatch
                }
                completedBytes += expectedSize
                update(model.role) { item in
                    item.phase = .downloading
                    item.downloadedBytes = completedBytes
                }
            }

            update(model.role) { $0.phase = .verifying }
            try await Task.detached {
                try Self.validateArtifact(at: downloadDirectory, for: model)
            }.value
            try Self.activate(downloadDirectory, for: model)
            Self.setAutomaticResume(false, for: model.role)
            update(model.role) { item in
                item.phase = .installed
                item.downloadedBytes = item.totalBytes
            }
        } catch is CancellationError {
            update(model.role) { item in
                item.phase = .paused
                item.downloadedBytes = Self.resumableBytes(for: model)
            }
        } catch let error as URLError where error.code == .cancelled {
            update(model.role) { item in
                item.phase = .paused
                item.downloadedBytes = Self.resumableBytes(for: model)
            }
        } catch {
            Self.setAutomaticResume(false, for: model.role)
            update(model.role) { item in
                item.phase = .failed
                item.downloadedBytes = Self.resumableBytes(for: model)
                item.failureReason = error.localizedDescription
            }
        }
    }

    private func update(
        _ role: RuntimeModelRole,
        mutation: (inout ModelInstallationItem) -> Void
    ) {
        guard let index = items.firstIndex(where: { $0.id == role }) else {
            return
        }
        mutation(&items[index])
    }
}

private enum ModelInstallationError: Error {
    case manifestMissing
    case missingDownloadURL
    case insufficientDiskSpace
    case downloadSizeMismatch
    case checksumMismatch
    case artifactSmokeTestFailed
}

private extension ModelInstallationStore {
    nonisolated static func developmentOverrideDirectory(for role: RuntimeModelRole) -> URL? {
        guard role == .asr,
            let path = ProcessInfo.processInfo.environment["VOXOL_ASR_MODEL_ROOT"],
            !path.isEmpty
        else {
            return nil
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let requiredFiles = [
            "encoder.mlpackage",
            "decoder.mlpackage",
            "joint.mlpackage",
            "tokenizer.json",
        ]
        guard
            requiredFiles.allSatisfy({
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent($0).path
                )
            })
        else {
            return nil
        }
        return directory
    }

    nonisolated static func modelRoot() throws -> URL {
        guard
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        return applicationSupport.appendingPathComponent("VoxoL/Models", isDirectory: true)
    }

    nonisolated static func installationDirectory(for model: RuntimeModel) throws -> URL {
        try modelRoot()
            .appendingPathComponent(model.role.rawValue, isDirectory: true)
            .appendingPathComponent(model.revision, isDirectory: true)
    }

    nonisolated static func makeDownloadDirectory(for model: RuntimeModel) throws -> URL {
        guard let providerRevision = model.artifact.provider?.revision else {
            throw ModelInstallationError.missingDownloadURL
        }
        let directory = try modelRoot()
            .appendingPathComponent(".downloads", isDirectory: true)
            .appendingPathComponent(model.role.rawValue, isDirectory: true)
            .appendingPathComponent(model.revision, isDirectory: true)
            .appendingPathComponent(providerRevision, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static func activate(_ stagingDirectory: URL, for model: RuntimeModel) throws {
        let destination = try installationDirectory(for: model)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: stagingDirectory)
        } else {
            try FileManager.default.moveItem(at: stagingDirectory, to: destination)
        }
    }

    nonisolated static func ensureAvailableDiskSpace(
        for model: RuntimeModel,
        downloadedBytes: Int64,
        at url: URL
    ) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            return
        }
        let artifactBytes = model.artifact.files.compactMap(\.sizeBytes).reduce(0, +)
        let remainingBytes = max(0, artifactBytes - downloadedBytes)
        let temporaryOverhead = model.role == .asr ? artifactBytes : 268_435_456
        guard available >= remainingBytes + temporaryOverhead else {
            throw ModelInstallationError.insufficientDiskSpace
        }
    }

    nonisolated static func resumableBytes(for model: RuntimeModel) -> Int64 {
        guard let directory = try? makeDownloadDirectory(for: model) else {
            return 0
        }
        return model.artifact.files.reduce(into: 0) { total, file in
            guard let expectedSize = file.sizeBytes else {
                return
            }
            let destination = directory.appendingPathComponent(file.path)
            let partial = partialURL(for: destination)
            if fileSize(at: destination) > 0 {
                total += min(expectedSize, fileSize(at: destination))
            } else {
                total += min(expectedSize, fileSize(at: partial))
            }
        }
    }

    nonisolated static func partialURL(for destination: URL) -> URL {
        destination.appendingPathExtension("partial")
    }

    nonisolated static func fileSize(at url: URL) -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }

    nonisolated static func shouldResumeAutomatically(_ role: RuntimeModelRole) -> Bool {
        UserDefaults.standard.bool(forKey: automaticResumeKey(for: role))
    }

    nonisolated static func setAutomaticResume(_ enabled: Bool, for role: RuntimeModelRole) {
        UserDefaults.standard.set(enabled, forKey: automaticResumeKey(for: role))
    }

    nonisolated static func automaticResumeKey(for role: RuntimeModelRole) -> String {
        "voxol.model-download.auto-resume.\(role.rawValue)"
    }

    nonisolated static func validateArtifact(at directory: URL, for model: RuntimeModel) throws {
        switch model.role {
        case .asr:
            try validateCoreMLArtifact(at: directory)
        case .polisher:
            try validateQwenMLXArtifact(at: directory)
        }
    }

    nonisolated static func validateCoreMLArtifact(at directory: URL) throws {
        let cache = ModelCache(
            cacheDirectory: directory.appendingPathComponent(".compiled", isDirectory: true)
        )
        for packageName in ["encoder.mlpackage", "decoder.mlpackage", "joint.mlpackage"] {
            let packageURL = directory.appendingPathComponent(packageName, isDirectory: true)
            let compiledURL: URL
            do {
                compiledURL = try cache.compiledURL(for: packageURL)
            } catch {
                throw ModelInstallationError.artifactSmokeTestFailed
            }

            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits =
                    packageName == "encoder.mlpackage" ? .all : .cpuOnly
                _ = try MLModel(contentsOf: compiledURL, configuration: configuration)
            } catch {
                throw ModelInstallationError.artifactSmokeTestFailed
            }
        }

        let tokenizerURL = directory.appendingPathComponent("tokenizer.json")
        guard
            let tokenizer = try JSONSerialization.jsonObject(with: Data(contentsOf: tokenizerURL))
                as? [String: Any],
            !tokenizer.isEmpty
        else {
            throw ModelInstallationError.artifactSmokeTestFailed
        }
    }

    nonisolated static func validateQwenMLXArtifact(at directory: URL) throws {
        let configURL = directory.appendingPathComponent("config.json")
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        let weightsURL = directory.appendingPathComponent("model.safetensors")

        guard
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL))
                as? [String: Any],
            let textConfig = config["text_config"] as? [String: Any],
            textConfig["model_type"] as? String == "qwen3_5_text",
            let quantization = config["quantization"] as? [String: Any],
            (quantization["bits"] as? NSNumber)?.intValue == 4,
            quantization["mode"] as? String == "affine",
            let index = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL))
                as? [String: Any],
            let weightMap = index["weight_map"] as? [String: String],
            !weightMap.isEmpty,
            weightMap.keys.contains(where: { $0.hasPrefix("language_model.") }),
            weightMap.keys.allSatisfy({
                $0.hasPrefix("language_model.") || $0.hasPrefix("vision_tower.")
            }),
            Set(weightMap.values) == Set(["model.safetensors"]),
            FileManager.default.fileExists(atPath: weightsURL.path)
        else {
            throw ModelInstallationError.artifactSmokeTestFailed
        }
    }

    nonisolated static func isInstalled(_ model: RuntimeModel) async -> Bool {
        guard model.artifact.state == .ready,
            let directory = try? installationDirectory(for: model)
        else {
            return false
        }
        return await Task.detached {
            for file in model.artifact.files {
                let url = directory.appendingPathComponent(file.path)
                guard FileManager.default.fileExists(atPath: url.path),
                    (try? sha256(of: url)) == file.sha256
                else {
                    return false
                }
            }
            return !model.artifact.files.isEmpty
        }.value
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
