import AppKit
import PersonalizationKit
import SwiftUI
import UniformTypeIdentifiers

// The screens that change how VoxoL writes: the words it must spell your way, the phrases that
// expand into text, the style it writes in, and the recordings you review.

// MARK: - Dictionary

/// Words one correction short of becoming a rule, minus the ones the user ignored.
///
/// One function for the sidebar count and the Dictionary page, so the two never disagree.
enum DictionarySuggestions {
    private static let ignoredKey = "voxol.dictionarySuggestionIgnores"

    @MainActor
    static func pending(
        in personalization: PersonalizationStore, learningEnabled: Bool, privateMode: Bool
    ) -> [DictionaryEntry] {
        guard learningEnabled, !privateMode else { return [] }
        let ignored = Set(UserDefaults.standard.stringArray(forKey: ignoredKey) ?? [])
        return DictionaryLearning.pendingSuggestions(
            from: personalization.corrections,
            existing: personalization.snapshot.dictionary
        )
        .filter { !ignored.contains(DictionaryLearning.suggestionKey($0)) }
    }

    static func ignore(_ entry: DictionaryEntry) {
        var ignored = UserDefaults.standard.stringArray(forKey: ignoredKey) ?? []
        ignored.append(DictionaryLearning.suggestionKey(entry))
        UserDefaults.standard.set(ignored, forKey: ignoredKey)
    }
}

private enum DictionaryFilter: Hashable, CaseIterable {
    case all
    case added
    case learned

    func includes(_ entry: DictionaryEntry) -> Bool {
        switch self {
        case .all: true
        case .added: entry.origin == .manual
        case .learned: entry.origin == .learned
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .added: "Added"
        case .learned: "Learned"
        }
    }
}

/// Identifies a sheet that edits an existing item or creates a new one.
private enum EditorTarget<Item: Identifiable>: Identifiable {
    case new
    case existing(Item)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let item): "\(item.id)"
        }
    }

    var item: Item? {
        if case .existing(let item) = self { return item }
        return nil
    }
}

struct DictionaryView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PersonalizationStore.self) private var personalization

    @AppStorage("voxol.learningEnabled") private var learningEnabled = true
    @AppStorage("voxol.privateMode") private var privateMode = false

    @State private var filter = DictionaryFilter.all
    @State private var editing: EditorTarget<DictionaryEntry>?
    /// Bumped when a suggestion is ignored: the ignore list lives in UserDefaults, which SwiftUI
    /// does not observe.
    @State private var ignoredRevision = 0

    var body: some View {
        let entries = personalization.snapshot.dictionary
        HubPage {
            HubPageHeader(title: "Dictionary", meta: Text("\(entries.count) words")) {
                Button {
                    editing = .new
                } label: {
                    Label("Add a word", systemImage: "plus")
                }
                .buttonStyle(HubButtonStyle(kind: .primary))
            }

            suggestionsCard
                .id(ignoredRevision)

            if entries.isEmpty {
                HubDitherCard(art: "DitherDunes") {
                    Text("No word yet. Add the names and terms VoxoL must write exactly.")
                        .font(VoxoLTypography.font(size: 13))
                        .foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 64, alignment: .leading)
                }
                .padding(.top, 20)
            } else {
                HubSegmented(options: DictionaryFilter.allCases, selection: $filter) { option in
                    Text(option.title) + Text(verbatim: "  \(entries.filter(option.includes).count)")
                }
                .padding(.top, 24)
                .padding(.bottom, 8)

                LazyVStack(spacing: 2) {
                    ForEach(entries.filter(filter.includes)) { entry in
                        DictionaryRow(entry: entry) { editing = .existing(entry) }
                    }
                }
            }
        }
        .sheet(item: $editing) { target in
            DictionaryEntryEditor(entry: target.item) { saved in
                Task {
                    if target.item == nil {
                        await personalization.addDictionaryEntry(saved)
                    } else {
                        await personalization.updateDictionaryEntry(saved)
                    }
                }
            }
            .environment(theme)
        }
    }

    @ViewBuilder
    private var suggestionsCard: some View {
        let suggestions = DictionarySuggestions.pending(
            in: personalization, learningEnabled: learningEnabled, privateMode: privateMode)
        if !suggestions.isEmpty {
            HubDitherCard(art: "DitherDunes") {
                VStack(alignment: .leading, spacing: 0) {
                    Text("To confirm")
                        .font(VoxoLTypography.font(size: 15, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .padding(.bottom, 4)
                    ForEach(suggestions) { suggestion in
                        HStack(spacing: 8) {
                            Text(verbatim: suggestion.canonical)
                                .font(VoxoLTypography.font(size: 13, weight: .medium))
                                .foregroundStyle(theme.ink)
                            Text("instead of “\(suggestion.spokenForms.first ?? "")”")
                                .font(VoxoLTypography.font(size: 13))
                                .foregroundStyle(theme.secondaryInk)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Button("Add") {
                                Task { await personalization.addDictionaryEntry(suggestion) }
                            }
                            .buttonStyle(HubButtonStyle(kind: .onWell))
                            Button("Ignore") {
                                DictionarySuggestions.ignore(suggestion)
                                ignoredRevision += 1
                            }
                            .buttonStyle(HubButtonStyle(kind: .ghost))
                        }
                        .frame(minHeight: 40)
                    }
                }
            }
            .padding(.top, 20)
        }
    }
}

private struct DictionaryRow: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PersonalizationStore.self) private var personalization

    let entry: DictionaryEntry
    let edit: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.canonical)
                    .font(VoxoLTypography.font(size: 14, weight: .medium))
                    .foregroundStyle(entry.isEnabled ? theme.ink : theme.secondaryInk)
                heard
                    .font(VoxoLTypography.font(size: 12))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if !entry.isEnabled {
                Text("Paused")
                    .font(VoxoLTypography.font(size: 12))
                    .foregroundStyle(theme.secondaryInk)
            } else if entry.origin == .learned {
                Text("Learned")
                    .font(VoxoLTypography.font(size: 12))
                    .foregroundStyle(theme.secondaryInk)
            }
            ScopeView(bundleIdentifiers: entry.bundleIdentifiers)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 52)
        .hubRowHover(hovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit", action: edit)
            Button("Delete", role: .destructive) {
                Task { await personalization.removeDictionaryEntry(id: entry.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Edit this dictionary entry"))
    }

    private var heard: Text {
        entry.spokenForms.isEmpty
            ? Text("Exact form")
            : Text("heard “\(entry.spokenForms.joined(separator: ", "))”")
    }
}

/// Where an entry applies: everywhere, or the icons of the apps it is limited to.
private struct ScopeView: View {
    @Environment(VoxoLTheme.self) private var theme

    let bundleIdentifiers: [String]

    var body: some View {
        if bundleIdentifiers.isEmpty {
            Text("Everywhere")
                .font(VoxoLTypography.font(size: 12))
                .foregroundStyle(theme.secondaryInk)
        } else {
            HStack(spacing: 4) {
                ForEach(bundleIdentifiers.prefix(4), id: \.self) { bundle in
                    HubAppIcon(bundleIdentifier: bundle, size: 16)
                        .help(ApplicationIconCache.name(forBundleIdentifier: bundle) ?? bundle)
                }
            }
        }
    }
}

// MARK: - Voice shortcuts

struct SnippetsView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PersonalizationStore.self) private var personalization

    @State private var editing: EditorTarget<VoiceSnippet>?

    var body: some View {
        let snippets = personalization.snapshot.snippets
        HubPage {
            HubPageHeader(title: "Shortcuts", meta: Text("\(snippets.count) shortcuts")) {
                Button {
                    editing = .new
                } label: {
                    Label("Add a shortcut", systemImage: "plus")
                }
                .buttonStyle(HubButtonStyle(kind: .primary))
            }

            if snippets.isEmpty {
                HubDitherCard(art: "DitherDunes") {
                    Text("Say a short phrase to insert a longer text you save.")
                        .font(VoxoLTypography.font(size: 13))
                        .foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 64, alignment: .leading)
                }
                .padding(.top, 20)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(snippets) { snippet in
                        SnippetRow(snippet: snippet) { editing = .existing(snippet) }
                    }
                }
                .padding(.top, 16)
            }
        }
        .sheet(item: $editing) { target in
            SnippetEditor(
                snippet: target.item,
                existingTriggers: snippets.filter { $0.id != target.item?.id }.map(\.trigger)
            ) { saved in
                Task {
                    if target.item == nil {
                        await personalization.addSnippet(saved)
                    } else {
                        await personalization.updateSnippet(saved)
                    }
                }
            }
            .environment(theme)
        }
    }
}

private struct SnippetRow: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PersonalizationStore.self) private var personalization

    let snippet: VoiceSnippet
    let edit: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(snippet.trigger)”")
                    .font(VoxoLTypography.font(size: 14, weight: .medium))
                    .foregroundStyle(snippet.isEnabled ? theme.ink : theme.secondaryInk)
                    .lineLimit(1)
                if snippet.isEnabled {
                    scope
                } else {
                    Text("Paused")
                        .font(VoxoLTypography.font(size: 12))
                        .foregroundStyle(theme.secondaryInk)
                }
            }
            .frame(width: 200, alignment: .leading)

            Text(verbatim: snippet.expansion)
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.secondaryInk)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(
                "Active",
                isOn: Binding(
                    get: { snippet.isEnabled },
                    set: { enabled in
                        var updated = snippet
                        updated.isEnabled = enabled
                        Task { await personalization.updateSnippet(updated) }
                    }
                )
            )
            .toggleStyle(HubSwitchStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .hubRowHover(hovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit", action: edit)
            Button("Delete", role: .destructive) {
                Task { await personalization.removeSnippet(id: snippet.id) }
            }
        }
    }

    @ViewBuilder
    private var scope: some View {
        if snippet.bundleIdentifiers.isEmpty {
            Text("Everywhere")
                .font(VoxoLTypography.font(size: 12))
                .foregroundStyle(theme.secondaryInk)
        } else {
            Text(
                verbatim: snippet.bundleIdentifiers
                    .map { ApplicationIconCache.name(forBundleIdentifier: $0) ?? $0 }
                    .joined(separator: ", ")
            )
            .font(VoxoLTypography.font(size: 12))
            .foregroundStyle(theme.secondaryInk)
            .lineLimit(1)
        }
    }
}

// MARK: - Style

extension WritingProfile {
    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .chat: "Chat"
        case .email: "Email"
        case .document: "Document"
        case .developer: "Developer"
        case .prompt: "Prompt"
        case .raw: "Raw"
        }
    }

    /// The raw sentence every example below is written from.
    var exampleResource: LocalizedStringResource {
        "uh we move the check-in thursday no thursday 9"
    }

    /// The same dictation, as this profile writes it.
    var example: LocalizedStringKey {
        switch self {
        case .automatic: "Picks one of the styles below from the app in front of you."
        case .chat: "works for me, thursday 9?"
        case .email: "Hello, could we move it to Thursday at 9 a.m.? Best,"
        case .document: "The check-in is moved to Thursday at 9 a.m."
        case .developer: "Rename `authToken` to `sessionToken` in src/auth.ts."
        case .prompt: "Move the check-in to Thursday 9 a.m. and tell the team."
        case .raw: "uh we move the check-in thursday no thursday 9"
        }
    }
}

struct StyleView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.locale) private var locale
    @Environment(PersonalizationStore.self) private var personalization

    @AppStorage("voxol.writingProfile") private var writingProfile = WritingProfile.automatic
        .rawValue

    @State private var addingRule = false

    var body: some View {
        HubPage {
            HubPageHeader(title: "Style")

            HubSectionHeader(title: "By default") {
                (Text("Heard") + Text(verbatim: " ")
                    + Text("“\(String(WritingProfile.raw.exampleResource, in: locale))”"))
                    .lineLimit(1)
            }
            VStack(spacing: 2) {
                ForEach(WritingProfile.allCases) { profile in
                    profileRow(profile)
                }
            }

            HubSectionHeader(title: "By application") {
                Button {
                    addingRule = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(HubButtonStyle(kind: .ghost))
            }
            let rules = personalization.snapshot.applicationProfiles
            if rules.isEmpty {
                Text("No rule yet. The default style applies everywhere.")
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.secondaryInk)
                    .padding(.horizontal, 10)
            } else {
                VStack(spacing: 2) {
                    ForEach(rules) { rule in
                        RuleRow(rule: rule)
                    }
                }
            }
        }
        .sheet(isPresented: $addingRule) {
            ProfileRuleEditor { bundle, domain, profile in
                Task { await personalization.setProfile(profile, for: bundle, domain: domain) }
            }
            .environment(theme)
        }
    }

    private func profileRow(_ profile: WritingProfile) -> some View {
        let selected = writingProfile == profile.rawValue
        return Button {
            withAnimation(EditorialMotion.soft) { writingProfile = profile.rawValue }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(selected ? theme.ink : theme.selection)
                    .frame(width: 16, height: 16)
                    .overlay {
                        if selected { Circle().fill(.white).frame(width: 6, height: 6) }
                    }
                Text(profile.title)
                    .font(VoxoLTypography.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .frame(width: 112, alignment: .leading)
                Text(profile.example)
                    .font(VoxoLTypography.serif(size: 15))
                    .foregroundStyle(selected ? theme.ink : theme.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .hubRowHover(false, selected: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct RuleRow: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(PersonalizationStore.self) private var personalization

    let rule: ApplicationProfileRule

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            HubAppIcon(bundleIdentifier: rule.bundleIdentifier)
            HStack(spacing: 6) {
                Text(
                    verbatim: ApplicationIconCache.name(forBundleIdentifier: rule.bundleIdentifier)
                        ?? rule.bundleIdentifier
                )
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.ink)
                if let domain = rule.domain {
                    Text(verbatim: domain)
                        .font(VoxoLTypography.font(size: 12))
                        .foregroundStyle(theme.secondaryInk)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            if hovering {
                Button {
                    Task { await personalization.removeProfileRule(id: rule.id) }
                } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(HubButtonStyle(kind: .ghost))
                .help("Delete")
            }
            Menu {
                ForEach(WritingProfile.allCases.filter { $0 != .automatic }) { profile in
                    Button {
                        Task {
                            await personalization.setProfile(
                                profile, for: rule.bundleIdentifier, domain: rule.domain)
                        }
                    } label: {
                        Text(profile.title)
                    }
                }
            } label: {
                Text(rule.profile.title)
                    .font(VoxoLTypography.font(size: 13, weight: .medium))
                    .foregroundStyle(theme.ink)
            }
            .menuStyle(.borderlessButton)
            .tint(theme.ink)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(theme.well, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .hubRowHover(hovering)
        .onHover { hovering = $0 }
    }
}

/// Adds a style rule: pick the app from disk rather than typing its bundle identifier.
private struct ProfileRuleEditor: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    let save: (String, String?, WritingProfile) -> Void

    @State private var bundleIdentifier = ""
    @State private var domain = ""
    @State private var profile = WritingProfile.email

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New style rule")
                .font(VoxoLTypography.font(size: 17, weight: .semibold))
                .foregroundStyle(theme.ink)

            HubPanel {
                HubField(title: "Application") {
                    Button {
                        chooseApplication()
                    } label: {
                        HStack(spacing: 6) {
                            if !bundleIdentifier.isEmpty {
                                HubAppIcon(bundleIdentifier: bundleIdentifier, size: 16)
                            }
                            Text(
                                verbatim: ApplicationIconCache.name(
                                    forBundleIdentifier: bundleIdentifier)
                                    ?? String("Choose…", in: locale)
                            )
                        }
                    }
                    .buttonStyle(HubButtonStyle(kind: .onWell))
                }
                HubField(title: "Website") {
                    TextField("Optional, e.g. chatgpt.com", text: $domain)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                HubField(title: "Style") {
                    Picker("Style", selection: $profile) {
                        ForEach(WritingProfile.allCases.filter { $0 != .automatic }) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.top, 16)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(HubButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let site = domain.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(bundleIdentifier, site.isEmpty ? nil : site, profile)
                    dismiss()
                }
                .buttonStyle(HubButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(bundleIdentifier.isEmpty)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 480)
        .background(theme.surface)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
            let identifier = Bundle(url: url)?.bundleIdentifier
        else { return }
        bundleIdentifier = identifier
    }
}

// MARK: - Review

struct ReviewView: View {
    var body: some View {
        TrainingStudioView()
            .padding(.horizontal, 32)
            .padding(.top, 32)
            .padding(.bottom, 24)
    }
}
