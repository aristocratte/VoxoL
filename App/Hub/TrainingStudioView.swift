import AppKit
import SwiftUI

/// Turns saved dictations into references only after an explicit listen-and-correct decision.
struct TrainingStudioView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TrainingReviewStore.self) private var reviews
    @Environment(\.locale) private var locale

    private enum ReviewFilter: CaseIterable, Hashable {
        case toReview
        case verified
        case excluded

        var title: LocalizedStringKey {
            switch self {
            case .toReview: "To review"
            case .verified: "Verified recordings"
            case .excluded: "Excluded recordings"
            }
        }

        func includes(_ session: TrainingReviewSession) -> Bool {
            switch self {
            case .toReview: session.status == .pending || session.status == .contextReview
            case .verified: session.status == .accepted
            case .excluded: session.status == .quarantined
            }
        }
    }

    private enum PendingNavigation {
        case recording(String)
        case filter(ReviewFilter)
    }

    @State private var filter: ReviewFilter = .toReview
    @State private var selectedID: String?
    @State private var verbatim = ""
    @State private var faithful = ""
    @State private var rewrite = ""
    @State private var code = ""
    @State private var rationale = ""
    @State private var customRewrite = false
    @State private var showsMore = false
    @State private var confirmed = false
    @State private var isSaving = false
    @State private var pendingNavigation: PendingNavigation?
    @State private var showsDiscardAlert = false
    @State private var player: NSSound?
    @State private var playingID: String?
    @State private var playbackTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(theme.line).frame(height: 1)
            HStack(spacing: 0) {
                queue
                    .frame(width: 292)
                Rectangle().fill(theme.line).frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.line, lineWidth: 1)
        }
        .task {
            if !reviews.isLoaded { await reviews.load() }
            selectFirstAvailable()
        }
        .onChange(of: reviews.sessions) { _, _ in
            if selectedID == nil { selectFirstAvailable() }
        }
        .onDisappear { stopAudio() }
        .alert("Discard your edits?", isPresented: $showsDiscardAlert) {
            Button("Keep editing", role: .cancel) { pendingNavigation = nil }
            Button("Discard edits", role: .destructive) { completePendingNavigation() }
        } message: {
            Text("Your changes to this recording have not been saved.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Review your recordings")
                    .font(VoxoLTypography.font(size: 16, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(theme.ink)
                Text(
                    "Listen and correct saved dictations to create trusted examples for quality checks."
                )
                .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                .foregroundStyle(theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                Text("This does not retrain the model immediately. Everything stays on this Mac.")
                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Button {
                    Task { await reviews.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryInk)
                .disabled(reviews.isLoading)
                .help("Refresh recordings")

                Button {
                    Task { await reviews.export() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SignalSecondaryButtonStyle())
                .disabled(reviews.sessions.isEmpty)
                .help("Export reviewed references as JSONL")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach(ReviewFilter.allCases, id: \.self) { option in
                    Button {
                        requestFilter(option)
                    } label: {
                        VStack(spacing: 2) {
                            Text(count(for: option).formatted())
                                .font(VoxoLTypography.font(size: 14, weight: .semibold))
                            Text(option.title)
                                .font(VoxoLTypography.font(size: 10.5, relativeTo: .caption))
                        }
                        .foregroundStyle(filter == option ? theme.ink : theme.secondaryInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 49)
                        .background(filter == option ? theme.surface : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == option ? .isSelected : [])
                }
            }
            .padding(5)
            .background(theme.selection.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(12)

            Rectangle().fill(theme.line).frame(height: 1)

            if reviews.isLoading && reviews.sessions.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleSessions.isEmpty {
                queueEmptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(visibleSessions) { session in
                            queueRow(session)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(theme.raisedSurface.opacity(0.45))
    }

    private var queueEmptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: reviews.sessions.isEmpty ? "waveform" : "checkmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(theme.secondaryInk)
                .padding(.bottom, 4)
            Text(reviews.sessions.isEmpty ? "No recordings yet" : "Nothing in this section")
                .font(VoxoLTypography.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text(
                reviews.sessions.isEmpty
                    ? "Enable Personal benchmark capture in Settings to save future dictations for review."
                    : "Choose another section to see your recordings."
            )
            .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
            .foregroundStyle(theme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private func queueRow(_ session: TrainingReviewSession) -> some View {
        Button {
            requestSelection(session)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(statusColor(session.status))
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: preview(for: session))
                        .font(VoxoLTypography.font(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: rowMetadata(for: session))
                        .font(VoxoLTypography.font(size: 10.5, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedID == session.id ? theme.cobaltSoft.opacity(0.72) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedID == session.id ? .isSelected : [])
    }

    @ViewBuilder
    private var detail: some View {
        if let session = selectedSession, filter.includes(session) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        detailHeader(session)
                        Rectangle().fill(theme.line).frame(height: 1)
                        Text(
                            "These texts are prefilled proposals. Listen to the recording and correct them before you verify it."
                        )
                        .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                        .foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        editor(
                            title: "Words spoken",
                            detail: "What you actually said, including hesitations.",
                            text: $verbatim
                        )
                        editor(
                            title: "Final text expected",
                            detail:
                                "The text you wanted VoxoL to write, without changing the facts.",
                            text: $faithful
                        )
                        moreReferences(session)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Rectangle().fill(theme.line).frame(height: 1)
                decisionControls(session)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.surface)
            }
        } else {
            VStack(spacing: 7) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.secondaryInk)
                Text("Select a recording to review")
                    .font(VoxoLTypography.font(size: 14, weight: .medium))
                    .foregroundStyle(theme.ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ session: TrainingReviewSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    statusBadge(session.status)
                    Text(verbatim: dateTitle(for: session))
                        .font(VoxoLTypography.font(size: 15, weight: .semibold))
                        .foregroundStyle(theme.ink)
                }
                Text(verbatim: "\(appName(for: session)) · \(duration(for: session))")
                    .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                    .foregroundStyle(theme.secondaryInk)
            }
            Spacer(minLength: 8)
            Button {
                toggleAudio(session)
            } label: {
                Label(
                    playingID == session.id ? "Stop" : "Listen",
                    systemImage: playingID == session.id ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(SignalSecondaryButtonStyle())
            .help(
                session.nativeAudioURL == nil
                    ? "Audio used for transcription (16 kHz). Older recordings have no original copy."
                    : "Original microphone recording, before transcription processing."
            )
        }
    }

    private func editor(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(VoxoLTypography.font(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text(detail)
                .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
            TextEditor(text: text)
                .font(VoxoLTypography.font(size: 12.5, relativeTo: .body))
                .foregroundStyle(theme.ink)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 118)
                .background(theme.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.line, lineWidth: 1)
                }
                .accessibilityLabel(Text(title))
        }
    }

    private func moreReferences(_ session: TrainingReviewSession) -> some View {
        DisclosureGroup(isExpanded: $showsMore) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("Use a different version for Rewrite mode", isOn: $customRewrite)
                    .toggleStyle(.checkbox)
                    .font(VoxoLTypography.font(size: 12, relativeTo: .body))
                if customRewrite {
                    editor(
                        title: "Rewrite version",
                        detail: "A more polished version with the same meaning and facts.",
                        text: $rewrite
                    )
                } else {
                    Text("The final text above is also used for Rewrite mode.")
                        .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                }
                editor(
                    title: "Code reference (optional)",
                    detail: "Only fill this when the recording contains dictated code.",
                    text: $code
                )
                evidence(session)
            }
            .padding(.top, 12)
        } label: {
            Text("More references and comparisons")
                .font(VoxoLTypography.font(size: 12, weight: .medium))
                .foregroundStyle(theme.ink)
        }
    }

    @ViewBuilder
    private func evidence(_ session: TrainingReviewSession) -> some View {
        if let review = session.review, !review.candidates.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(review.candidates.keys.sorted(), id: \.self) { system in
                        if let candidate = review.candidates[system] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: system.capitalized)
                                    .font(VoxoLTypography.font(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.ink)
                                Text(verbatim: candidate.raw)
                                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                                    .foregroundStyle(theme.secondaryInk)
                                    .textSelection(.enabled)
                                Text(verbatim: candidate.clean)
                                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                                    .foregroundStyle(theme.secondaryInk)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Other transcription proposals")
                    .font(VoxoLTypography.font(size: 11.5, weight: .medium))
            }
        }
    }

    private func decisionControls(_ session: TrainingReviewSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Note (optional)", text: $rationale)
                .textFieldStyle(.roundedBorder)
            Toggle("I listened and checked these texts", isOn: $confirmed)
                .toggleStyle(.checkbox)
                .font(VoxoLTypography.font(size: 12, relativeTo: .body))
            HStack(spacing: 10) {
                Button("Exclude recording") {
                    save(session, disposition: .quarantine)
                }
                .buttonStyle(SignalSecondaryButtonStyle())
                .help("Excluded recordings are not used as verified examples")
                Spacer(minLength: 8)
                Button("Save as verified") {
                    save(session, disposition: .accept)
                }
                .buttonStyle(SignalPrimaryButtonStyle())
                .disabled(!canAccept)
            }
            .disabled(isSaving)
            if let error = reviews.lastError {
                Text(verbatim: error)
                    .foregroundStyle(theme.coral)
                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
            } else if let notice = reviews.notice {
                Text(verbatim: notice)
                    .foregroundStyle(theme.success)
                    .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
            }
        }
    }

    private var visibleSessions: [TrainingReviewSession] {
        reviews.sessions.filter(filter.includes)
    }

    private var selectedSession: TrainingReviewSession? {
        guard let selectedID else { return nil }
        return reviews.sessions.first { $0.id == selectedID }
    }

    private var canAccept: Bool {
        confirmed
            && !verbatim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !faithful.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!customRewrite || !rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var hasUnsavedChanges: Bool {
        guard let session = selectedSession else { return false }
        let savedNote =
            session.review?.provenance.humanReviewed == true
            ? session.review?.provenance.rationale ?? "" : ""
        return verbatim != session.verbatimText
            || faithful != session.faithfulText
            || (customRewrite ? rewrite : faithful) != session.rewriteText
            || code != session.codeText
            || rationale != savedNote
    }

    private func count(for option: ReviewFilter) -> Int {
        reviews.sessions.count(where: option.includes)
    }

    private func selectFirstAvailable() {
        guard selectedID == nil, let first = visibleSessions.first else { return }
        selectNow(first)
    }

    private func requestFilter(_ option: ReviewFilter) {
        guard option != filter else { return }
        if hasUnsavedChanges {
            pendingNavigation = .filter(option)
            showsDiscardAlert = true
        } else {
            showFilter(option)
        }
    }

    private func requestSelection(_ session: TrainingReviewSession) {
        guard selectedID != session.id else { return }
        if hasUnsavedChanges {
            pendingNavigation = .recording(session.id)
            showsDiscardAlert = true
        } else {
            selectNow(session)
        }
    }

    private func completePendingNavigation() {
        defer { pendingNavigation = nil }
        switch pendingNavigation {
        case .recording(let id):
            if let session = reviews.sessions.first(where: { $0.id == id }) { selectNow(session) }
        case .filter(let option):
            showFilter(option)
        case nil:
            break
        }
    }

    private func showFilter(_ option: ReviewFilter) {
        stopAudio()
        filter = option
        selectedID = nil
        selectFirstAvailable()
    }

    private func selectNow(_ session: TrainingReviewSession, clearNotice: Bool = true) {
        stopAudio()
        selectedID = session.id
        verbatim = session.verbatimText
        faithful = session.faithfulText
        rewrite = session.rewriteText
        code = session.codeText
        rationale =
            session.review?.provenance.humanReviewed == true
            ? session.review?.provenance.rationale ?? "" : ""
        customRewrite = session.rewriteText != session.faithfulText
        showsMore = customRewrite || !session.codeText.isEmpty
        confirmed = false
        if clearNotice { reviews.dismissNotice() }
    }

    private func save(_ session: TrainingReviewSession, disposition: TrainingReviewDisposition) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            await reviews.save(
                id: session.id,
                verbatim: verbatim,
                faithful: faithful,
                rewrite: customRewrite ? rewrite : faithful,
                code: code,
                disposition: disposition,
                rationale: rationale.isEmpty
                    ? String(
                        localized: disposition == .accept
                            ? "Reviewed in VoxoL." : "Excluded in VoxoL.")
                    : rationale
            )
            isSaving = false
            guard reviews.lastError == nil else { return }
            if filter == .toReview, let next = visibleSessions.first(where: { $0.id != session.id })
            {
                selectNow(next, clearNotice: false)
            } else if filter.includes(
                reviews.sessions.first(where: { $0.id == session.id }) ?? session),
                let updated = reviews.sessions.first(where: { $0.id == session.id })
            {
                selectNow(updated, clearNotice: false)
            } else {
                stopAudio()
                selectedID = nil
            }
        }
    }

    private func toggleAudio(_ session: TrainingReviewSession) {
        if playingID == session.id {
            stopAudio()
            return
        }
        stopAudio()
        guard
            let sound = NSSound(contentsOf: session.playbackAudioURL, byReference: true)
                ?? NSSound(contentsOf: session.audioURL, byReference: true)
        else { return }
        player = sound
        playingID = session.id
        sound.play()
        playbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0.2, sound.duration)))
            guard !Task.isCancelled, playingID == session.id else { return }
            stopAudio()
        }
    }

    private func stopAudio() {
        playbackTask?.cancel()
        playbackTask = nil
        player?.stop()
        player = nil
        playingID = nil
    }

    private func statusBadge(_ status: TrainingReviewStatus) -> some View {
        Text(statusTitle(status))
            .font(VoxoLTypography.font(size: 10.5, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(statusColor(status).opacity(0.1))
            .clipShape(Capsule())
    }

    private func statusTitle(_ status: TrainingReviewStatus) -> LocalizedStringKey {
        switch status {
        case .pending: "To review"
        case .contextReview: "Needs checking"
        case .accepted: "Verified"
        case .quarantined: "Excluded"
        }
    }

    private func statusColor(_ status: TrainingReviewStatus) -> Color {
        switch status {
        case .pending: theme.secondaryInk
        case .contextReview: theme.coral
        case .accepted: theme.success
        case .quarantined: theme.secondaryInk
        }
    }

    private func preview(for session: TrainingReviewSession) -> String {
        let text = session.faithfulText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? String(localized: "Recording without text") : text
    }

    private func dateTitle(for session: TrainingReviewSession) -> String {
        session.capturedAt?.formatted(
            .dateTime.day().month(.abbreviated).year().hour().minute().locale(locale))
            ?? String(localized: "Saved recording")
    }

    private func rowMetadata(for session: TrainingReviewSession) -> String {
        let date =
            session.capturedAt?.formatted(.dateTime.day().month(.abbreviated).locale(locale))
            ?? String(localized: "Undated")
        return "\(date) · \(appName(for: session)) · \(duration(for: session))"
    }

    private func appName(for session: TrainingReviewSession) -> String {
        guard session.application != "unknown" else { return String(localized: "Unknown app") }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: session.application)
        {
            return url.deletingPathExtension().lastPathComponent
        }
        return session.application.split(separator: ".").last.map(String.init)?.capitalized
            ?? session.application
    }

    private func duration(for session: TrainingReviewSession) -> String {
        let seconds = max(0, Int(session.durationSeconds.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
