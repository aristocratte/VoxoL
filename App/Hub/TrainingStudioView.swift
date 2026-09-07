import AppKit
import SwiftUI

struct TrainingStudioView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TrainingReviewStore.self) private var reviews

    @State private var selectedID: String?
    @State private var verbatim = ""
    @State private var faithful = ""
    @State private var rewrite = ""
    @State private var code = ""
    @State private var rationale = ""
    @State private var player: NSSound?
    @State private var playingID: String?
    @State private var playbackTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            queue
                .frame(width: 286)
            Divider().overlay(theme.line)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.line, lineWidth: 1)
        }
        .task {
            if !reviews.isLoaded {
                await reviews.load()
            }
            selectInitialSession()
        }
        .onChange(of: reviews.sessions) { _, _ in
            selectInitialSession()
        }
        .onDisappear { stopAudio() }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Training Studio")
                            .font(
                                VoxoLTypography.font(size: 16, weight: .semibold, relativeTo: .body)
                            )
                            .foregroundStyle(theme.ink)
                        Text("Auditable personal references")
                            .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                            .foregroundStyle(theme.secondaryInk)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Button {
                            Task { await reviews.load() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(reviews.isLoading)
                        .help("Refresh training review")

                        Button {
                            Task { await reviews.export() }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .help("Export training review")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.cobalt)
                }

                HStack(spacing: 8) {
                    countBadge(value: reviews.acceptedCount, label: "accepted", tone: theme.success)
                    countBadge(value: reviews.attentionCount, label: "attention", tone: theme.coral)
                }
            }
            .padding(18)

            Divider().overlay(theme.line)

            if reviews.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if reviews.sessions.isEmpty {
                Text("No personal captures yet")
                    .font(VoxoLTypography.font(size: 13, relativeTo: .body))
                    .foregroundStyle(theme.secondaryInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(reviews.sessions) { session in
                            queueRow(session)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(theme.raisedSurface.opacity(0.55))
    }

    @ViewBuilder
    private var detail: some View {
        if let session = selectedSession {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailHeader(session)
                    editor(
                        title: "Verbatim gold",
                        detail: "What was said, including fillers and false starts.",
                        text: $verbatim
                    )
                    editor(
                        title: "Faithful gold",
                        detail: "Faithful formatting without changing facts or intent.",
                        text: $faithful
                    )
                    editor(
                        title: "Rewrite gold",
                        detail: "The best written version allowed by rewrite mode.",
                        text: $rewrite
                    )
                    editor(
                        title: "Code gold (optional)",
                        detail: "Exact code dictation reference when this capture contains code.",
                        text: $code
                    )
                    evidence(session)
                    decisionControls(session)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundStyle(theme.cobalt)
                Text("Select a capture")
                    .font(VoxoLTypography.font(size: 16, weight: .medium, relativeTo: .body))
                    .foregroundStyle(theme.ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func queueRow(_ session: TrainingReviewSession) -> some View {
        Button {
            select(session)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(session.status))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: session.faithfulText)
                        .font(VoxoLTypography.font(size: 12.5, weight: .medium, relativeTo: .body))
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                    Text(verbatim: rowDetail(session))
                        .font(VoxoLTypography.font(size: 10.5, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedID == session.id ? theme.cobaltSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detailHeader(_ session: TrainingReviewSession) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    statusBadge(session)
                    Text(verbatim: session.tier)
                        .font(VoxoLTypography.font(size: 10.5, relativeTo: .caption))
                        .foregroundStyle(theme.secondaryInk)
                }
                Text(verbatim: session.id)
                    .font(VoxoLTypography.font(size: 17, weight: .semibold, relativeTo: .headline))
                    .foregroundStyle(theme.ink)
                Text(
                    verbatim:
                        "\(session.application) · \(session.durationSeconds.formatted(.number.precision(.fractionLength(1)))) s"
                )
                .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
            }
            Spacer()
            Button {
                toggleAudio(session)
            } label: {
                Label(
                    playingID == session.id ? "Stop" : "Listen",
                    systemImage: playingID == session.id ? "stop.fill" : "play.fill"
                )
            }
            .buttonStyle(SignalSecondaryButtonStyle())
        }
    }

    private func editor(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(VoxoLTypography.font(size: 13.5, weight: .semibold, relativeTo: .body))
                .foregroundStyle(theme.ink)
            Text(detail)
                .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                .foregroundStyle(theme.secondaryInk)
            TextEditor(text: text)
                .font(VoxoLTypography.font(size: 13, relativeTo: .body))
                .foregroundStyle(theme.ink)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 104)
                .background(theme.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.line, lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private func evidence(_ session: TrainingReviewSession) -> some View {
        if let review = session.review {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(review.candidates.keys.sorted(), id: \.self) { system in
                        if let candidate = review.candidates[system] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: system.capitalized)
                                    .font(
                                        VoxoLTypography.font(
                                            size: 11, weight: .semibold, relativeTo: .caption)
                                    )
                                    .foregroundStyle(theme.cobalt)
                                Text("Verbatim candidate")
                                    .font(
                                        VoxoLTypography.font(
                                            size: 10.5, weight: .medium, relativeTo: .caption)
                                    )
                                    .foregroundStyle(theme.secondaryInk)
                                Text(verbatim: candidate.raw)
                                    .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                                    .foregroundStyle(theme.secondaryInk)
                                    .textSelection(.enabled)
                                Text("Clean candidate")
                                    .font(
                                        VoxoLTypography.font(
                                            size: 10.5, weight: .medium, relativeTo: .caption)
                                    )
                                    .foregroundStyle(theme.secondaryInk)
                                Text(verbatim: candidate.clean)
                                    .font(VoxoLTypography.font(size: 11.5, relativeTo: .caption))
                                    .foregroundStyle(theme.secondaryInk)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    if !review.criticalDisagreements.isEmpty {
                        Text(
                            "Protected disagreements: \(review.criticalDisagreements.joined(separator: ", "))"
                        )
                        .font(VoxoLTypography.font(size: 11, weight: .medium, relativeTo: .caption))
                        .foregroundStyle(theme.coral)
                    }
                }
                .padding(.top, 10)
            } label: {
                Text("Teacher evidence")
                    .font(VoxoLTypography.font(size: 12.5, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(theme.ink)
            }
        }
    }

    private func decisionControls(_ session: TrainingReviewSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Decision rationale", text: $rationale)
                .textFieldStyle(.roundedBorder)
            HStack {
                if let error = reviews.lastError {
                    Text(verbatim: error)
                        .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                        .foregroundStyle(theme.coral)
                        .lineLimit(2)
                } else if let notice = reviews.notice {
                    Text(verbatim: notice)
                        .font(VoxoLTypography.font(size: 11, relativeTo: .caption))
                        .foregroundStyle(theme.success)
                }
                Spacer()
                Button("Quarantine") {
                    save(session, disposition: .quarantine)
                }
                .buttonStyle(SignalSecondaryButtonStyle())
                Button("Save reviewed reference") {
                    save(session, disposition: .accept)
                }
                .buttonStyle(SignalPrimaryButtonStyle())
                .disabled(
                    verbatim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || faithful.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var selectedSession: TrainingReviewSession? {
        guard let selectedID else { return nil }
        return reviews.sessions.first(where: { $0.id == selectedID })
    }

    private func selectInitialSession() {
        if selectedSession == nil, let first = reviews.sessions.first {
            select(first)
        }
    }

    private func select(_ session: TrainingReviewSession) {
        stopAudio()
        selectedID = session.id
        verbatim = session.verbatimText
        faithful = session.faithfulText
        rewrite = session.rewriteText
        code = session.codeText
        rationale = session.review?.provenance.rationale ?? ""
        reviews.dismissNotice()
    }

    private func save(_ session: TrainingReviewSession, disposition: TrainingReviewDisposition) {
        Task {
            await reviews.save(
                id: session.id,
                verbatim: verbatim,
                faithful: faithful,
                rewrite: rewrite,
                code: code,
                disposition: disposition,
                rationale: rationale.isEmpty ? "Reviewed in Training Studio." : rationale
            )
        }
    }

    private func toggleAudio(_ session: TrainingReviewSession) {
        if playingID == session.id {
            stopAudio()
            return
        }
        stopAudio()
        guard let sound = NSSound(contentsOf: session.audioURL, byReference: true) else { return }
        player = sound
        playingID = session.id
        sound.play()
        playbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0.2, session.durationSeconds)))
            guard !Task.isCancelled, playingID == session.id else { return }
            player?.stop()
            player = nil
            playingID = nil
            playbackTask = nil
        }
    }

    private func stopAudio() {
        playbackTask?.cancel()
        playbackTask = nil
        player?.stop()
        player = nil
        playingID = nil
    }

    private func countBadge(value: Int, label: LocalizedStringKey, tone: Color) -> some View {
        HStack(spacing: 4) {
            Text(value.formatted())
                .font(VoxoLTypography.font(size: 11, weight: .semibold, relativeTo: .caption))
            Text(label)
                .font(VoxoLTypography.font(size: 10.5, relativeTo: .caption))
        }
        .foregroundStyle(tone)
    }

    private func statusBadge(_ session: TrainingReviewSession) -> some View {
        Text(statusTitle(session.status))
            .font(VoxoLTypography.font(size: 10.5, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(statusColor(session.status))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(statusColor(session.status).opacity(0.12))
            .clipShape(Capsule())
    }

    private func statusTitle(_ status: TrainingReviewStatus) -> LocalizedStringKey {
        switch status {
        case .pending: "Pending"
        case .accepted: "Accepted"
        case .contextReview: "Context review"
        case .quarantined: "Quarantined"
        }
    }

    private func statusText(_ status: TrainingReviewStatus) -> String {
        switch status {
        case .pending: String(localized: "Pending")
        case .accepted: String(localized: "Accepted")
        case .contextReview: String(localized: "Context review")
        case .quarantined: String(localized: "Quarantined")
        }
    }

    private func statusColor(_ status: TrainingReviewStatus) -> Color {
        switch status {
        case .accepted: theme.success
        case .contextReview: theme.cobalt
        case .quarantined: theme.coral
        case .pending: theme.secondaryInk
        }
    }

    private func rowDetail(_ session: TrainingReviewSession) -> String {
        "\(statusText(session.status)) · \(session.durationSeconds.formatted(.number.precision(.fractionLength(1)))) s"
    }
}
