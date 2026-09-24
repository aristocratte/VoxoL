// swift-format-ignore-file: AllPublicDeclarationsHaveDocumentation

import CryptoKit
import Foundation

public enum TrainingReviewStatus: String, Codable, Sendable {
    case pending
    case accepted
    case contextReview = "context_review"
    case quarantined
}

public struct TrainingReviewProvenance: Codable, Equatable, Sendable {
    public var tier: String
    public var humanReviewed: Bool
    public var rationale: String

    enum CodingKeys: String, CodingKey {
        case tier, rationale
        case humanReviewed = "human_reviewed"
    }

    public init(tier: String, humanReviewed: Bool, rationale: String) {
        self.tier = tier
        self.humanReviewed = humanReviewed
        self.rationale = rationale
    }
}

public struct TrainingReviewChoice: Codable, Equatable, Sendable {
    public var verbatim: String
    public var faithful: String
    public var rewrite: String
    public var code: String
    public var verbatimSource: String
    public var faithfulSource: String
    public var rewriteSource: String
    public var codeSource: String
    public var verbatimSHA256: String
    public var faithfulSHA256: String
    public var rewriteSHA256: String
    public var codeSHA256: String

    public var clean: String {
        get { faithful }
        set { faithful = newValue }
    }
    public var cleanSource: String {
        get { faithfulSource }
        set { faithfulSource = newValue }
    }
    public var cleanSHA256: String {
        get { faithfulSHA256 }
        set { faithfulSHA256 = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case verbatimGold = "verbatim_gold"
        case faithfulGold = "faithful_gold"
        case rewriteGold = "rewrite_gold"
        case codeGold = "code_gold"
        case legacyVerbatim = "verbatim"
        case legacyClean = "clean"
        case verbatimSource = "verbatim_source"
        case faithfulSource = "faithful_source"
        case rewriteSource = "rewrite_source"
        case codeSource = "code_source"
        case legacyCleanSource = "clean_source"
        case verbatimSHA256 = "verbatim_sha256"
        case faithfulSHA256 = "faithful_sha256"
        case rewriteSHA256 = "rewrite_sha256"
        case codeSHA256 = "code_sha256"
        case legacyCleanSHA256 = "clean_sha256"
    }

    public init(
        verbatim: String,
        clean: String,
        verbatimSource: String,
        cleanSource: String,
        verbatimSHA256: String,
        cleanSHA256: String
    ) {
        self.verbatim = verbatim
        faithful = clean
        rewrite = ""
        code = ""
        self.verbatimSource = verbatimSource
        faithfulSource = cleanSource
        rewriteSource = "unreviewed"
        codeSource = "not-applicable"
        self.verbatimSHA256 = verbatimSHA256
        faithfulSHA256 = cleanSHA256
        rewriteSHA256 = ""
        codeSHA256 = ""
    }

    public init(
        verbatim: String,
        faithful: String,
        rewrite: String,
        code: String,
        verbatimSource: String,
        faithfulSource: String,
        rewriteSource: String,
        codeSource: String,
        verbatimSHA256: String,
        faithfulSHA256: String,
        rewriteSHA256: String,
        codeSHA256: String
    ) {
        self.verbatim = verbatim
        self.faithful = faithful
        self.rewrite = rewrite
        self.code = code
        self.verbatimSource = verbatimSource
        self.faithfulSource = faithfulSource
        self.rewriteSource = rewriteSource
        self.codeSource = codeSource
        self.verbatimSHA256 = verbatimSHA256
        self.faithfulSHA256 = faithfulSHA256
        self.rewriteSHA256 = rewriteSHA256
        self.codeSHA256 = codeSHA256
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        verbatim =
            try values.decodeIfPresent(String.self, forKey: .verbatimGold)
            ?? values.decode(String.self, forKey: .legacyVerbatim)
        faithful =
            try values.decodeIfPresent(String.self, forKey: .faithfulGold)
            ?? values.decode(String.self, forKey: .legacyClean)
        rewrite = try values.decodeIfPresent(String.self, forKey: .rewriteGold) ?? ""
        code = try values.decodeIfPresent(String.self, forKey: .codeGold) ?? ""
        verbatimSource =
            try values.decodeIfPresent(String.self, forKey: .verbatimSource)
            ?? "unknown"
        faithfulSource =
            try values.decodeIfPresent(String.self, forKey: .faithfulSource)
            ?? values.decodeIfPresent(String.self, forKey: .legacyCleanSource)
            ?? "unknown"
        rewriteSource =
            try values.decodeIfPresent(String.self, forKey: .rewriteSource)
            ?? "unreviewed"
        codeSource =
            try values.decodeIfPresent(String.self, forKey: .codeSource)
            ?? "not-applicable"
        verbatimSHA256 = try values.decodeIfPresent(String.self, forKey: .verbatimSHA256) ?? ""
        faithfulSHA256 =
            try values.decodeIfPresent(String.self, forKey: .faithfulSHA256)
            ?? values.decodeIfPresent(String.self, forKey: .legacyCleanSHA256)
            ?? ""
        rewriteSHA256 = try values.decodeIfPresent(String.self, forKey: .rewriteSHA256) ?? ""
        codeSHA256 = try values.decodeIfPresent(String.self, forKey: .codeSHA256) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(verbatim, forKey: .verbatimGold)
        try values.encode(faithful, forKey: .faithfulGold)
        try values.encode(rewrite, forKey: .rewriteGold)
        try values.encode(code, forKey: .codeGold)
        // Keep the two v1 aliases while local benchmark tooling migrates.
        try values.encode(verbatim, forKey: .legacyVerbatim)
        try values.encode(faithful, forKey: .legacyClean)
        try values.encode(verbatimSource, forKey: .verbatimSource)
        try values.encode(faithfulSource, forKey: .faithfulSource)
        try values.encode(rewriteSource, forKey: .rewriteSource)
        try values.encode(codeSource, forKey: .codeSource)
        try values.encode(faithfulSource, forKey: .legacyCleanSource)
        try values.encode(verbatimSHA256, forKey: .verbatimSHA256)
        try values.encode(faithfulSHA256, forKey: .faithfulSHA256)
        try values.encode(rewriteSHA256, forKey: .rewriteSHA256)
        try values.encode(codeSHA256, forKey: .codeSHA256)
        try values.encode(faithfulSHA256, forKey: .legacyCleanSHA256)
    }
}

public struct TrainingReviewCandidate: Codable, Equatable, Sendable {
    public let raw: String
    public let clean: String
    public let rawSHA256: String
    public let cleanSHA256: String

    enum CodingKeys: String, CodingKey {
        case raw, clean
        case rawSHA256 = "raw_sha256"
        case cleanSHA256 = "clean_sha256"
    }
}

public struct TrainingReviewAgreement: Codable, Equatable, Sendable {
    public let teacherRawDistance: Double
    public let teacherCleanDistance: Double
    public let rawMedoidDistance: Double
    public let cleanMedoidDistance: Double

    enum CodingKeys: String, CodingKey {
        case teacherRawDistance = "teacher_raw_distance"
        case teacherCleanDistance = "teacher_clean_distance"
        case rawMedoidDistance = "raw_medoid_distance"
        case cleanMedoidDistance = "clean_medoid_distance"
    }

    public init(
        teacherRawDistance: Double = 0,
        teacherCleanDistance: Double = 0,
        rawMedoidDistance: Double = 0,
        cleanMedoidDistance: Double = 0
    ) {
        self.teacherRawDistance = teacherRawDistance
        self.teacherCleanDistance = teacherCleanDistance
        self.rawMedoidDistance = rawMedoidDistance
        self.cleanMedoidDistance = cleanMedoidDistance
    }
}

public struct TrainingReviewDocument: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: String
    public let id: String
    public let audioPath: String
    public var status: TrainingReviewStatus
    public var provenance: TrainingReviewProvenance
    public var chosen: TrainingReviewChoice
    public let agreement: TrainingReviewAgreement
    public let criticalDisagreements: [String]
    public var reasons: [String]
    public let candidates: [String: TrainingReviewCandidate]
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, status, provenance, chosen, agreement, reasons, candidates
        case schemaVersion = "schema_version"
        case audioPath = "audio_path"
        case criticalDisagreements = "critical_disagreements"
        case updatedAt = "updated_at"
    }

    public init(
        schemaVersion: String = "voxol-transcript-adjudication-v1",
        id: String,
        audioPath: String,
        status: TrainingReviewStatus,
        provenance: TrainingReviewProvenance,
        chosen: TrainingReviewChoice,
        agreement: TrainingReviewAgreement = TrainingReviewAgreement(),
        criticalDisagreements: [String] = [],
        reasons: [String] = [],
        candidates: [String: TrainingReviewCandidate] = [:],
        updatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.audioPath = audioPath
        self.status = status
        self.provenance = provenance
        self.chosen = chosen
        self.agreement = agreement
        self.criticalDisagreements = criticalDisagreements
        self.reasons = reasons
        self.candidates = candidates
        self.updatedAt = updatedAt
    }
}

public struct TrainingReviewSession: Equatable, Identifiable, Sendable {
    public let id: String
    public let capturedAt: Date?
    public let language: String
    public let application: String
    public let durationSeconds: Double
    public let audioURL: URL
    /// Complete original from the same capture, when retention was enabled and space permitted.
    public let nativeAudioURL: URL?
    public let productRawText: String
    public let productFinalText: String
    public let verbatimText: String
    public let faithfulText: String
    public let rewriteText: String
    public let codeText: String
    public let review: TrainingReviewDocument?

    public var cleanText: String { faithfulText }
    public var playbackAudioURL: URL { nativeAudioURL ?? audioURL }

    public var status: TrainingReviewStatus { review?.status ?? .pending }
    public var tier: String { review?.provenance.tier ?? "unverified-capture" }
}

public enum TrainingReviewDisposition: String, Codable, Sendable {
    case accept
    case quarantine
}

public struct TrainingReviewDecision: Equatable, Sendable {
    public let id: String
    public let verbatim: String
    public let faithful: String
    public let rewrite: String
    public let code: String
    public let disposition: TrainingReviewDisposition
    public let rationale: String

    public init(
        id: String,
        verbatim: String,
        faithful: String,
        rewrite: String,
        code: String = "",
        disposition: TrainingReviewDisposition,
        rationale: String
    ) {
        self.id = id
        self.verbatim = verbatim
        self.faithful = faithful
        self.rewrite = rewrite
        self.code = code
        self.disposition = disposition
        self.rationale = rationale
    }

    public init(
        id: String,
        verbatim: String,
        clean: String,
        disposition: TrainingReviewDisposition,
        rationale: String
    ) {
        self.init(
            id: id,
            verbatim: verbatim,
            faithful: clean,
            rewrite: clean,
            disposition: disposition,
            rationale: rationale
        )
    }
}

public enum TrainingReviewRepositoryError: Error, Equatable, Sendable {
    case sessionMissing(String)
    case emptyDecision
}

public actor TrainingReviewRepository {
    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support =
                fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.rootURL = support.appendingPathComponent(
                "VoxoL/PersonalBenchmark", isDirectory: true)
        }
    }

    public func load() throws -> [TrainingReviewSession] {
        let sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        guard
            let directories = try? fileManager.contentsOfDirectory(
                at: sessionsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        return try directories.compactMap(loadSession).sorted {
            ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast)
        }
    }

    public func save(_ decision: TrainingReviewDecision) throws -> TrainingReviewSession {
        let verbatim = decision.verbatim.trimmingCharacters(in: .whitespacesAndNewlines)
        let faithful = decision.faithful.trimmingCharacters(in: .whitespacesAndNewlines)
        let rewrite = decision.rewrite.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = decision.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard decision.disposition == .quarantine
            || (!verbatim.isEmpty && !faithful.isEmpty && !rewrite.isEmpty)
        else {
            throw TrainingReviewRepositoryError.emptyDecision
        }
        let directory = sessionURL(for: decision.id)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw TrainingReviewRepositoryError.sessionMissing(decision.id)
        }
        let existing = try loadReview(from: directory)
        let status: TrainingReviewStatus =
            decision.disposition == .accept ? .accepted : .quarantined
        let choice = TrainingReviewChoice(
            verbatim: verbatim,
            faithful: faithful,
            rewrite: rewrite,
            code: code,
            verbatimSource: "owner",
            faithfulSource: "owner",
            rewriteSource: "owner",
            codeSource: code.isEmpty ? "not-applicable" : "owner",
            verbatimSHA256: Self.sha256(verbatim),
            faithfulSHA256: Self.sha256(faithful),
            rewriteSHA256: Self.sha256(rewrite),
            codeSHA256: code.isEmpty ? "" : Self.sha256(code)
        )
        let document = TrainingReviewDocument(
            schemaVersion: "voxol-transcript-adjudication-v2",
            id: decision.id,
            audioPath: existing?.audioPath ?? "sessions/\(decision.id)/audio.wav",
            status: status,
            provenance: TrainingReviewProvenance(
                tier: "human-reviewed",
                humanReviewed: true,
                rationale: decision.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            chosen: choice,
            agreement: existing?.agreement ?? TrainingReviewAgreement(),
            criticalDisagreements: existing?.criticalDisagreements ?? [],
            reasons: [decision.disposition == .accept ? "human_override" : "human_quarantine"],
            candidates: existing?.candidates ?? [:]
        )
        if decision.disposition == .accept {
            try Data(verbatim.utf8).write(
                to: directory.appendingPathComponent("verbatim.txt"),
                options: [.atomic, .completeFileProtection]
            )
            try Data(faithful.utf8).write(
                to: directory.appendingPathComponent("corrected.txt"),
                options: [.atomic, .completeFileProtection]
            )
            try Data(faithful.utf8).write(
                to: directory.appendingPathComponent("faithful.txt"),
                options: [.atomic, .completeFileProtection]
            )
            try Data(rewrite.utf8).write(
                to: directory.appendingPathComponent("rewrite.txt"),
                options: [.atomic, .completeFileProtection]
            )
            try Data(code.utf8).write(
                to: directory.appendingPathComponent("code.txt"),
                options: [.atomic, .completeFileProtection]
            )
        }
        try write(document, to: directory.appendingPathComponent("review.json"))
        guard let session = try loadSession(directory) else {
            throw TrainingReviewRepositoryError.sessionMissing(decision.id)
        }
        return session
    }

    public func exportJSONL() throws -> Data {
        let documents = try load().compactMap(\.review)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try documents.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        return Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
    }
}

private extension TrainingReviewRepository {
    struct SessionMetadata: Decodable {
        let date: String?
        let language: String?
        let application: String?
        let durationSeconds: Double?
        let rawText: String?
        let finalText: String?
        let nativeAudioComplete: Bool?
    }

    func sessionURL(for id: String) -> URL {
        rootURL.appendingPathComponent("sessions/\(id)", isDirectory: true)
    }

    func loadSession(_ directory: URL) throws -> TrainingReviewSession? {
        let metadataURL = directory.appendingPathComponent("meta.json")
        let audioURL = directory.appendingPathComponent("audio.wav")
        guard fileManager.fileExists(atPath: metadataURL.path),
            fileManager.fileExists(atPath: audioURL.path)
        else {
            return nil
        }
        let metadata = try JSONDecoder().decode(
            SessionMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
        let review = try loadReview(from: directory)
        let productRaw = metadata.rawText ?? ""
        let productFinal = metadata.finalText ?? ""
        let storedVerbatim = try readText(directory.appendingPathComponent("verbatim.txt"))
        let storedFaithful =
            try readText(directory.appendingPathComponent("faithful.txt"))
            ?? readText(directory.appendingPathComponent("corrected.txt"))
        let storedRewrite = try readText(directory.appendingPathComponent("rewrite.txt"))
        let storedCode = try readText(directory.appendingPathComponent("code.txt"))
        let nativeURL = directory.appendingPathComponent("native.wav")
        let nativeAvailable =
            metadata.nativeAudioComplete == true && fileManager.fileExists(atPath: nativeURL.path)
        return TrainingReviewSession(
            id: directory.lastPathComponent,
            capturedAt: metadata.date.flatMap(Self.date),
            language: metadata.language ?? "auto",
            application: metadata.application ?? "unknown",
            durationSeconds: metadata.durationSeconds ?? 0,
            audioURL: audioURL,
            nativeAudioURL: nativeAvailable ? nativeURL : nil,
            productRawText: productRaw,
            productFinalText: productFinal,
            verbatimText: review?.chosen.verbatim ?? storedVerbatim ?? productRaw,
            faithfulText: review?.chosen.faithful ?? storedFaithful ?? productFinal,
            rewriteText: nonempty(review?.chosen.rewrite) ?? storedRewrite ?? productFinal,
            codeText: nonempty(review?.chosen.code) ?? storedCode ?? "",
            review: review
        )
    }

    func loadReview(from directory: URL) throws -> TrainingReviewDocument? {
        let path = directory.appendingPathComponent("review.json")
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(
            TrainingReviewDocument.self,
            from: Data(contentsOf: path)
        )
    }

    func readText(_ path: URL) throws -> String? {
        guard fileManager.fileExists(atPath: path.path) else { return nil }
        return try String(contentsOf: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    func write(_ document: TrainingReviewDocument, to path: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(
            to: path,
            options: [.atomic, .completeFileProtection]
        )
    }

    static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
