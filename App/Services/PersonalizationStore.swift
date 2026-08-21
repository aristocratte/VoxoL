import Foundation
import Observation
import PersonalizationKit
import TextProcessingKit

@MainActor
@Observable
final class PersonalizationStore {
    private(set) var snapshot = PersonalizationSnapshot()
    private(set) var corrections: [CorrectionPair] = []
    private(set) var isLoaded = false
    private(set) var lastError: String?

    @ObservationIgnored private let repository: PersonalizationRepository

    /// Called after the dictionary changes, however it changes.
    ///
    /// The decoder boosts dictionary terms through a prebuilt trie, and that
    /// trie used to be rebuilt only at configuration time — so a word learned
    /// mid-session was substituted in post-processing but not *recognised*
    /// until the next launch. The coordinator installs itself here so the
    /// boost follows the dictionary immediately.
    @ObservationIgnored var dictionaryDidChange: (() -> Void)?

    /// Called with the entries an automatic promotion just created, so the
    /// interface can say "learned: chipset" while the correction that earned
    /// it is still on the user's mind. Silence here is what made the feature
    /// invisible: it had been learning since 0.1.2 and nobody could tell.
    @ObservationIgnored var dictionaryDidLearn: (([DictionaryEntry]) -> Void)?

    init(repository: PersonalizationRepository = PersonalizationRepository()) {
        self.repository = repository
    }

    func load() async {
        guard !isLoaded else {
            return
        }
        do {
            snapshot = try await repository.load()
            corrections = try await repository.loadCorrections()
            lastError = nil
        } catch {
            snapshot = PersonalizationSnapshot()
            corrections = []
            lastError = error.localizedDescription
        }
        isLoaded = true
        // The store loads in parallel with the speech runtime's configuration,
        // and whichever finishes second must not leave the decoder biased on
        // an empty dictionary.
        if !snapshot.dictionary.isEmpty {
            dictionaryDidChange?()
        }
    }

    func addDictionaryEntry(_ entry: DictionaryEntry) async {
        snapshot.dictionary.append(entry)
        await persist()
        dictionaryDidChange?()
    }

    func updateDictionaryEntry(_ entry: DictionaryEntry) async {
        guard let index = snapshot.dictionary.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        snapshot.dictionary[index] = entry
        await persist()
        dictionaryDidChange?()
    }

    func removeDictionaryEntry(id: UUID) async {
        snapshot.dictionary.removeAll { $0.id == id }
        await persist()
        dictionaryDidChange?()
    }

    func addSnippet(_ snippet: VoiceSnippet) async {
        snapshot.snippets.append(snippet)
        await persist()
    }

    func updateSnippet(_ snippet: VoiceSnippet) async {
        guard let index = snapshot.snippets.firstIndex(where: { $0.id == snippet.id }) else {
            return
        }
        snapshot.snippets[index] = snippet
        await persist()
    }

    func removeSnippet(id: UUID) async {
        snapshot.snippets.removeAll { $0.id == id }
        await persist()
    }

    func setProfile(
        _ profile: WritingProfile,
        for bundleIdentifier: String,
        domain: String? = nil
    ) async {
        snapshot.applicationProfiles.removeAll {
            $0.bundleIdentifier == bundleIdentifier && $0.domain == domain
        }
        snapshot.applicationProfiles.append(
            ApplicationProfileRule(
                bundleIdentifier: bundleIdentifier,
                domain: domain,
                profile: profile
            )
        )
        await persist()
    }

    func removeProfileRule(id: UUID) async {
        snapshot.applicationProfiles.removeAll { $0.id == id }
        await persist()
    }

    func addCorrection(_ correction: CorrectionPair) async {
        do {
            try await repository.addCorrection(correction)
            corrections.insert(correction, at: 0)
            lastError = nil
            await demoteContradictedEntries(by: correction)
            await promoteRepeatedCorrections()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Pauses learned entries the user just corrected away — the loop-breaker
    /// for bias reinforcing its own mistake. The entry stays visible in the
    /// Library as paused rather than vanishing: an automation that undoes
    /// itself silently is as opaque as one that acts silently.
    private func demoteContradictedEntries(by correction: CorrectionPair) async {
        let contradicted = DictionaryLearning.contradictedEntries(
            by: correction,
            in: snapshot.dictionary
        )
        guard !contradicted.isEmpty else { return }
        for id in contradicted {
            if let index = snapshot.dictionary.firstIndex(where: { $0.id == id }) {
                snapshot.dictionary[index].isEnabled = false
            }
        }
        await persist()
        dictionaryDidChange?()
    }

    /// Adds dictionary entries for mistakes the user has now corrected more
    /// than once.
    ///
    /// Corrections used to accumulate and do nothing: the only thing that read
    /// them was an offline script, so a word the recogniser got wrong every
    /// time stayed wrong unless it was typed into the dictionary by hand. The
    /// thresholds live in `DictionaryLearning` — repeated evidence, and a
    /// change small enough to be a mishearing rather than a rewrite.
    private func promoteRepeatedCorrections() async {
        let learned = DictionaryLearning.suggestions(
            from: corrections,
            existing: snapshot.dictionary
        )
        guard !learned.isEmpty else { return }
        snapshot.dictionary.append(contentsOf: learned)
        await persist()
        dictionaryDidChange?()
        dictionaryDidLearn?(learned)
    }

    func removeAllCorrections() async {
        do {
            try await repository.removeAllCorrections()
            corrections = []
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func correctionExportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = try corrections.map { correction in
            let preparation = DeterministicTextProcessor.prepare(
                TextProcessingRequest(
                    rawTranscript: correction.rawTranscript,
                    preferredLanguage: correction.language == .french ? .french : .english,
                    preferences: TextProcessingPreferences(
                        fastPathEnabled: false,
                        profile: correction.profile
                    )
                )
            )
            let source = ExportedCorrection(
                id: correction.id.uuidString,
                language: correction.language == .french ? "fr" : "en",
                profile: correction.profile.rawValue,
                protectedTokens: preparation.protectedTokens.map(\.value),
                rawTranscript: correction.rawTranscript,
                targetText: correction.correctedText,
                approved: correction.approved
            )
            return String(decoding: try encoder.encode(source), as: UTF8.self)
        }
        return Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
    }
}

private struct ExportedCorrection: Encodable {
    let id: String
    let language: String
    let profile: String
    let appCategory = "personal"
    let beforeCursor = ""
    let afterCursor = ""
    let dictionary: [String] = []
    let protectedTokens: [String]
    let rawTranscript: String
    let targetText: String
    let operations = ["human_edit"]
    let source = "human"
    let approved: Bool

    enum CodingKeys: String, CodingKey {
        case id, language, profile, dictionary, operations, source, approved
        case appCategory = "app_category"
        case beforeCursor = "before_cursor"
        case afterCursor = "after_cursor"
        case protectedTokens = "protected_tokens"
        case rawTranscript = "raw_transcript"
        case targetText = "target_text"
    }
}

private extension PersonalizationStore {
    func persist() async {
        do {
            try await repository.save(snapshot)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
