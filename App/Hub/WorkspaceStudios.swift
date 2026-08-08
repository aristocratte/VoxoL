import Foundation

/// Says what "instant" actually costs, in one place for both settings screens.
///
/// Nobody guesses that instant mode means a dictation past about twenty-four
/// words gets no list formatting and no rephrasing. The measured price of
/// turning it off is near one second.
let instantModeExplanationText = """
    Skips model cleanup past about 24 words, which is where list formatting \
    and rephrasing happen. Turn it off to clean everything: measured cost is \
    roughly one second on a long dictation.
    """

import SwiftUI

enum DictationCleanupMode: String, CaseIterable, Identifiable {
    case faithful
    case raw

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .faithful:
            "Faithful"
        case .raw:
            "Raw"
        }
    }
}

enum ActivationMode: String, CaseIterable, Identifiable {
    case hold
    case toggle

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .hold:
            "Hold"
        case .toggle:
            "Toggle"
        }
    }
}

struct SignalDictationView: View {
    /// Says what "instant" actually costs.
    ///
    /// The label alone hid the trade: nobody guesses that instant mode means a
    /// dictation past about twenty-four words gets no list formatting and no
    /// rephrasing. The measured price of turning it off is near one second.
    private var instantModeDetail: String {
        fastPathEnabled
            ? "Long dictations skip model cleanup — no list formatting."
            : "Every dictation is cleaned, about a second more on long ones."
    }

    @Environment(VoxoLTheme.self) private var theme
    @Environment(DictationSessionCoordinator.self) private var dictationSession

    let previewCapsule: () -> Void

    @AppStorage("voxol.activationMode") private var activationMode = ActivationMode.hold
    @AppStorage("voxol.dictationLanguage") private var dictationLanguage =
        DictationLanguagePreference.preferred
    @AppStorage("voxol.cleanupMode") private var cleanup = DictationCleanupMode.faithful
    @AppStorage("voxol.removeFillers") private var removesFillers = true
    @AppStorage("voxol.automaticLists") private var automaticLists = true
    @AppStorage("voxol.fastPathEnabled") private var fastPathEnabled = true
    @AppStorage("voxol.streamingEnabled") private var streamingEnabled = true
    @AppStorage("voxol.pipelineInspectorEnabled") private var pipelineInspectorEnabled = false
    @AppStorage("voxol.privateMode") private var privateMode = false

    @State private var showsAdvancedSettings = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760 || geometry.size.height < 600

            VStack(alignment: .leading, spacing: compact ? 13 : 18) {
                SignalPageHeader(
                    eyebrow: "Dictation",
                    title: "Your voice, ready everywhere.",
                    summary: "Choose a language, then use ⌥ Space in any app."
                ) {
                    languagePicker
                        .frame(width: compact ? 236 : 284)
                }

                dictationStage(compact: compact)
                    .frame(maxHeight: .infinity)

                HStack(spacing: compact ? 9 : 12) {
                    activationTile(compact: compact)
                    cleanupTile(compact: compact)
                    advancedTile(compact: compact)
                }
                .frame(height: compact ? 72 : 84)
            }
            .padding(.horizontal, compact ? 24 : 34)
            .padding(.vertical, compact ? 21 : 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: privateMode) { _, enabled in
            guard enabled else {
                return
            }
            pipelineInspectorEnabled = false
            dictationSession.clearPipelineTraces()
        }
    }

    private var languagePicker: some View {
        Picker("Spoken language", selection: $dictationLanguage) {
            ForEach(DictationLanguagePreference.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.large)
    }

    private func dictationStage(compact: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    theme.surface,
                    theme.selection.opacity(0.52),
                    theme.cobaltSoft.opacity(0.2),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HubDitherField(mode: activeSignalMode)

            VStack(spacing: compact ? 14 : 20) {
                Spacer(minLength: 0)

                Button(action: previewCapsule) {
                    HStack(spacing: 11) {
                        PrototypeWaveform(
                            tone: runtimeColor,
                            height: compact ? 23 : 27
                        )
                        Text(runtimeCapsuleLabel)
                            .font(
                                VoxoLTypography.font(
                                    size: compact ? 13 : 14,
                                    weight: .semibold,
                                    relativeTo: .body
                                )
                            )
                            .foregroundStyle(theme.ink)
                        KeyboardShortcutBadge(keys: isRuntimeActive ? "esc" : "⌥ Space")
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 9)
                    .frame(minHeight: compact ? 48 : 54)
                    .background(theme.surface.opacity(0.96))
                    .clipShape(Capsule())
                    .overlay { Capsule().stroke(theme.line.opacity(0.84), lineWidth: 1) }
                    .shadow(color: theme.ink.opacity(0.09), radius: 18, y: 8)
                }
                .buttonStyle(SignalPressButtonStyle())
                .help("Preview the floating capsule")

                if !dictationSession.livePartialTranscript.isEmpty {
                    Text(dictationSession.livePartialTranscript)
                        .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                        .foregroundStyle(theme.cobalt)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(theme.surface.opacity(0.88))
                        .clipShape(Capsule())
                        .transition(.opacity)
                }

                HStack(alignment: .top, spacing: compact ? 8 : 12) {
                    comparisonPanel(
                        eyebrow: rawIsExample ? "Heard · example" : "Heard",
                        text: rawText,
                        tint: theme.coralSoft.opacity(0.64),
                        compact: compact
                    )
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.secondaryInk)
                        .frame(width: compact ? 22 : 28)
                    comparisonPanel(
                        eyebrow: rawIsExample ? "Ready to insert · example" : "Ready to insert",
                        text: finalText,
                        tint: theme.cobaltSoft.opacity(0.6),
                        compact: compact
                    )
                }
                .frame(height: compact ? 118 : 142)
                .padding(.horizontal, compact ? 16 : 24)
                .padding(.bottom, compact ? 16 : 23)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.line.opacity(0.75), lineWidth: 1)
        }
    }

    private func comparisonPanel(
        eyebrow: LocalizedStringKey,
        text: String,
        tint: Color,
        compact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SignalEyebrow(title: eyebrow)
            Text(verbatim: text)
                .font(
                    VoxoLTypography.font(
                        size: compact ? 13.5 : 15.5,
                        weight: .medium,
                        relativeTo: .body
                    )
                )
                .foregroundStyle(theme.ink)
                .lineLimit(compact ? 3 : 4)
                .textSelection(.enabled)
        }
        .padding(compact ? 14 : 17)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.line.opacity(0.78), lineWidth: 1)
        }
    }

    private func activationTile(compact: Bool) -> some View {
        Menu {
            ForEach(ActivationMode.allCases) { mode in
                Button {
                    activationMode = mode
                } label: {
                    if activationMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            settingTile(
                symbol: "waveform",
                eyebrow: "Activation",
                value: activationMode == .hold ? "Hold to speak" : "Press to toggle",
                compact: compact
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(SignalPressButtonStyle())
    }

    private func cleanupTile(compact: Bool) -> some View {
        Menu {
            ForEach(DictationCleanupMode.allCases) { mode in
                Button {
                    cleanup = mode
                } label: {
                    if cleanup == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            settingTile(
                symbol: "textformat",
                eyebrow: "Preparation",
                value: cleanup == .faithful ? "Faithful" : "Raw",
                compact: compact
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(SignalPressButtonStyle())
    }

    private func advancedTile(compact: Bool) -> some View {
        Button {
            showsAdvancedSettings.toggle()
        } label: {
            settingTile(
                symbol: "slider.horizontal.3",
                eyebrow: "Live settings",
                value: "Fine tune",
                compact: compact
            )
        }
        .buttonStyle(SignalPressButtonStyle())
        .popover(isPresented: $showsAdvancedSettings, arrowEdge: .bottom) {
            advancedSettings
        }
    }

    private func settingTile(
        symbol: String,
        eyebrow: LocalizedStringKey,
        value: LocalizedStringKey,
        compact: Bool
    ) -> some View {
        HStack(spacing: compact ? 9 : 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.ink)
                .frame(width: compact ? 34 : 40, height: compact ? 34 : 40)
                .background(theme.selection.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(eyebrow)
                    .font(VoxoLTypography.font(size: 10, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                Text(value)
                    .font(
                        VoxoLTypography.font(
                            size: compact ? 12 : 13,
                            weight: .semibold,
                            relativeTo: .subheadline
                        )
                    )
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 3)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.secondaryInk)
        }
        .padding(.horizontal, compact ? 11 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.line.opacity(0.82), lineWidth: 1)
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Live dictation settings")
                .font(VoxoLTypography.font(size: 17, weight: .semibold, relativeTo: .headline))

            Toggle("Remove fillers", isOn: $removesFillers)
            Toggle("Automatic lists", isOn: $automaticLists)
            Toggle("Instant mode", isOn: $fastPathEnabled)
            Text(instantModeDetail)
                .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
            Toggle("Stable live transcript", isOn: $streamingEnabled)
                .disabled(dictationLanguage != .automatic)
            Toggle("Pipeline inspector", isOn: pipelineInspectorBinding)
                .disabled(privateMode)

            Text(dictationLanguageDetail)
                .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
        }
        .toggleStyle(.switch)
        .padding(20)
        .frame(width: 310)
        .background(theme.surface)
    }

    private var pipelineInspectorBinding: Binding<Bool> {
        Binding(
            get: { pipelineInspectorEnabled },
            set: { enabled in
                pipelineInspectorEnabled = enabled
                if !enabled {
                    dictationSession.clearPipelineTraces()
                }
            }
        )
    }

    private var latestTrace: DictationPipelineTrace? {
        dictationSession.pipelineTraces.first
    }

    private var rawIsExample: Bool {
        latestTrace == nil
    }

    private var rawText: String {
        latestTrace?.rawTranscript
            ?? String(localized: "Um, send it Tuesday—no, Wednesday morning.")
    }

    private var finalText: String {
        guard cleanup == .faithful else {
            return rawText
        }
        return latestTrace?.finalText ?? String(localized: "Send it Wednesday morning.")
    }

    private var isRuntimeActive: Bool {
        switch dictationSession.state {
        case .listening, .speechDetected, .transcribing, .polishing, .inserting:
            true
        default:
            false
        }
    }

    private var activeSignalMode: HubSignalMode {
        switch dictationSession.state {
        case .listening, .speechDetected:
            .voice
        case .transcribing, .polishing, .inserting:
            .processing
        default:
            .idle
        }
    }

    private var runtimeCapsuleLabel: LocalizedStringKey {
        switch dictationSession.state {
        case .waitingForInputMonitoring: "Finish permission setup"
        case .ready: "Ready to listen"
        case .listening: "Listening"
        case .speechDetected: "Voice detected"
        case .transcribing: "Transcribing"
        case .polishing: "Preparing text"
        case .inserting: "Inserting"
        case .captureNeedsModel: "Local model unavailable"
        case .noSpeech: "No speech heard"
        case .insertionSucceeded: "Inserted"
        case .copiedForManualPaste: "Copied · press ⌘V"
        case .failed: "Check permissions"
        }
    }

    private var runtimeColor: Color {
        switch dictationSession.state {
        case .listening, .speechDetected:
            theme.coral
        case .transcribing, .polishing, .inserting:
            theme.cobalt
        case .insertionSucceeded:
            theme.success
        case .failed, .captureNeedsModel, .waitingForInputMonitoring:
            theme.warning
        default:
            theme.ink
        }
    }

    private var dictationLanguageDetail: LocalizedStringKey {
        switch dictationLanguage {
        case .automatic: "Each dictation is detected automatically with Parakeet."
        case .french: "Recognition and preparation are locked to French."
        case .english: "Recognition and preparation are locked to English."
        }
    }
}

private enum MeetingPreviewTab: String, CaseIterable, Identifiable {
    case summary
    case decisions
    case actions
    case transcript

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .summary: "Summary"
        case .decisions: "Decisions"
        case .actions: "Actions"
        case .transcript: "Transcript"
        }
    }

    var count: Int? {
        switch self {
        case .decisions: 2
        case .actions: 3
        default: nil
        }
    }
}

struct SignalMeetingsView: View {
    @Environment(VoxoLTheme.self) private var theme

    @State private var selectedTab = MeetingPreviewTab.summary

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760 || geometry.size.height < 600

            VStack(alignment: .leading, spacing: compact ? 12 : 17) {
                SignalPageHeader(
                    eyebrow: "Meetings · coming soon",
                    title: "Your meetings, summarized on this Mac.",
                    summary:
                        "The future space is visible now, without pretending unavailable capture works."
                ) {
                    SignalStatusChip(
                        title: "Local capture",
                        color: theme.secondaryInk,
                        symbol: "lock"
                    )
                }

                meetingPreview(compact: compact)
                    .frame(maxHeight: .infinity)

                futureFlow(compact: compact)
                    .frame(height: compact ? 48 : 56)
            }
            .padding(.horizontal, compact ? 24 : 34)
            .padding(.vertical, compact ? 21 : 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func meetingPreview(compact: Bool) -> some View {
        SignalCard(padding: compact ? 15 : 19, cornerRadius: 21) {
            VStack(alignment: .leading, spacing: compact ? 10 : 13) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        SignalEyebrow(title: "Result preview")
                        Text("Product check-in")
                            .font(
                                VoxoLTypography.font(
                                    size: compact ? 18 : 21,
                                    weight: .semibold,
                                    relativeTo: .title3
                                )
                            )
                            .foregroundStyle(theme.ink)
                        Text("Google Meet · 42 min · Example, not recorded")
                            .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                            .foregroundStyle(theme.secondaryInk)
                    }
                    Spacer()
                    SignalStatusChip(title: "42:18", color: theme.coral)
                }

                ZStack {
                    theme.selection.opacity(0.58)
                    HubDitherField(mode: .meeting)
                    HStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { index in
                            HStack(spacing: 0) {
                                Circle()
                                    .fill(index == 3 ? theme.coral : theme.ink)
                                    .frame(width: 6, height: 6)
                                if index < 3 {
                                    Rectangle()
                                        .fill(theme.line)
                                        .frame(height: 1)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(height: compact ? 58 : 74)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 5) {
                    ForEach(MeetingPreviewTab.allCases) { tab in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedTab = tab
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(tab.title)
                                if let count = tab.count {
                                    Text(verbatim: count.formatted())
                                        .font(
                                            VoxoLTypography.font(
                                                size: 9,
                                                weight: .semibold,
                                                relativeTo: .caption
                                            )
                                        )
                                        .frame(width: 20, height: 20)
                                        .background(theme.selection)
                                        .clipShape(Circle())
                                }
                            }
                            .font(
                                VoxoLTypography.font(
                                    size: compact ? 11 : 12.5,
                                    weight: .semibold,
                                    relativeTo: .subheadline
                                )
                            )
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, compact ? 9 : 12)
                            .frame(minHeight: 38)
                            .background(selectedTab == tab ? theme.selection : .clear)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(SignalPressButtonStyle())
                    }
                }

                meetingOutput(compact: compact)
                    .frame(maxHeight: .infinity)
                    .id(selectedTab)
                    .transition(.opacity.combined(with: .offset(y: 5)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func meetingOutput(compact: Bool) -> some View {
        switch selectedTab {
        case .summary:
            meetingColumns(
                [
                    MeetingPreviewItem(
                        index: "01",
                        title: "Dictation remains the priority.",
                        detail: "Quality and latency are validated before long-form capture."
                    ),
                    MeetingPreviewItem(
                        index: "02",
                        title: "Processing remains entirely local.",
                        detail: "Summaries, decisions and actions keep the same privacy promise."
                    ),
                ],
                compact: compact
            )
        case .decisions:
            meetingColumns(
                [
                    MeetingPreviewItem(
                        index: "01",
                        title: "Validate dictation before long capture.",
                        detail: "Meeting mode opens only after quality and performance gates."
                    ),
                    MeetingPreviewItem(
                        index: "02",
                        title: "Do not promise speaker attribution.",
                        detail: "The first release stays honest about available capabilities."
                    ),
                ],
                compact: compact
            )
        case .actions:
            meetingColumns(
                [
                    MeetingPreviewItem(
                        index: "01",
                        title: "Test macOS source selection.",
                        detail: "Owner: product · after dictation validation."
                    ),
                    MeetingPreviewItem(
                        index: "02",
                        title: "Measure long-session summaries.",
                        detail: "Owner: models · latency gate to define."
                    ),
                ],
                compact: compact
            )
        case .transcript:
            VStack(alignment: .leading, spacing: 8) {
                transcriptLine(
                    time: "10:04",
                    text: "The priority is making dictation excellent before expanding capture."
                )
                transcriptLine(
                    time: "10:05",
                    text: "The first meeting mode must stay local and clear about its limits."
                )
            }
        }
    }

    private func meetingColumns(
        _ items: [MeetingPreviewItem],
        compact: Bool
    ) -> some View {
        HStack(spacing: compact ? 9 : 12) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 11) {
                    Text(verbatim: item.index)
                        .font(
                            VoxoLTypography.font(
                                size: 11, weight: .semibold, relativeTo: .caption)
                        )
                        .foregroundStyle(theme.cobalt)
                        .frame(width: 34, height: 34)
                        .background(theme.cobaltSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(
                                VoxoLTypography.font(
                                    size: compact ? 12 : 13.5,
                                    weight: .semibold,
                                    relativeTo: .subheadline
                                )
                            )
                            .foregroundStyle(theme.ink)
                            .lineLimit(2)
                        Text(item.detail)
                            .font(
                                VoxoLTypography.font(
                                    size: compact ? 9.5 : 10.5,
                                    relativeTo: .caption
                                )
                            )
                            .foregroundStyle(theme.secondaryInk)
                            .lineLimit(2)
                    }
                }
                .padding(compact ? 10 : 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(theme.selection.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func transcriptLine(time: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text(verbatim: time)
                .font(VoxoLTypography.font(size: 10.5, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(theme.cobalt)
                .monospacedDigit()
            Text(text)
                .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                .foregroundStyle(theme.ink)
                .lineLimit(2)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.selection.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func futureFlow(compact: Bool) -> some View {
        HStack(spacing: compact ? 7 : 11) {
            futureStep(index: "1", title: "Choose a source", compact: compact)
            Divider().frame(height: 1)
            futureStep(index: "2", title: "Capture locally", compact: compact)
            Divider().frame(height: 1)
            futureStep(index: "3", title: "Review the recap", compact: compact)
        }
        .padding(.horizontal, compact ? 12 : 16)
        .background(theme.selection.opacity(0.56))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func futureStep(
        index: String,
        title: LocalizedStringKey,
        compact: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Text(verbatim: index)
                .font(VoxoLTypography.font(size: 10, weight: .semibold, relativeTo: .caption))
                .frame(width: 26, height: 26)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(
                    VoxoLTypography.font(
                        size: compact ? 10.5 : 12,
                        weight: .semibold,
                        relativeTo: .caption
                    )
                )
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct MeetingPreviewItem: Identifiable {
        let index: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey

        var id: String { index }
    }
}

struct DictationStudioView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(DictationSessionCoordinator.self) private var dictationSession

    let previewCapsule: () -> Void

    @AppStorage("voxol.activationMode") private var activationMode = ActivationMode.hold
    @AppStorage("voxol.dictationLanguage") private var dictationLanguage =
        DictationLanguagePreference.preferred
    @AppStorage("voxol.cleanupMode") private var cleanup = DictationCleanupMode.faithful
    @AppStorage("voxol.removeFillers") private var removesFillers = true
    @AppStorage("voxol.automaticLists") private var automaticLists = true
    @AppStorage("voxol.fastPathEnabled") private var fastPathEnabled = true
    @AppStorage("voxol.streamingEnabled") private var streamingEnabled = true
    @AppStorage("voxol.pipelineInspectorEnabled") private var pipelineInspectorEnabled = false
    @AppStorage("voxol.privateMode") private var privateMode = false

    var body: some View {
        StudioPage(
            eyebrow: "Dictation studio",
            title: "Natural speech. Faithful text.",
            summary: "Test the interaction and choose the few defaults that shape every dictation."
        ) {
            ShowcaseSurface {
                VStack(spacing: 24) {
                    HStack {
                        StatusPill(
                            title: runtimeStatusTitle,
                            symbol: runtimeStatusSymbol,
                            tone: runtimeStatusTone
                        )
                        Spacer()
                        KeyboardShortcutBadge(keys: "⌥ Space")
                    }

                    languageSelector

                    DemoCapsule(
                        label: runtimeCapsuleLabel,
                        isRecording: isActivelyCapturing,
                        shortcut: isActivelyCapturing ? "release" : "⌥ Space",
                        indicatorTone: runtimeStatusTone
                    )

                    if !dictationSession.livePartialTranscript.isEmpty {
                        Text(dictationSession.livePartialTranscript)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryInk)
                            .lineLimit(2)
                            .frame(maxWidth: 520)
                            .transition(.opacity)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        transcriptColumn(
                            label: "Spoken",
                            text: "Um, let's ship Tuesday—actually Wednesday morning."
                        )
                        Image(systemName: "arrow.right")
                            .foregroundStyle(theme.secondaryInk)
                            .padding(.top, 30)
                        transcriptColumn(
                            label: "Ready",
                            text: cleanup == .faithful
                                ? "Let's ship Wednesday morning."
                                : "Um, let's ship Tuesday—actually Wednesday morning."
                        )
                    }

                    Button(action: previewCapsule) {
                        Label("Preview floating capsule", systemImage: "macwindow.on.rectangle")
                    }
                    .buttonStyle(VoxoLPrimaryButtonStyle())
                }
            }

            StudioSection("Live shortcuts") {
                VoxoLCard {
                    VStack(spacing: 18) {
                        SettingLine(
                            title: "Dictate anywhere",
                            detail:
                                "Hold the shortcut in any app. VoxoL captures locally until you release it."
                        ) {
                            KeyboardShortcutBadge(keys: "⌥ Space")
                        }

                        Divider()

                        SettingLine(
                            title: "Verify text insertion",
                            detail:
                                "Focus an editable field in Notes, Mail, Safari, Slack, VS Code or Cursor, then use the test shortcut."
                        ) {
                            KeyboardShortcutBadge(keys: "⌥ ⇧ Space")
                        }

                        if let report = dictationSession.lastReport {
                            Divider()
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Last dictation")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(
                                        report.capture.durationSeconds,
                                        format: .number.precision(.fractionLength(1))
                                    )
                                    Text("seconds")
                                }

                                HStack(spacing: 10) {
                                    Image(systemName: "mic")
                                    Text("Microphone signal")
                                    ProgressView(
                                        value: report.capture.normalizedMaximumLevel
                                    )
                                    .frame(maxWidth: 150)
                                    Text(
                                        report.capture.maximumLevelDBFS,
                                        format: .number.precision(.fractionLength(0))
                                    )
                                    Text("dBFS")
                                        .foregroundStyle(theme.secondaryInk)
                                }

                                HStack(spacing: 10) {
                                    Image(
                                        systemName: report.capture.speechDetected
                                            ? "waveform.badge.checkmark" : "waveform.slash"
                                    )
                                    Text("Voice detector")
                                    Spacer()
                                    if report.capture.speechDetected {
                                        Text("Detected")
                                    } else {
                                        Text("Not detected")
                                    }
                                }

                                if let characterCount = report.transcriptCharacterCount,
                                    let inferenceDuration = report.inferenceDurationSeconds
                                {
                                    HStack(spacing: 10) {
                                        Image(systemName: "text.quote")
                                        Text("Local transcription")
                                        Spacer()
                                        if let engine = report.speechRecognitionEngine {
                                            Text(speechEngineTitle(engine))
                                            Text("·")
                                        }
                                        Text("\(characterCount) characters")
                                        Text("·")
                                        Text(
                                            inferenceDuration * 1_000,
                                            format: .number.precision(.fractionLength(0))
                                        )
                                        Text("ms")
                                    }
                                }

                                if let route = report.processingRoute {
                                    HStack(spacing: 10) {
                                        Image(systemName: "wand.and.stars")
                                        Text("Text processing")
                                        Spacer()
                                        Text(processingTitle(route))
                                        if let duration = report.polishingDurationSeconds,
                                            duration > 0
                                        {
                                            Text("·")
                                            Text(
                                                duration * 1_000,
                                                format: .number.precision(.fractionLength(0))
                                            )
                                            Text("ms")
                                        }
                                    }
                                }

                                HStack(spacing: 10) {
                                    Image(systemName: deliverySymbol(for: report.outcome))
                                    Text("Text delivery")
                                    Spacer()
                                    Text(deliveryTitle(for: report.outcome))
                                }

                                if let duration = report.releaseToPasteDurationSeconds {
                                    HStack(spacing: 10) {
                                        Image(systemName: "stopwatch")
                                        Text("Release to insertion")
                                        Spacer()
                                        Text(
                                            duration * 1_000,
                                            format: .number.precision(.fractionLength(0))
                                        )
                                        Text("ms")
                                    }
                                }

                                if let failureReason = report.failureReason {
                                    Text(failureReason)
                                        .font(.caption)
                                        .foregroundStyle(theme.warning)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(theme.secondaryInk)
                        }
                    }
                }
            }

            StudioSection("Pipeline inspector") {
                VoxoLCard {
                    VStack(alignment: .leading, spacing: 16) {
                        SettingLine(
                            title: "Compare raw and final text",
                            detail: pipelineInspectorDetail
                        ) {
                            Toggle(
                                "Capture comparisons",
                                isOn: pipelineInspectorBinding
                            )
                            .labelsHidden()
                            .disabled(privateMode)
                        }

                        if pipelineInspectorEnabled, !privateMode {
                            Divider()

                            if let trace = dictationSession.pipelineTraces.first {
                                HStack {
                                    Label(
                                        speechEngineTitle(trace.speechRecognitionEngine),
                                        systemImage: "waveform"
                                    )
                                    Spacer()
                                    Text(processingTitle(trace.processingRoute))
                                    Text("·")
                                    Text(
                                        trace.asrDurationSeconds * 1_000,
                                        format: .number.precision(.fractionLength(0))
                                    )
                                    Text("ms")
                                }
                                .font(.caption)
                                .foregroundStyle(theme.secondaryInk)

                                HStack(alignment: .top, spacing: 14) {
                                    pipelineText(
                                        label: "Parakeet raw",
                                        text: trace.rawTranscript
                                    )
                                    pipelineText(
                                        label: "Final text",
                                        text: trace.finalText
                                    )
                                }

                                HStack(spacing: 10) {
                                    Text(
                                        dictationSession.pipelineTraces.count,
                                        format: .number
                                    )
                                    Text("comparisons captured")
                                        .foregroundStyle(theme.secondaryInk)
                                    Spacer()
                                    Button("Clear") {
                                        dictationSession.clearPipelineTraces()
                                    }
                                    .buttonStyle(VoxoLSecondaryButtonStyle())
                                    Button("Copy comparisons") {
                                        dictationSession.copyPipelineTraces()
                                    }
                                    .buttonStyle(VoxoLSecondaryButtonStyle())
                                }
                                .font(.caption)
                            } else {
                                Label(
                                    "Dictate a phrase to capture the first comparison.",
                                    systemImage: "text.bubble"
                                )
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryInk)
                            }
                        }
                    }
                }
            }

            StudioSection("Interaction") {
                VoxoLCard {
                    VStack(spacing: 18) {
                        SettingLine(
                            title: "Trigger",
                            detail: activationMode == .hold
                                ? "Capture lasts exactly as long as the shortcut is held."
                                : "Press once to start and press again to finish."
                        ) {
                            Picker("Trigger", selection: $activationMode) {
                                ForEach(ActivationMode.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 210)
                        }

                        Divider()

                        SettingLine(
                            title: "Cleanup mode",
                            detail:
                                "Faithful removes clear speech artifacts; Raw preserves every word."
                        ) {
                            Picker("Cleanup mode", selection: $cleanup) {
                                ForEach(DictationCleanupMode.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 210)
                        }

                        Divider()

                        SettingLine(
                            title: "Remove fillers",
                            detail: "Remove clear hesitation sounds without changing intent."
                        ) {
                            Toggle("Remove fillers", isOn: $removesFillers)
                                .labelsHidden()
                        }

                        Divider()

                        SettingLine(
                            title: "Automatic lists",
                            detail: "Turn spoken structure into bullets or numbered steps."
                        ) {
                            Toggle("Automatic lists", isOn: $automaticLists)
                                .labelsHidden()
                        }

                        Divider()

                        SettingLine(
                            title: "Instant mode",
                            detail: LocalizedStringKey(instantModeExplanationText)
                        ) {
                            Toggle("Instant mode", isOn: $fastPathEnabled)
                                .labelsHidden()
                        }

                        Divider()

                        SettingLine(
                            title: "Stable live transcript",
                            detail: stableTranscriptDetail
                        ) {
                            Toggle("Stable live transcript", isOn: $streamingEnabled)
                                .labelsHidden()
                                .disabled(dictationLanguage != .automatic)
                        }
                    }
                }
            }

            LocalOnlyNote(
                text: "Microphone capture, local speech-to-text and insertion are live."
            )
        }
        .onChange(of: privateMode) { _, enabled in
            guard enabled else {
                return
            }
            pipelineInspectorEnabled = false
            dictationSession.clearPipelineTraces()
        }
    }

    private var runtimeStatusTitle: LocalizedStringKey {
        switch dictationSession.state {
        case .waitingForInputMonitoring:
            "Permission setup required"
        case .ready:
            "Ready in every app"
        case .listening:
            "Capturing locally"
        case .speechDetected:
            "Speech detected"
        case .transcribing:
            "Transcribing locally"
        case .polishing:
            "Refining locally"
        case .inserting:
            "Inserting text"
        case .captureNeedsModel:
            "Capture ready · model pending"
        case .noSpeech:
            "No speech detected"
        case .insertionSucceeded(.accessibility):
            "Accessibility insertion verified"
        case .insertionSucceeded(.clipboardFallback):
            "Paste command sent"
        case .copiedForManualPaste:
            "Copied · press ⌘V"
        case .failed:
            "Check permissions"
        }
    }

    private var dictationLanguageDetail: LocalizedStringKey {
        switch dictationLanguage {
        case .automatic:
            "Detect each dictation automatically with Parakeet."
        case .french:
            "Lock recognition and text cleanup to French."
        case .english:
            "Lock recognition and text cleanup to English."
        }
    }

    private var languageSelector: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 16) {
                Label("Spoken language", systemImage: "character.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                Picker("Spoken language", selection: $dictationLanguage) {
                    ForEach(DictationLanguagePreference.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            Text(dictationLanguageDetail)
                .font(.caption)
                .foregroundStyle(theme.secondaryInk)
        }
        .padding(14)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.line, lineWidth: 1)
        }
    }

    private var stableTranscriptDetail: LocalizedStringKey {
        if dictationLanguage == .automatic {
            "Show only words confirmed by consecutive local partial transcriptions; partial text is never inserted."
        } else {
            "Live partial text is available in Auto; language-locked mode returns only the fast final transcript."
        }
    }

    private var pipelineInspectorDetail: LocalizedStringKey {
        if privateMode {
            "Unavailable in Private mode."
        } else if pipelineInspectorEnabled {
            "The last 20 comparisons stay in memory and disappear when VoxoL quits."
        } else {
            "Temporarily retain Parakeet raw text and final text in memory for model evaluation."
        }
    }

    private var pipelineInspectorBinding: Binding<Bool> {
        Binding(
            get: { pipelineInspectorEnabled },
            set: { enabled in
                pipelineInspectorEnabled = enabled
                if !enabled {
                    dictationSession.clearPipelineTraces()
                }
            }
        )
    }

    private var runtimeStatusSymbol: String {
        switch dictationSession.state {
        case .waitingForInputMonitoring, .failed:
            "exclamationmark.circle"
        case .listening, .speechDetected, .transcribing, .polishing:
            "waveform"
        case .inserting:
            "text.cursor"
        case .captureNeedsModel:
            "arrow.down.circle"
        case .noSpeech:
            "waveform.slash"
        case .ready:
            "checkmark.circle"
        case .insertionSucceeded, .copiedForManualPaste:
            "text.cursor"
        }
    }

    private var runtimeStatusTone: Color {
        switch dictationSession.state {
        case .waitingForInputMonitoring, .failed, .captureNeedsModel:
            theme.warning
        case .listening, .speechDetected, .transcribing, .polishing:
            theme.recording
        case .ready, .inserting, .noSpeech, .insertionSucceeded:
            theme.success
        case .copiedForManualPaste:
            theme.warning
        }
    }

    private var runtimeCapsuleLabel: LocalizedStringKey {
        switch dictationSession.state {
        case .waitingForInputMonitoring:
            "Finish permission setup"
        case .ready:
            "Ready to listen"
        case .listening:
            "Listening…"
        case .speechDetected:
            "Speech detected"
        case .transcribing:
            "Transcribing…"
        case .polishing:
            "Refining…"
        case .inserting:
            "Inserting…"
        case .captureNeedsModel:
            "Transcription model pending"
        case .noSpeech:
            "No speech heard"
        case .insertionSucceeded:
            "Insertion complete"
        case .copiedForManualPaste:
            "Copied · press ⌘V"
        case .failed:
            "Check permissions"
        }
    }

    private var isActivelyCapturing: Bool {
        dictationSession.state == .listening || dictationSession.state == .speechDetected
    }

    private func processingTitle(_ route: TextProcessingRoute) -> LocalizedStringKey {
        switch route {
        case .raw:
            "Raw"
        case .snippet:
            "Snippet"
        case .fastPath:
            "Fast path"
        case .qwen:
            "Qwen local"
        case .deterministicFallback:
            "Safe fallback"
        }
    }

    private func speechEngineTitle(
        _ engine: SpeechRecognitionEngine
    ) -> LocalizedStringKey {
        switch engine {
        case .appleFrench:
            "French · Apple local"
        case .appleEnglish:
            "English · Apple local"
        case .parakeetAutomatic:
            "Auto · Parakeet local"
        case .parakeetFallback:
            "Parakeet fallback"
        }
    }

    private func deliveryTitle(for outcome: DictationSessionOutcome) -> LocalizedStringKey {
        switch outcome {
        case .captured:
            "Capture complete"
        case .noSpeech:
            "No speech detected"
        case .transcribed:
            "Transcription complete"
        case .inserted(.accessibility):
            "Inserted with Accessibility"
        case .inserted(.clipboardFallback):
            "Inserted with paste"
        case .copiedForManualPaste:
            "Copied · press ⌘V"
        case .failed:
            "Not delivered"
        }
    }

    private func deliverySymbol(for outcome: DictationSessionOutcome) -> String {
        switch outcome {
        case .captured, .transcribed:
            "ellipsis.circle"
        case .noSpeech:
            "waveform.slash"
        case .inserted:
            "checkmark.circle"
        case .copiedForManualPaste:
            "doc.on.clipboard"
        case .failed:
            "exclamationmark.circle"
        }
    }

    private func transcriptColumn(
        label: LocalizedStringKey,
        text: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryInk)
            Text(text)
                .font(.title3)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func pipelineText(label: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryInk)
            Text(text)
                .font(.body)
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(theme.selection.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MeetingsPreviewView: View {
    @Environment(VoxoLTheme.self) private var theme

    var body: some View {
        StudioPage(
            eyebrow: "Meeting studio",
            title: "A local recap, when it is ready.",
            summary:
                "The destination remains visible so the future workflow is clear, but capture is unavailable."
        ) {
            ComingSoonBanner(
                detail:
                    "Meeting capture stays locked until dictation quality, privacy and performance gates pass."
            )

            ShowcaseSurface {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Product weekly")
                                .font(.title2.weight(.semibold))
                            Text("Google Meet · Preview")
                                .foregroundStyle(theme.secondaryInk)
                        }
                        Spacer()
                        StatusPill(title: "Unavailable", symbol: "lock")
                    }

                    HStack(spacing: 10) {
                        meetingTab("Summary", symbol: "text.alignleft")
                        meetingTab("Decisions", symbol: "checkmark.seal")
                        meetingTab("Actions", symbol: "checklist")
                        meetingTab("Transcript", symbol: "quote.bubble")
                    }

                    HStack(alignment: .top, spacing: 14) {
                        meetingPreviewCard(
                            title: "Decisions",
                            lines: [
                                "Keep all processing on this Mac",
                                "Validate dictation before Meeting mode",
                            ]
                        )
                        meetingPreviewCard(
                            title: "Actions",
                            lines: [
                                "Review the capture permission flow",
                                "Benchmark long-form local summaries",
                            ]
                        )
                    }
                }
            }

            StudioSection("Planned flow") {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: 14)],
                    spacing: 14
                ) {
                    FeatureStatusCard(
                        symbol: "rectangle.on.rectangle",
                        title: "Choose a source",
                        detail: "System picker for an app or window",
                        status: "1"
                    )
                    FeatureStatusCard(
                        symbol: "record.circle",
                        title: "Capture locally",
                        detail: "Visible timer, pause and explicit consent",
                        status: "2"
                    )
                    FeatureStatusCard(
                        symbol: "doc.text",
                        title: "Review the recap",
                        detail: "Summary, decisions, actions and transcript",
                        status: "3"
                    )
                }
            }

            LocalOnlyNote(
                text: "The first version will not promise named speaker attribution."
            )
        }
    }

    private func meetingTab(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.selection)
            .clipShape(Capsule())
    }

    private func meetingPreviewCard(
        title: LocalizedStringKey,
        lines: [LocalizedStringKey]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(theme.ink)
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryInk)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
