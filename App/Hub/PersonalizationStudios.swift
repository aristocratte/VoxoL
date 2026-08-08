import PersonalizationKit
import SwiftUI

private enum DemoAppProfile: String, CaseIterable, Identifiable {
    case mail
    case messages
    case documents
    case developer

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .mail:
            "Mail"
        case .messages:
            "Messages"
        case .documents:
            "Documents"
        case .developer:
            "Developer"
        }
    }

    var symbol: String {
        switch self {
        case .mail:
            "envelope"
        case .messages:
            "bubble.left.and.bubble.right"
        case .documents:
            "doc.text"
        case .developer:
            "chevron.left.forwardslash.chevron.right"
        }
    }

    var sample: LocalizedStringKey {
        switch self {
        case .mail:
            "Hello Maya, I will send the revised proposal tomorrow morning."
        case .messages:
            "Hey Maya, I'll send the update tomorrow morning"
        case .documents:
            "The revised proposal will be delivered tomorrow morning."
        case .developer:
            "Update RuntimeModelManifest before opening the pull request."
        }
    }
}

struct ContextStudioView: View {
    @Environment(VoxoLTheme.self) private var theme

    @State private var profile = DemoAppProfile.mail
    @AppStorage("voxol.contextEnabled") private var contextEnabled = true
    @AppStorage("voxol.nearbyTextEnabled") private var readsNearbyText = true
    @AppStorage("voxol.websiteDomainEnabled") private var usesWebsiteDomain = true

    var body: some View {
        StudioPage(
            eyebrow: "Context studio",
            title: "Enough context. Nothing more.",
            summary:
                "Preview how bounded local context changes formatting without reading the whole screen."
        ) {
            ShowcaseSurface {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("App profile", selection: $profile) {
                        ForEach(DemoAppProfile.allCases) { item in
                            Label(item.title, systemImage: item.symbol).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(alignment: .top, spacing: 18) {
                        contextSource(
                            symbol: profile.symbol,
                            title: "Active destination",
                            value: profile.title
                        )
                        contextSource(
                            symbol: "text.cursor",
                            title: "Nearby text",
                            value: readsNearbyText ? "Bounded" : "Off"
                        )
                        contextSource(
                            symbol: "globe",
                            title: "Website domain",
                            value: usesWebsiteDomain ? "When available" : "Off"
                        )
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Result preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.secondaryInk)
                        Text(profile.sample)
                            .font(.title3)
                            .foregroundStyle(theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            StudioSection("Context boundaries") {
                VoxoLCard {
                    VStack(spacing: 18) {
                        SettingLine(
                            title: "Application context",
                            detail: "Use only the active app and a bounded cursor window locally."
                        ) {
                            Toggle("Application context", isOn: $contextEnabled)
                                .labelsHidden()
                        }
                        Divider()
                        SettingLine(
                            title: "Nearby text",
                            detail:
                                "Read a bounded window before and after the cursor when supported."
                        ) {
                            Toggle("Nearby text", isOn: $readsNearbyText)
                                .labelsHidden()
                                .disabled(!contextEnabled)
                        }
                        Divider()
                        SettingLine(
                            title: "Website domain",
                            detail: "Recognize the active site without storing browsing history."
                        ) {
                            Toggle("Website domain", isOn: $usesWebsiteDomain)
                                .labelsHidden()
                                .disabled(!contextEnabled)
                        }
                        Divider()
                        SettingLine(
                            title: "Screen capture",
                            detail: "Never used by dictation context in the planned default."
                        ) {
                            StatusPill(title: "Off", symbol: "lock")
                        }
                    }
                }
            }

            LocalOnlyNote(
                text: "Context is ephemeral and never appears in content-free diagnostics."
            )
        }
    }

    private func contextSource(
        symbol: String,
        title: LocalizedStringKey,
        value: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.secondaryInk)
            Text(value)
                .font(.headline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DictionaryStudioView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PersonalizationStore.self) private var personalization

    @State private var search = ""
    @State private var editedEntry: DictionaryEntry?
    @State private var showsEditor = false

    private var entries: [DictionaryEntry] {
        let entries = personalization.snapshot.dictionary
        guard !search.isEmpty else {
            return entries
        }
        return entries.filter {
            $0.canonical.localizedCaseInsensitiveContains(search)
                || $0.spokenForms.contains {
                    $0.localizedCaseInsensitiveContains(search)
                }
        }
    }

    var body: some View {
        StudioPage(
            eyebrow: "Personal dictionary",
            title: "Your words, pronounced your way.",
            summary:
                "Keep names, products and technical terms accurate with explicit local entries."
        ) {
            ShowcaseSurface {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        TextField("Search dictionary", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                        Spacer()
                        Button {
                            editedEntry = nil
                            showsEditor = true
                        } label: {
                            Label("Add a word", systemImage: "plus")
                        }
                        .buttonStyle(VoxoLPrimaryButtonStyle())
                    }

                    if entries.isEmpty {
                        ContentUnavailableView(
                            "No dictionary entries",
                            systemImage: "character.book.closed",
                            description: Text("Add a name or term and the exact forms you may say.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 190)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(entries) { entry in
                                dictionaryRow(entry)
                                if entry.id != entries.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(theme.line, lineWidth: 1)
                        }
                    }

                    if let error = personalization.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(theme.warning)
                    }
                }
            }

            StudioSection("Learning policy") {
                VoxoLCard {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "hand.raised")
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Corrections are proposed, never learned silently.")
                                .font(.headline)
                            Text(
                                "Every entry has an explicit canonical form, language and app scope."
                            )
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryInk)
                        }
                    }
                }
            }

            LocalOnlyNote(text: "Dictionary matching is deterministic and stored only on this Mac.")
        }
        .sheet(isPresented: $showsEditor) {
            DictionaryEntryEditor(entry: editedEntry) { entry in
                Task {
                    if editedEntry == nil {
                        await personalization.addDictionaryEntry(entry)
                    } else {
                        await personalization.updateDictionaryEntry(entry)
                    }
                }
            }
        }
    }

    private func dictionaryRow(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: 16) {
            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { entry.isEnabled },
                    set: { enabled in
                        var updated = entry
                        updated.isEnabled = enabled
                        Task { await personalization.updateDictionaryEntry(updated) }
                    }
                )
            )
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.canonical)
                    .font(.headline)
                Text(
                    entry.spokenForms.isEmpty
                        ? entry.canonical : entry.spokenForms.joined(separator: ", ")
                )
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondaryInk)
            }
            Spacer()
            Text(
                entry.bundleIdentifiers.isEmpty
                    ? "All apps" : entry.bundleIdentifiers.joined(separator: ", ")
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryInk)
            .lineLimit(1)
            Button {
                editedEntry = entry
                showsEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                Task { await personalization.removeDictionaryEntry(id: entry.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 13)
    }
}

struct SnippetsStudioView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PersonalizationStore.self) private var personalization

    @State private var selectedID: UUID?
    @State private var editedSnippet: VoiceSnippet?
    @State private var showsEditor = false

    private var selectedSnippet: VoiceSnippet? {
        personalization.snapshot.snippets.first { $0.id == selectedID }
            ?? personalization.snapshot.snippets.first
    }

    var body: some View {
        StudioPage(
            eyebrow: "Voice snippets",
            title: "Say the cue. Insert the exact block.",
            summary:
                "Reusable text stays deterministic, local and visibly separate from generative cleanup."
        ) {
            ShowcaseSurface {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Snippet library")
                                .font(.headline)
                            Spacer()
                            Button {
                                editedSnippet = nil
                                showsEditor = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.borderless)
                        }
                        ForEach(personalization.snapshot.snippets) { snippet in
                            Button {
                                selectedID = snippet.id
                            } label: {
                                HStack {
                                    Image(systemName: "quote.bubble")
                                    Text(snippet.trigger)
                                    Spacer()
                                }
                                .padding(11)
                                .background(
                                    selectedID == snippet.id ? theme.selection : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 210)

                    Divider()

                    if let selectedSnippet {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Voice cue")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(theme.secondaryInk)
                                    Text(selectedSnippet.trigger)
                                        .font(.title3.weight(.semibold))
                                }
                                Spacer()
                                Button("Edit") {
                                    editedSnippet = selectedSnippet
                                    showsEditor = true
                                }
                                Button(role: .destructive) {
                                    Task {
                                        await personalization.removeSnippet(id: selectedSnippet.id)
                                        selectedID = nil
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Exact expansion")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.secondaryInk)
                                Text(selectedSnippet.expansion)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ContentUnavailableView(
                            "No snippets yet",
                            systemImage: "text.badge.plus",
                            description: Text("Add a voice cue and its exact expansion.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 190)
                    }
                }
            }

            StudioSection("Matching rules") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 14)],
                    spacing: 14
                ) {
                    FeatureStatusCard(
                        symbol: "textformat",
                        title: "Exact casing",
                        detail: "The saved expansion is inserted without rewriting",
                        status: "Deterministic"
                    )
                    FeatureStatusCard(
                        symbol: "exclamationmark.triangle",
                        title: "Conflict checks",
                        detail: "Duplicate cues are blocked before they are saved",
                        status: "Active"
                    )
                }
            }
        }
        .sheet(isPresented: $showsEditor) {
            SnippetEditor(
                snippet: editedSnippet,
                existingTriggers: personalization.snapshot.snippets
                    .filter { $0.id != editedSnippet?.id }
                    .map(\.trigger)
            ) { snippet in
                Task {
                    if editedSnippet == nil {
                        await personalization.addSnippet(snippet)
                    } else {
                        await personalization.updateSnippet(snippet)
                    }
                    selectedID = snippet.id
                }
            }
        }
    }
}

struct StylesStudioView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PersonalizationStore.self) private var personalization

    @AppStorage("voxol.writingProfile") private var selectedProfileRaw = WritingProfile.automatic
        .rawValue
    @State private var bundleIdentifier = ""
    @State private var domain = ""
    @State private var ruleProfile = WritingProfile.email

    private var selectedProfile: WritingProfile {
        WritingProfile(rawValue: selectedProfileRaw) ?? .automatic
    }

    var body: some View {
        StudioPage(
            eyebrow: "Styles and profiles",
            title: "The right shape for the destination.",
            summary: "Profiles adjust form and tone while protected facts and intent remain fixed."
        ) {
            ShowcaseSurface {
                VStack(alignment: .leading, spacing: 22) {
                    Picker(
                        "Style",
                        selection: Binding(
                            get: { selectedProfile },
                            set: { selectedProfileRaw = $0.rawValue }
                        )
                    ) {
                        ForEach(WritingProfile.allCases) { option in
                            Text(profileTitle(option)).tag(option)
                        }
                    }
                    .frame(maxWidth: 360)

                    HStack(alignment: .top, spacing: 16) {
                        styleSample(
                            label: "Spoken thought",
                            value:
                                "I looked at the proposal and the pricing is clear, but the timeline, we should review it once more."
                        )
                        Image(systemName: "arrow.right")
                            .foregroundStyle(theme.secondaryInk)
                            .padding(.top, 32)
                        styleSample(label: "Profile result", value: profileSample(selectedProfile))
                    }
                }
            }

            StudioSection("Automatic assignment") {
                VoxoLCard {
                    VStack(spacing: 16) {
                        HStack(spacing: 10) {
                            TextField("Bundle identifier", text: $bundleIdentifier)
                            TextField("Domain (optional)", text: $domain)
                            Picker("Profile", selection: $ruleProfile) {
                                ForEach(WritingProfile.allCases.filter { $0 != .automatic }) {
                                    Text(profileTitle($0)).tag($0)
                                }
                            }
                            Button("Add") {
                                let bundle = bundleIdentifier.trimmingCharacters(in: .whitespaces)
                                let site = domain.trimmingCharacters(in: .whitespaces)
                                Task {
                                    await personalization.setProfile(
                                        ruleProfile,
                                        for: bundle,
                                        domain: site.isEmpty ? nil : site
                                    )
                                    bundleIdentifier = ""
                                    domain = ""
                                }
                            }
                            .disabled(bundleIdentifier.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        ForEach(personalization.snapshot.applicationProfiles) { rule in
                            Divider()
                            HStack {
                                Image(systemName: "app")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.bundleIdentifier)
                                    if let domain = rule.domain {
                                        Text(domain)
                                            .font(.caption)
                                            .foregroundStyle(theme.secondaryInk)
                                    }
                                }
                                Spacer()
                                Text(profileTitle(rule.profile))
                                    .foregroundStyle(theme.secondaryInk)
                                Button(role: .destructive) {
                                    Task { await personalization.removeProfileRule(id: rule.id) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            LocalOnlyNote(
                text: "Profiles never authorize adding facts or answering dictated questions.")
        }
    }

    private func styleSample(
        label: LocalizedStringKey,
        value: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryInk)
            Text(value)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func profileTitle(_ profile: WritingProfile) -> LocalizedStringKey {
        switch profile {
        case .automatic: "Automatic"
        case .chat: "Chat"
        case .email: "Email"
        case .document: "Document"
        case .developer: "Developer"
        case .prompt: "Prompt"
        case .raw: "Raw"
        }
    }

    private func profileSample(_ profile: WritingProfile) -> LocalizedStringKey {
        switch profile {
        case .automatic:
            "VoxoL chooses the profile from the active application."
        case .chat:
            "Pricing looks good. Let’s review the timeline once more."
        case .email:
            "I reviewed the proposal. The pricing is clear, but the timeline needs one more pass."
        case .document:
            "The proposal’s pricing is clear; its timeline requires another review."
        case .developer:
            "Review the proposal timeline before merging the change."
        case .prompt:
            "Review the proposal and identify the timeline risks."
        case .raw:
            "I looked at the proposal and the pricing is clear but the timeline we should review it once more"
        }
    }
}

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

struct CommandsPreviewView: View {
    @Environment(VoxoLTheme.self) private var theme

    var body: some View {
        StudioPage(
            eyebrow: "Voice commands",
            title: "Edit with intent, after dictation is proven.",
            summary: "Commands remain a planned mode with a distinct gesture and explicit preview."
        ) {
            ComingSoonBanner(
                detail: "Commands will ship after selection safety and undo behavior are validated."
            )

            ShowcaseSurface {
                VStack(spacing: 20) {
                    HStack {
                        StatusPill(title: "Command preview", symbol: "command")
                        Spacer()
                        KeyboardShortcutBadge(keys: "⌃ ⌥ Space")
                    }

                    DemoCapsule(label: "Make this more concise", isRecording: false)

                    HStack(alignment: .top, spacing: 16) {
                        commandText(
                            label: "Selected text",
                            value:
                                "I wanted to send a quick note to let you know the build is ready."
                        )
                        Image(systemName: "arrow.right")
                            .foregroundStyle(theme.secondaryInk)
                            .padding(.top, 32)
                        commandText(label: "Preview", value: "The build is ready.")
                    }

                    HStack {
                        Button("Cancel") {}
                            .buttonStyle(VoxoLSecondaryButtonStyle())
                        Button("Apply preview") {}
                            .buttonStyle(VoxoLPrimaryButtonStyle())
                    }
                    .disabled(true)
                }
            }

            LocalOnlyNote(
                text:
                    "A command must never be mistaken for normal dictation or execute destructively without recovery."
            )
        }
    }

    private func commandText(
        label: LocalizedStringKey,
        value: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryInk)
            Text(value)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
