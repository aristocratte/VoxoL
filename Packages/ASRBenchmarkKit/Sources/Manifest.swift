// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation
import CryptoKit
import Foundation

public enum ASRBenchmarkSplit: String, Codable, CaseIterable, Sendable {
    case development
    case calibration
    case blind
    case stress
}

/// A language a benchmark item can be spoken in.
///
/// French and English are the languages VoxoL is tuned for; the rest are the
/// remaining European languages the multilingual public suites cover, and they
/// are enumerated so an unadapted result can be measured rather than assumed.
public enum ASRBenchmarkLanguage: String, Codable, CaseIterable, Sendable {
    case french
    case english
    case mixed
    case german
    case spanish
    case italian
    case portuguese
    case dutch
    case polish
}

public enum ASRCriticalSpanKind: String, Codable, CaseIterable, Sendable {
    case person
    case organization
    case product
    case place
    case number
    case date
    case time
    case currency
    case unit
    case url
    case email
    case path
    case code
    case command
    case negation
}

public struct ASRCriticalSpan: Codable, Equatable, Sendable {
    public let kind: ASRCriticalSpanKind
    public let expected: String
    public let acceptedAlternatives: [String]

    public init(
        kind: ASRCriticalSpanKind,
        expected: String,
        acceptedAlternatives: [String] = []
    ) {
        self.kind = kind
        self.expected = expected
        self.acceptedAlternatives = acceptedAlternatives
    }
}

public struct ASRBenchmarkReference: Codable, Equatable, Sendable {
    public let verbatim: String
    public let clean: String
    public let criticalSpans: [ASRCriticalSpan]
    public let reviewed: Bool

    public init(
        verbatim: String,
        clean: String,
        criticalSpans: [ASRCriticalSpan] = [],
        reviewed: Bool
    ) {
        self.verbatim = verbatim
        self.clean = clean
        self.criticalSpans = criticalSpans
        self.reviewed = reviewed
    }
}

public struct ASRBenchmarkItem: Codable, Equatable, Sendable {
    public let id: String
    public let audioPath: String
    public let speakerID: String
    public let sessionID: String
    public let split: ASRBenchmarkSplit
    public let language: ASRBenchmarkLanguage
    public let microphone: String
    public let environment: String
    public let tags: [String]
    public let reference: ASRBenchmarkReference

    public init(
        id: String,
        audioPath: String,
        speakerID: String,
        sessionID: String,
        split: ASRBenchmarkSplit,
        language: ASRBenchmarkLanguage,
        microphone: String,
        environment: String,
        tags: [String],
        reference: ASRBenchmarkReference
    ) {
        self.id = id
        self.audioPath = audioPath
        self.speakerID = speakerID
        self.sessionID = sessionID
        self.split = split
        self.language = language
        self.microphone = microphone
        self.environment = environment
        self.tags = tags
        self.reference = reference
    }
}

public struct ASRBenchmarkManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let normalizationVersion = "voxol-asr-normalizer-v1"

    public let schemaVersion: Int
    public let benchmarkID: String
    public let normalizationVersion: String
    public let frozenAt: String?
    public let contentSHA256: String?
    public let items: [ASRBenchmarkItem]

    public init(
        schemaVersion: Int = Self.schemaVersion,
        benchmarkID: String,
        normalizationVersion: String = Self.normalizationVersion,
        frozenAt: String? = nil,
        contentSHA256: String? = nil,
        items: [ASRBenchmarkItem]
    ) {
        self.schemaVersion = schemaVersion
        self.benchmarkID = benchmarkID
        self.normalizationVersion = normalizationVersion
        self.frozenAt = frozenAt
        self.contentSHA256 = contentSHA256
        self.items = items
    }

    public func validate(requireFrozen: Bool = false) throws {
        guard schemaVersion == Self.schemaVersion else {
            throw ASRBenchmarkManifestError.unsupportedSchemaVersion(schemaVersion)
        }
        guard normalizationVersion == Self.normalizationVersion else {
            throw ASRBenchmarkManifestError.unsupportedNormalizationVersion(
                normalizationVersion
            )
        }
        guard !benchmarkID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ASRBenchmarkManifestError.missingBenchmarkID
        }
        guard !items.isEmpty else {
            throw ASRBenchmarkManifestError.emptyManifest
        }

        var identifiers = Set<String>()
        var speakerSplits = [String: ASRBenchmarkSplit]()
        var sessionSplits = [String: ASRBenchmarkSplit]()
        for item in items {
            guard identifiers.insert(item.id).inserted else {
                throw ASRBenchmarkManifestError.duplicateItemID(item.id)
            }
            guard Self.isSafeRelativePath(item.audioPath) else {
                throw ASRBenchmarkManifestError.unsafeAudioPath(item.audioPath)
            }
            guard
                !item.id.isEmpty,
                !item.speakerID.isEmpty,
                !item.sessionID.isEmpty,
                !item.microphone.isEmpty,
                !item.environment.isEmpty,
                !item.reference.verbatim.isEmpty,
                !item.reference.clean.isEmpty
            else {
                throw ASRBenchmarkManifestError.incompleteItem(item.id)
            }
            guard item.reference.reviewed else {
                throw ASRBenchmarkManifestError.unreviewedReference(item.id)
            }
            for span in item.reference.criticalSpans
            where span.expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ASRBenchmarkManifestError.emptyCriticalSpan(item.id)
            }
            if let previous = speakerSplits[item.speakerID], previous != item.split {
                throw ASRBenchmarkManifestError.speakerCrossesSplits(item.speakerID)
            }
            if let previous = sessionSplits[item.sessionID], previous != item.split {
                throw ASRBenchmarkManifestError.sessionCrossesSplits(item.sessionID)
            }
            speakerSplits[item.speakerID] = item.split
            sessionSplits[item.sessionID] = item.split
        }

        if requireFrozen {
            guard frozenAt != nil, let contentSHA256 else {
                throw ASRBenchmarkManifestError.notFrozen
            }
            let expectedDigest = try digest()
            guard contentSHA256 == expectedDigest else {
                throw ASRBenchmarkManifestError.digestMismatch
            }
        }
    }

    public func frozen(at timestamp: String) throws -> ASRBenchmarkManifest {
        let candidate = ASRBenchmarkManifest(
            benchmarkID: benchmarkID,
            normalizationVersion: normalizationVersion,
            frozenAt: timestamp,
            items: items
        )
        try candidate.validate()
        return ASRBenchmarkManifest(
            benchmarkID: candidate.benchmarkID,
            normalizationVersion: candidate.normalizationVersion,
            frozenAt: timestamp,
            contentSHA256: try candidate.digest(),
            items: candidate.items
        )
    }

    public func digest() throws -> String {
        let canonical = ASRBenchmarkManifest(
            benchmarkID: benchmarkID,
            normalizationVersion: normalizationVersion,
            frozenAt: frozenAt,
            items: items
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(canonical)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard
            !path.isEmpty,
            !path.hasPrefix("/"),
            !path.hasPrefix("~"),
            !components.contains(where: { $0 == ".." })
        else {
            return false
        }
        return true
    }
}

public enum ASRBenchmarkManifestError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case unsupportedNormalizationVersion(String)
    case missingBenchmarkID
    case emptyManifest
    case duplicateItemID(String)
    case unsafeAudioPath(String)
    case incompleteItem(String)
    case unreviewedReference(String)
    case emptyCriticalSpan(String)
    case speakerCrossesSplits(String)
    case sessionCrossesSplits(String)
    case notFrozen
    case digestMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported ASR benchmark schema version: \(version)"
        case .unsupportedNormalizationVersion(let version):
            "Unsupported ASR normalization version: \(version)"
        case .missingBenchmarkID:
            "The benchmark identifier is empty."
        case .emptyManifest:
            "The benchmark contains no items."
        case .duplicateItemID(let identifier):
            "Duplicate benchmark item identifier: \(identifier)"
        case .unsafeAudioPath(let path):
            "Audio path must be safe and relative: \(path)"
        case .incompleteItem(let identifier):
            "Benchmark item is incomplete: \(identifier)"
        case .unreviewedReference(let identifier):
            "Benchmark reference has not been reviewed: \(identifier)"
        case .emptyCriticalSpan(let identifier):
            "Benchmark item has an empty critical span: \(identifier)"
        case .speakerCrossesSplits(let speaker):
            "Speaker appears in more than one benchmark split: \(speaker)"
        case .sessionCrossesSplits(let session):
            "Session appears in more than one benchmark split: \(session)"
        case .notFrozen:
            "The benchmark manifest is not frozen."
        case .digestMismatch:
            "The frozen benchmark digest does not match its contents."
        }
    }
}
