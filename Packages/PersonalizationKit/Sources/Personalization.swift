import Foundation
import SQLite3

/// Language scope for a dictionary entry or voice snippet.
public enum PersonalizationLanguage: String, Codable, CaseIterable, Sendable {
    case any
    case english
    case french
}

/// Writing style selected explicitly or resolved from application context.
public enum WritingProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case chat
    case email
    case document
    case developer
    case prompt
    case raw

    /// Stable picker identifier.
    public var id: String { rawValue }
}

/// Canonical local term with optional spoken forms and application scope.
public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    /// How an entry came to exist — typed in, or earned from corrections.
    ///
    /// Displayed, not just stored: an entry that appeared on its own is only
    /// trustworthy if the user can see that it did, what it does, and turn it
    /// off. Invisible automation is how a bad rule rewrites a year of text.
    public enum Origin: String, Codable, Sendable {
        case manual
        case learned
    }

    /// Stable entry identifier.
    public var id: UUID
    /// Exact form emitted into the transcript.
    public var canonical: String
    /// Alternative ASR forms replaced by the canonical form.
    public var spokenForms: [String]
    /// Language scope.
    public var language: PersonalizationLanguage
    /// Empty for global use, otherwise allowed application bundle identifiers.
    public var bundleIdentifiers: [String]
    /// Whether matching is active.
    public var isEnabled: Bool
    /// Where this entry came from.
    public var origin: Origin

    /// Creates a local dictionary entry.
    public init(
        id: UUID = UUID(),
        canonical: String,
        spokenForms: [String] = [],
        language: PersonalizationLanguage = .any,
        bundleIdentifiers: [String] = [],
        isEnabled: Bool = true,
        origin: Origin = .manual
    ) {
        self.id = id
        self.canonical = canonical
        self.spokenForms = spokenForms
        self.language = language
        self.bundleIdentifiers = bundleIdentifiers
        self.isEnabled = isEnabled
        self.origin = origin
    }

    /// Decodes an entry, tolerating dictionaries written before `origin`
    /// existed — the synthesized decoder fails on the missing key even with a
    /// default, and a personalization file that stops decoding reads as the
    /// user's vocabulary being erased by an update.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        canonical = try container.decode(String.self, forKey: .canonical)
        spokenForms = try container.decode([String].self, forKey: .spokenForms)
        language = try container.decode(PersonalizationLanguage.self, forKey: .language)
        bundleIdentifiers = try container.decode([String].self, forKey: .bundleIdentifiers)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        origin = try container.decodeIfPresent(Origin.self, forKey: .origin) ?? .manual
    }

    /// Returns whether this enabled entry applies to an application.
    public func applies(to bundleIdentifier: String?) -> Bool {
        isEnabled
            && (bundleIdentifiers.isEmpty
                || bundleIdentifier.map(bundleIdentifiers.contains) == true)
    }
}

/// Exact spoken cue expanded into user-authored text.
public struct VoiceSnippet: Codable, Equatable, Identifiable, Sendable {
    /// Stable snippet identifier.
    public var id: UUID
    /// Exact spoken cue.
    public var trigger: String
    /// Text inserted for the cue.
    public var expansion: String
    /// Language scope.
    public var language: PersonalizationLanguage
    /// Empty for global use, otherwise allowed application bundle identifiers.
    public var bundleIdentifiers: [String]
    /// Whether expansion is active.
    public var isEnabled: Bool

    /// Creates a voice snippet.
    public init(
        id: UUID = UUID(),
        trigger: String,
        expansion: String,
        language: PersonalizationLanguage = .any,
        bundleIdentifiers: [String] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.language = language
        self.bundleIdentifiers = bundleIdentifiers
        self.isEnabled = isEnabled
    }

    /// Returns whether this enabled snippet applies to an application.
    public func applies(to bundleIdentifier: String?) -> Bool {
        isEnabled
            && (bundleIdentifiers.isEmpty
                || bundleIdentifier.map(bundleIdentifiers.contains) == true)
    }
}

/// Writing-profile override for an application and optional website domain.
public struct ApplicationProfileRule: Codable, Equatable, Identifiable, Sendable {
    /// Stable rule identifier.
    public var id: UUID
    /// Destination application bundle identifier.
    public var bundleIdentifier: String
    /// Optional exact or parent website domain.
    public var domain: String?
    /// Profile selected by the rule.
    public var profile: WritingProfile

    /// Creates an application profile rule.
    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        domain: String? = nil,
        profile: WritingProfile
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain
        self.profile = profile
    }
}

/// In-memory snapshot of manual local personalization.
public struct PersonalizationSnapshot: Codable, Equatable, Sendable {
    /// Schema version supported by this build.
    public static let currentSchemaVersion = 2

    /// Stored schema version.
    public var schemaVersion: Int
    /// User dictionary entries.
    public var dictionary: [DictionaryEntry]
    /// User voice snippets.
    public var snippets: [VoiceSnippet]
    /// Application and domain profile rules.
    public var applicationProfiles: [ApplicationProfileRule]

    /// Creates a personalization snapshot.
    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        dictionary: [DictionaryEntry] = [],
        snippets: [VoiceSnippet] = [],
        applicationProfiles: [ApplicationProfileRule] = []
    ) {
        self.schemaVersion = schemaVersion
        self.dictionary = dictionary
        self.snippets = snippets
        self.applicationProfiles = applicationProfiles
    }

    /// Returns enabled dictionary entries applicable to an application.
    public func dictionaryEntries(for bundleIdentifier: String?) -> [DictionaryEntry] {
        dictionary.filter { $0.applies(to: bundleIdentifier) }
    }

    /// Returns enabled snippets applicable to an application.
    public func snippets(for bundleIdentifier: String?) -> [VoiceSnippet] {
        snippets.filter { $0.applies(to: bundleIdentifier) }
    }

    /// Resolves the first matching application and domain profile rule.
    public func profile(
        for bundleIdentifier: String?,
        domain: String?
    ) -> WritingProfile? {
        guard let bundleIdentifier else {
            return nil
        }
        return applicationProfiles.first { rule in
            guard rule.bundleIdentifier == bundleIdentifier else {
                return false
            }
            guard let expectedDomain = rule.domain?.lowercased() else {
                return true
            }
            return domain?.lowercased() == expectedDomain
                || domain?.lowercased().hasSuffix("." + expectedDomain) == true
        }?.profile
    }
}

/// One explicitly approved local edit suitable for later dataset review.
public struct CorrectionPair: Codable, Equatable, Identifiable, Sendable {
    /// Stable pair identifier.
    public let id: UUID
    /// Time of the explicit edit.
    public let createdAt: Date
    /// Verbatim transcript before cleanup.
    public let rawTranscript: String
    /// Text saved by the user.
    public let correctedText: String
    /// Destination bundle identifier when available.
    public let bundleIdentifier: String?
    /// Effective writing profile.
    public let profile: WritingProfile
    /// Detected language.
    public let language: PersonalizationLanguage
    /// Explicit approval state.
    public let approved: Bool

    /// Creates one consented local correction pair.
    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawTranscript: String,
        correctedText: String,
        bundleIdentifier: String?,
        profile: WritingProfile,
        language: PersonalizationLanguage,
        approved: Bool = true
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.correctedText = correctedText
        self.bundleIdentifier = bundleIdentifier
        self.profile = profile
        self.language = language
        self.approved = approved
    }
}

/// Stable persistence errors from the local personalization repository.
public enum PersonalizationRepositoryError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case database(String)
}

/// Encrypted SQLite repository for dictionary, snippets, profiles and corrections.
public actor PersonalizationRepository {
    private let fileURL: URL
    private let legacyJSONURL: URL?
    private let fixedCipher: PersonalizationCipher?

    /// Creates the production repository or a deterministic repository at a test URL.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            legacyJSONURL = nil
            fixedCipher = PersonalizationCipher(keyData: Data(repeating: 0xA7, count: 32))
        } else {
            let applicationSupport =
                FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first ?? FileManager.default.temporaryDirectory
            self.fileURL =
                applicationSupport
                .appendingPathComponent("VoxoL", isDirectory: true)
                .appendingPathComponent("personalization.sqlite3")
            legacyJSONURL =
                applicationSupport
                .appendingPathComponent("VoxoL", isDirectory: true)
                .appendingPathComponent("personalization.json")
            fixedCipher = nil
        }
    }

    /// Loads a snapshot, migrating a legacy JSON store when present.
    public func load() throws -> PersonalizationSnapshot {
        if !FileManager.default.fileExists(atPath: fileURL.path),
            let legacyJSONURL,
            FileManager.default.fileExists(atPath: legacyJSONURL.path)
        {
            var snapshot = try JSONDecoder().decode(
                PersonalizationSnapshot.self,
                from: Data(contentsOf: legacyJSONURL)
            )
            snapshot.schemaVersion = PersonalizationSnapshot.currentSchemaVersion
            try save(snapshot)
            return snapshot
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PersonalizationSnapshot()
        }

        return try withDatabase { database in
            try ensureSchema(in: database)
            let cipher = try activeCipher()
            let schemaVersion = try readSchemaVersion(from: database)
            guard schemaVersion == PersonalizationSnapshot.currentSchemaVersion else {
                throw PersonalizationRepositoryError.unsupportedSchema(schemaVersion)
            }
            return PersonalizationSnapshot(
                schemaVersion: schemaVersion,
                dictionary: try loadDictionary(from: database, cipher: cipher),
                snippets: try loadSnippets(from: database, cipher: cipher),
                applicationProfiles: try loadProfiles(from: database, cipher: cipher)
            )
        }
    }

    /// Atomically replaces manual personalization tables.
    public func save(_ snapshot: PersonalizationSnapshot) throws {
        guard snapshot.schemaVersion == PersonalizationSnapshot.currentSchemaVersion else {
            throw PersonalizationRepositoryError.unsupportedSchema(snapshot.schemaVersion)
        }
        try withDatabase { database in
            try ensureSchema(in: database)
            let cipher = try activeCipher()
            try execute("BEGIN IMMEDIATE", in: database)
            do {
                try execute("DELETE FROM dictionary_entries", in: database)
                try execute("DELETE FROM snippets", in: database)
                try execute("DELETE FROM application_profiles", in: database)
                for entry in snapshot.dictionary {
                    try insert(entry, in: database, cipher: cipher)
                }
                for snippet in snapshot.snippets {
                    try insert(snippet, in: database, cipher: cipher)
                }
                for profile in snapshot.applicationProfiles {
                    try insert(profile, in: database, cipher: cipher)
                }
                try execute("COMMIT", in: database)
            } catch {
                try? execute("ROLLBACK", in: database)
                throw error
            }
        }
        protectDatabaseFiles()
    }

    /// Removes the SQLite database and sidecar files.
    public func reset() throws {
        for url in databaseFiles {
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Loads approved and pending local correction pairs.
    public func loadCorrections() throws -> [CorrectionPair] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        return try withDatabase { database in
            try ensureSchema(in: database)
            return try loadCorrections(from: database, cipher: activeCipher())
        }
    }

    /// Persists one explicit correction without rewriting personalization tables.
    public func addCorrection(_ correction: CorrectionPair) throws {
        try withDatabase { database in
            try ensureSchema(in: database)
            try insert(correction, in: database, cipher: activeCipher())
        }
        protectDatabaseFiles()
    }

    /// Deletes every retained correction pair while preserving manual personalization.
    public func removeAllCorrections() throws {
        try withDatabase { database in
            try ensureSchema(in: database)
            try execute("DELETE FROM correction_pairs", in: database)
        }
    }
}

private extension PersonalizationRepository {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func activeCipher() throws -> PersonalizationCipher {
        if let fixedCipher {
            return fixedCipher
        }
        return PersonalizationCipher(keyData: try PersonalizationKeychain.loadOrCreateKey())
    }

    var databaseFiles: [URL] {
        [
            fileURL,
            URL(fileURLWithPath: fileURL.path + "-wal"),
            URL(fileURLWithPath: fileURL.path + "-shm"),
        ]
    }

    func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            fileURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = database.map(databaseMessage) ?? "Unable to open personalization database"
            if let database {
                sqlite3_close(database)
            }
            throw PersonalizationRepositoryError.database(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        try execute("PRAGMA journal_mode=WAL", in: database)
        try execute("PRAGMA synchronous=NORMAL", in: database)
        return try operation(database)
    }

    func ensureSchema(in database: OpaquePointer) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """,
            in: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS dictionary_entries (
                id TEXT PRIMARY KEY NOT NULL,
                canonical TEXT NOT NULL,
                spoken_forms TEXT NOT NULL,
                language TEXT NOT NULL,
                bundle_identifiers TEXT NOT NULL,
                enabled INTEGER NOT NULL
            )
            """,
            in: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS snippets (
                id TEXT PRIMARY KEY NOT NULL,
                trigger TEXT NOT NULL,
                expansion TEXT NOT NULL,
                language TEXT NOT NULL,
                bundle_identifiers TEXT NOT NULL,
                enabled INTEGER NOT NULL
            )
            """,
            in: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS application_profiles (
                id TEXT PRIMARY KEY NOT NULL,
                bundle_identifier TEXT NOT NULL,
                domain TEXT,
                profile TEXT NOT NULL
            )
            """,
            in: database
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS correction_pairs (
                id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL,
                raw_transcript TEXT NOT NULL,
                corrected_text TEXT NOT NULL,
                bundle_identifier TEXT,
                profile TEXT NOT NULL,
                language TEXT NOT NULL,
                approved INTEGER NOT NULL
            )
            """,
            in: database
        )
        try execute(
            "INSERT OR IGNORE INTO metadata(key, value) VALUES ('schema_version', '\(PersonalizationSnapshot.currentSchemaVersion)')",
            in: database
        )
    }

    func readSchemaVersion(from database: OpaquePointer) throws -> Int {
        let statement = try prepare(
            "SELECT value FROM metadata WHERE key = 'schema_version'",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let value = columnText(statement, index: 0),
            let version = Int(value)
        else {
            throw PersonalizationRepositoryError.database("Missing schema version")
        }
        return version
    }

    func loadDictionary(
        from database: OpaquePointer,
        cipher: PersonalizationCipher
    ) throws -> [DictionaryEntry] {
        let statement = try prepare(
            "SELECT id, canonical, spoken_forms, language, bundle_identifiers, enabled FROM dictionary_entries ORDER BY rowid",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var entries: [DictionaryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnText(statement, index: 0).flatMap(UUID.init(uuidString:)),
                let canonicalValue = columnText(statement, index: 1),
                let languageRaw = columnText(statement, index: 3),
                let language = PersonalizationLanguage(rawValue: languageRaw)
            else {
                throw PersonalizationRepositoryError.database("Invalid dictionary row")
            }
            entries.append(
                DictionaryEntry(
                    id: id,
                    canonical: try cipher.open(canonicalValue),
                    spokenForms: try decodeArray(cipher.open(requiredText(statement, index: 2))),
                    language: language,
                    bundleIdentifiers: try decodeArray(
                        cipher.open(requiredText(statement, index: 4))),
                    isEnabled: sqlite3_column_int(statement, 5) != 0
                )
            )
        }
        return entries
    }

    func loadSnippets(
        from database: OpaquePointer,
        cipher: PersonalizationCipher
    ) throws -> [VoiceSnippet] {
        let statement = try prepare(
            "SELECT id, trigger, expansion, language, bundle_identifiers, enabled FROM snippets ORDER BY rowid",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var snippets: [VoiceSnippet] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnText(statement, index: 0).flatMap(UUID.init(uuidString:)),
                let triggerValue = columnText(statement, index: 1),
                let expansionValue = columnText(statement, index: 2),
                let languageRaw = columnText(statement, index: 3),
                let language = PersonalizationLanguage(rawValue: languageRaw)
            else {
                throw PersonalizationRepositoryError.database("Invalid snippet row")
            }
            snippets.append(
                VoiceSnippet(
                    id: id,
                    trigger: try cipher.open(triggerValue),
                    expansion: try cipher.open(expansionValue),
                    language: language,
                    bundleIdentifiers: try decodeArray(
                        cipher.open(requiredText(statement, index: 4))),
                    isEnabled: sqlite3_column_int(statement, 5) != 0
                )
            )
        }
        return snippets
    }

    func loadProfiles(
        from database: OpaquePointer,
        cipher: PersonalizationCipher
    ) throws -> [ApplicationProfileRule] {
        let statement = try prepare(
            "SELECT id, bundle_identifier, domain, profile FROM application_profiles ORDER BY rowid",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var profiles: [ApplicationProfileRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnText(statement, index: 0).flatMap(UUID.init(uuidString:)),
                let bundleIdentifierValue = columnText(statement, index: 1),
                let profileRaw = columnText(statement, index: 3),
                let profile = WritingProfile(rawValue: profileRaw)
            else {
                throw PersonalizationRepositoryError.database("Invalid profile row")
            }
            profiles.append(
                ApplicationProfileRule(
                    id: id,
                    bundleIdentifier: try cipher.open(bundleIdentifierValue),
                    domain: try columnText(statement, index: 2).map(cipher.open),
                    profile: profile
                )
            )
        }
        return profiles
    }

    func loadCorrections(
        from database: OpaquePointer,
        cipher: PersonalizationCipher
    ) throws -> [CorrectionPair] {
        let statement = try prepare(
            "SELECT id, created_at, raw_transcript, corrected_text, bundle_identifier, profile, language, approved FROM correction_pairs ORDER BY created_at DESC",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var corrections: [CorrectionPair] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnText(statement, index: 0).flatMap(UUID.init(uuidString:)),
                let rawValue = columnText(statement, index: 2),
                let correctedValue = columnText(statement, index: 3),
                let profileValue = columnText(statement, index: 5),
                let profile = WritingProfile(rawValue: profileValue),
                let languageValue = columnText(statement, index: 6),
                let language = PersonalizationLanguage(rawValue: languageValue)
            else {
                throw PersonalizationRepositoryError.database("Invalid correction row")
            }
            corrections.append(
                CorrectionPair(
                    id: id,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    rawTranscript: try cipher.open(rawValue),
                    correctedText: try cipher.open(correctedValue),
                    bundleIdentifier: try columnText(statement, index: 4).map(cipher.open),
                    profile: profile,
                    language: language,
                    approved: sqlite3_column_int(statement, 7) != 0
                )
            )
        }
        return corrections
    }

    func insert(
        _ entry: DictionaryEntry,
        in database: OpaquePointer,
        cipher: PersonalizationCipher
    ) throws {
        let statement = try prepare(
            "INSERT INTO dictionary_entries VALUES (?, ?, ?, ?, ?, ?)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bind(entry.id.uuidString, at: 1, to: statement)
        bind(try cipher.seal(entry.canonical), at: 2, to: statement)
        bind(try cipher.seal(encodeArray(entry.spokenForms)), at: 3, to: statement)
        bind(entry.language.rawValue, at: 4, to: statement)
        bind(try cipher.seal(encodeArray(entry.bundleIdentifiers)), at: 5, to: statement)
        sqlite3_bind_int(statement, 6, entry.isEnabled ? 1 : 0)
        try step(statement, in: database)
    }

    func insert(
        _ snippet: VoiceSnippet,
        in database: OpaquePointer,
        cipher: PersonalizationCipher
    ) throws {
        let statement = try prepare(
            "INSERT INTO snippets VALUES (?, ?, ?, ?, ?, ?)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bind(snippet.id.uuidString, at: 1, to: statement)
        bind(try cipher.seal(snippet.trigger), at: 2, to: statement)
        bind(try cipher.seal(snippet.expansion), at: 3, to: statement)
        bind(snippet.language.rawValue, at: 4, to: statement)
        bind(try cipher.seal(encodeArray(snippet.bundleIdentifiers)), at: 5, to: statement)
        sqlite3_bind_int(statement, 6, snippet.isEnabled ? 1 : 0)
        try step(statement, in: database)
    }

    func insert(
        _ profile: ApplicationProfileRule,
        in database: OpaquePointer,
        cipher: PersonalizationCipher
    ) throws {
        let statement = try prepare(
            "INSERT INTO application_profiles VALUES (?, ?, ?, ?)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bind(profile.id.uuidString, at: 1, to: statement)
        bind(try cipher.seal(profile.bundleIdentifier), at: 2, to: statement)
        if let domain = profile.domain {
            bind(try cipher.seal(domain), at: 3, to: statement)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        bind(profile.profile.rawValue, at: 4, to: statement)
        try step(statement, in: database)
    }

    func insert(
        _ correction: CorrectionPair,
        in database: OpaquePointer,
        cipher: PersonalizationCipher
    ) throws {
        let statement = try prepare(
            "INSERT OR REPLACE INTO correction_pairs VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bind(correction.id.uuidString, at: 1, to: statement)
        sqlite3_bind_double(statement, 2, correction.createdAt.timeIntervalSince1970)
        bind(try cipher.seal(correction.rawTranscript), at: 3, to: statement)
        bind(try cipher.seal(correction.correctedText), at: 4, to: statement)
        if let bundleIdentifier = correction.bundleIdentifier {
            bind(try cipher.seal(bundleIdentifier), at: 5, to: statement)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        bind(correction.profile.rawValue, at: 6, to: statement)
        bind(correction.language.rawValue, at: 7, to: statement)
        sqlite3_bind_int(statement, 8, correction.approved ? 1 : 0)
        try step(statement, in: database)
    }

    func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw PersonalizationRepositoryError.database(databaseMessage(database))
        }
        return statement
    }

    func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw PersonalizationRepositoryError.database(databaseMessage(database))
        }
    }

    func step(_ statement: OpaquePointer, in database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PersonalizationRepositoryError.database(databaseMessage(database))
        }
    }

    func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    func encodeArray(_ values: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }

    func decodeArray(_ value: String) throws -> [String] {
        return try JSONDecoder().decode([String].self, from: Data(value.utf8))
    }

    func requiredText(_ statement: OpaquePointer, index: Int32) throws -> String {
        guard let value = columnText(statement, index: index) else {
            throw PersonalizationRepositoryError.database("Missing encrypted value")
        }
        return value
    }

    func databaseMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    func protectDatabaseFiles() {
        for url in databaseFiles where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }
}
