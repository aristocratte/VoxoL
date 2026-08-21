import Darwin
import Foundation
import PersonalizationKit

/// Imports reviewed dictionary entries through the app's own store.
///
/// The personalization store is an encrypted database whose key lives in the
/// app's keychain context — the honest ways in are the UI, one entry at a
/// time, or this: the app run headless against a reviewed JSONL file. It
/// exists because the labeling loop produces vocabulary in batches
/// (validated ASR repairs like "linéaire Oatt" → "Linear OAuth"), and asking
/// a person to retype what they already approved is the friction this
/// project keeps removing.
///
/// Idempotent: an entry whose canonical and spoken forms are already known is
/// skipped, so re-running an import file is safe.
enum DictionaryImportRunner {
    static let argument = "--import-dictionary"

    static func runAndExit(arguments: [String]) async -> Never {
        let code = await run(arguments: arguments)
        fflush(stdout)
        Darwin.exit(code)
    }

    private struct ImportedEntry: Decodable {
        let canonical: String
        let spokenForms: [String]
        let language: String?
    }

    private static func run(arguments: [String]) async -> Int32 {
        guard let index = arguments.firstIndex(of: argument),
            arguments.indices.contains(index + 1)
        else {
            print("Usage: VoxoL --import-dictionary <fichier.jsonl>")
            return 2
        }
        let fileURL = URL(fileURLWithPath: arguments[index + 1])
        do {
            let lines = try String(contentsOf: fileURL, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
            let repository = PersonalizationRepository()
            var snapshot = try await repository.load()
            let known = Set(
                snapshot.dictionary.flatMap { entry in
                    entry.spokenForms.map { "\(entry.canonical.lowercased())|\($0.lowercased())" }
                }
            )
            var added = 0
            for line in lines {
                let imported = try JSONDecoder().decode(
                    ImportedEntry.self,
                    from: Data(line.utf8)
                )
                let spoken = imported.spokenForms.filter {
                    !known.contains("\(imported.canonical.lowercased())|\($0.lowercased())")
                }
                guard !spoken.isEmpty else { continue }
                snapshot.dictionary.append(
                    DictionaryEntry(
                        canonical: imported.canonical,
                        spokenForms: spoken,
                        language: PersonalizationLanguage(
                            rawValue: imported.language ?? "any"
                        ) ?? .any,
                        origin: .learned
                    )
                )
                added += 1
            }
            try await repository.save(snapshot)
            print("\(added) entrée(s) importée(s), dictionnaire: \(snapshot.dictionary.count)")
            return 0
        } catch {
            print("Import échoué: \(error.localizedDescription)")
            return 1
        }
    }
}
