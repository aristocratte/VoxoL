import SwiftUI

/// What changed in each shipped version, in the words of someone using the app.
///
/// Bundled rather than fetched: the notes must match the build that is running,
/// they have to render the moment the window opens, and a release page that
/// fails to load is not a reason to hide what just changed. The feed is for
/// discovering that a version exists; this is for explaining the one installed.
enum ReleaseNotes {
    struct Item: Identifiable {
        let id = UUID()
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    struct Entry {
        let version: String
        let headline: LocalizedStringKey
        let items: [Item]
    }

    // Computed rather than stored: `LocalizedStringKey` carries no Sendable
    // guarantee, and a stored static of it is shared mutable state as far as
    // the compiler is concerned.
    static var all: [Entry] {
        [
            Entry(
                version: "0.1.3",
                headline: "Spoken French in, written French out.",
                items: [
                    Item(
                        title: "Rewrite mode",
                        detail: "Settings → Preparation → Rewrite: crutches like “du coup”, “en fait” and false starts are dropped, and the sentence is punctuated like written text. Faithful stays the default."
                    ),
                    Item(
                        title: "The built-in mic gets Apple's cleanup",
                        detail: "Noise reduction tuned for MacBook microphones, on automatically when no external mic is used. A short hint tells you when a take was too far away or too loud."
                    ),
                    Item(
                        title: "The dictionary shows what it learns",
                        detail: "A toast names each learned word, one correction is enough to get a suggestion, and a learned word is recognized immediately — not at the next launch."
                    ),
                    Item(
                        title: "Words on screen are heard better",
                        detail: "Names and terms visible in the target app guide the recognizer for that dictation."
                    ),
                ]
            ),
            Entry(
                version: "0.1.2",
                headline: "Dictation now reads like something you wrote.",
                items: [
                    Item(
                        title: "Cleanup runs on long dictations",
                        detail: "It was skipped past twenty-four words — exactly the dictations that needed it most, which is why they read like a raw transcript."
                    ),
                    Item(
                        title: "History and statistics are on by default",
                        detail: "They stayed off until you found the switch, so a fresh install showed zeroes forever. Private mode still turns everything off in one click."
                    ),
                    Item(
                        title: "Undo now has a redo",
                        detail: "Restoring the raw text used to destroy the cleaned-up version for good. You can step both ways and compare them."
                    ),
                    Item(
                        title: "Updates find you",
                        detail: "VoxoL checks for new versions on its own and shows them in the sidebar, instead of waiting for you to open Settings."
                    ),
                ]
            )
        ]
    }

    static func entry(for version: String) -> Entry? {
        all.first { $0.version == version }
    }
}

/// The card shown once, after an update, over a dimmed and blurred window.
struct ReleaseNotesCard: View {
    let entry: ReleaseNotes.Entry
    let dismiss: () -> Void

    @Environment(VoxoLTheme.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "VoxoL \(entry.version)")
                    .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(theme.cobalt)
                Text(entry.headline)
                    .font(VoxoLTypography.font(size: 22, weight: .semibold, relativeTo: .title2))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(entry.items) { item in
                    HStack(alignment: .top, spacing: 11) {
                        Circle()
                            .fill(theme.cobalt)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(
                                    VoxoLTypography.font(
                                        size: 13,
                                        weight: .semibold,
                                        relativeTo: .body
                                    )
                                )
                                .foregroundStyle(theme.ink)
                            Text(item.detail)
                                .font(VoxoLTypography.font(size: 12.5, relativeTo: .body))
                                .foregroundStyle(theme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Button(action: dismiss) {
                Text("Continue")
                    .font(VoxoLTypography.font(size: 13, weight: .semibold, relativeTo: .body))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(theme.ink)
                    .foregroundStyle(theme.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 26)
        }
        .padding(30)
        .frame(width: 460)
        .background(theme.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 40, y: 18)
    }
}
