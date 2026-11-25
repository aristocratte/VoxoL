import PersonalizationKit
import SwiftUI

struct DictionaryEntryEditor: View {
    @Environment(\.dismiss) private var dismiss

    let id: UUID
    let save: (DictionaryEntry) -> Void

    @State private var canonical: String
    @State private var spokenForms: String
    @State private var language: PersonalizationLanguage
    @State private var bundleIdentifiers: String
    @State private var isEnabled: Bool

    init(entry: DictionaryEntry?, save: @escaping (DictionaryEntry) -> Void) {
        id = entry?.id ?? UUID()
        self.save = save
        _canonical = State(initialValue: entry?.canonical ?? "")
        _spokenForms = State(initialValue: entry?.spokenForms.joined(separator: ", ") ?? "")
        _language = State(initialValue: entry?.language ?? .any)
        _bundleIdentifiers = State(
            initialValue: entry?.bundleIdentifiers.joined(separator: ", ") ?? ""
        )
        _isEnabled = State(initialValue: entry?.isEnabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Dictionary entry")
                .font(.title2.weight(.semibold))
            TextField("Canonical form", text: $canonical)
            TextField("Spoken forms, separated by commas", text: $spokenForms)
            TextField("App bundle identifiers, separated by commas", text: $bundleIdentifiers)
            Picker("Language", selection: $language) {
                Text("Any").tag(PersonalizationLanguage.any)
                Text("English").tag(PersonalizationLanguage.english)
                Text("French").tag(PersonalizationLanguage.french)
            }
            Toggle("Enabled", isOn: $isEnabled)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save(
                        DictionaryEntry(
                            id: id,
                            canonical: canonical.trimmingCharacters(in: .whitespacesAndNewlines),
                            spokenForms: commaSeparated(spokenForms),
                            language: language,
                            bundleIdentifiers: commaSeparated(bundleIdentifiers),
                            isEnabled: isEnabled
                        )
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct SnippetEditor: View {
    @Environment(\.dismiss) private var dismiss

    let id: UUID
    let existingTriggers: [String]
    let save: (VoiceSnippet) -> Void

    @State private var trigger: String
    @State private var expansion: String
    @State private var language: PersonalizationLanguage
    @State private var bundleIdentifiers: String
    @State private var isEnabled: Bool

    init(
        snippet: VoiceSnippet?,
        existingTriggers: [String],
        save: @escaping (VoiceSnippet) -> Void
    ) {
        id = snippet?.id ?? UUID()
        self.existingTriggers = existingTriggers
        self.save = save
        _trigger = State(initialValue: snippet?.trigger ?? "")
        _expansion = State(initialValue: snippet?.expansion ?? "")
        _language = State(initialValue: snippet?.language ?? .any)
        _bundleIdentifiers = State(
            initialValue: snippet?.bundleIdentifiers.joined(separator: ", ") ?? ""
        )
        _isEnabled = State(initialValue: snippet?.isEnabled ?? true)
    }

    private var conflicts: Bool {
        existingTriggers.contains {
            $0.compare(
                trigger.trimmingCharacters(in: .whitespacesAndNewlines),
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Voice snippet")
                .font(.title2.weight(.semibold))
            TextField("Voice cue", text: $trigger)
            TextEditor(text: $expansion)
                .font(.body.monospaced())
                .frame(minHeight: 130)
                .overlay {
                    RoundedRectangle(cornerRadius: 6).stroke(.separator)
                }
            TextField("App bundle identifiers, separated by commas", text: $bundleIdentifiers)
            Picker("Language", selection: $language) {
                Text("Any").tag(PersonalizationLanguage.any)
                Text("English").tag(PersonalizationLanguage.english)
                Text("French").tag(PersonalizationLanguage.french)
            }
            Toggle("Enabled", isOn: $isEnabled)
            if conflicts {
                Label("This voice cue already exists.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save(
                        VoiceSnippet(
                            id: id,
                            trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines),
                            expansion: expansion,
                            language: language,
                            bundleIdentifiers: commaSeparated(bundleIdentifiers),
                            isEnabled: isEnabled
                        )
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || expansion.isEmpty || conflicts
                )
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private func commaSeparated(_ value: String) -> [String] {
    value.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
