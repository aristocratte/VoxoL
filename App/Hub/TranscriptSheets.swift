import PersonalizationKit
import SwiftUI
import TextProcessingKit

struct TranscriptEditor: View {
    @Environment(\.dismiss) private var dismiss

    let save: (String) -> Void
    @State private var text: String

    init(text: String, save: @escaping (String) -> Void) {
        self.save = save
        _text = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit transcription")
                .font(.title2.weight(.semibold))
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 180)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save(text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620)
    }
}

struct TranscriptDetailSheet: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss

    let record: TranscriptRecord
    let store: TranscriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(
                        title: "Final text",
                        trailing: {
                            Button("Copy") { store.copy(record) }
                                .buttonStyle(SignalQuietButtonStyle())
                        }
                    ) {
                        Text(verbatim: record.text)
                            .font(VoxoLTypography.font(size: 15, relativeTo: .body))
                            .foregroundStyle(theme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let raw = rawTranscript {
                        if let tokens = TranscriptDiff.tokens(raw: raw, final: record.text) {
                            section(
                                title: "What VoxoL changed",
                                trailing: { TranscriptDiffLegend() }
                            ) {
                                TranscriptDiffText(tokens: tokens)
                            }
                        }

                        section(
                            title: "Heard",
                            trailing: {
                                Button("Copy") { copyRaw(raw) }
                                    .buttonStyle(SignalQuietButtonStyle())
                            }
                        ) {
                            Text(verbatim: raw)
                                .font(VoxoLTypography.font(size: 14, relativeTo: .body))
                                .foregroundStyle(theme.secondaryInk)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        section(title: "What VoxoL changed") {
                            Text("Nothing to clean up — the transcript came out ready.")
                                .font(VoxoLTypography.font(size: 14, relativeTo: .body))
                                .foregroundStyle(theme.secondaryInk)
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
            }

            footer
        }
        .frame(width: 640, height: 520)
        .background(theme.canvas)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Result")
                    .font(VoxoLTypography.font(size: 11, weight: .semibold, relativeTo: .caption))
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(theme.secondaryInk)

                Text(verbatim: record.applicationName)
                    .font(VoxoLTypography.font(size: 22, weight: .semibold, relativeTo: .title2))
                    .foregroundStyle(theme.ink)

                Text(record.createdAt, format: .dateTime.day().month(.wide).hour().minute())
                    .font(VoxoLTypography.font(size: 12, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
            }

            Spacer(minLength: 8)

            SignalIconButton(symbol: "xmark", help: "Close") { dismiss() }
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("\(record.wordCount) words")
            Text(verbatim: "·")
            Text("\(record.wordsPerMinute) WPM")
            Text(verbatim: "·")
            Text("On this Mac")
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(SignalQuietButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
        .foregroundStyle(theme.secondaryInk)
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    /// The raw transcript is kept as the oldest revision, exactly as the store reads it.
    private var rawTranscript: String? {
        guard let raw = record.revisions.first?.text,
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                != record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return nil
        }
        return raw
    }

    private func copyRaw(_ raw: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(raw, forType: .string)
    }

    @ViewBuilder
    private func section<Content: View, Trailing: View>(
        title: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(VoxoLTypography.font(size: 11, weight: .semibold, relativeTo: .caption))
                    .textCase(.uppercase)
                    .tracking(0.9)
                    .foregroundStyle(theme.secondaryInk)
                Spacer(minLength: 12)
                trailing()
            }
            SignalCard(padding: 16) {
                content()
            }
        }
    }
}

/// A quiet text button for the detail sheet, in the same ink as the rest of the Hub.
struct SignalQuietButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoxoLTypography.font(size: 12, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(configuration.isPressed ? theme.ink : theme.cobalt)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule().fill(theme.selection.opacity(configuration.isPressed ? 0.9 : 0.55))
            )
            .contentShape(Capsule())
    }
}
