import AppKit
import AVFoundation
import Observation
import SpeakerKit
import SwiftUI

// What sits beside a meeting report: the audio it came from, printed and playable, and the
// conversation turn by turn.

/// The meetings screens choose their words from the interface language at the call site, the way
/// this module always has, rather than through the string catalog.
func tr(_ french: Bool, _ fr: String, _ en: String) -> String { french ? fr : en }

// MARK: - Playback

/// Plays a meeting's original audio from its bookmark. One per open report, shared by the print,
/// the timecodes in the document's margin, the transcript and the floating player.
@MainActor @Observable
final class MeetingPlayback {
    private(set) var player: AVPlayer?
    private(set) var position = 0.0
    private(set) var playing = false
    private(set) var rate: Float = 1
    var error: String?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var ownsScope = false
    @ObservationIgnored private var bookmark: Data?

    func play(_ reference: MeetingAudioReference?, at time: Double? = nil, french: Bool) {
        guard let reference else {
            if let time { position = max(0, time) }
            error =
                tr(french, "Relie le fichier audio d’origine pour écouter ce passage.", "Link the original audio file to listen to this passage.")
            return
        }
        do {
            if bookmark != reference.bookmark || player == nil {
                stop()
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: reference.bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
                ownsScope = url.startAccessingSecurityScopedResource()
                scopedURL = url
                guard FileManager.default.fileExists(atPath: url.path) else {
                    stop()
                    error =
                        tr(french, "Le fichier a été déplacé. Relie-le à nouveau.", "The file moved. Link it again.")
                    return
                }
                player = AVPlayer(url: url)
                bookmark = reference.bookmark
            }
            error = nil
            if let time { seek(time) }
            player?.rate = rate
            playing = true
        } catch {
            stop()
            self.error = error.localizedDescription
        }
    }

    func toggle(_ reference: MeetingAudioReference?, french: Bool) {
        if playing { pause() } else { play(reference, french: french) }
    }

    func pause() { player?.pause(); playing = false }

    func seek(_ time: Double) {
        player?.seek(
            to: CMTime(seconds: max(0, time), preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        position = max(0, time)
    }

    func skip(_ seconds: Double, limit: Double) { seek(min(max(0, position + seconds), limit)) }

    /// Cycles 1×, 1.25×, 1.5×, 2×.
    func cycleRate() {
        let rates: [Float] = [1, 1.25, 1.5, 2]
        rate = rates[((rates.firstIndex(of: rate) ?? 0) + 1) % rates.count]
        if playing { player?.rate = rate }
    }

    func refresh() {
        if let time = player?.currentTime().seconds, time.isFinite { position = time }
        if player != nil { playing = player?.timeControlStatus != .paused }
        if let failure = player?.currentItem?.error { error = failure.localizedDescription }
    }

    func stop() {
        player?.pause(); player = nil; playing = false
        if ownsScope { scopedURL?.stopAccessingSecurityScopedResource() }
        scopedURL = nil; ownsScope = false; bookmark = nil
    }
}

// MARK: - Speakers

/// How a voice is drawn: a pale tint of its own and the initial of its name.
struct MeetingSpeakerBadge: View {
    @Environment(VoxoLTheme.self) private var theme

    let speaker: Int?
    let name: String
    var size: CGFloat = 20

    var body: some View {
        Text(verbatim: String(name.first.map { $0.uppercased() } ?? "?"))
            .font(VoxoLTypography.font(size: size * 0.5, weight: .semibold))
            .foregroundStyle(theme.ink)
            .frame(width: size, height: size)
            .background(tint, in: Circle())
            .accessibilityHidden(true)
    }

    private var tint: Color {
        guard let speaker else { return theme.selection }
        let tints = [
            theme.cobaltSoft, theme.coralSoft, theme.sageSoft,
            Color(red: 0.98, green: 0.93, blue: 0.80), Color(red: 0.93, green: 0.89, blue: 0.98),
            Color(red: 0.86, green: 0.94, blue: 0.96),
        ]
        return tints[speaker % tints.count]
    }
}

// MARK: - The conversation, printed

/// The meeting drawn in the dither the rest of VoxoL is printed with: one column of dots per slice
/// of time, as tall as the speech in it. What has been played is in ink, the rest in grey, the
/// playhead in cobalt; chapter starts leave a gap. Click or drag to move the playhead.
struct ConversationPrint: View {
    @Environment(VoxoLTheme.self) private var theme

    /// Loudness from 0 to 1, oldest first, one value per slice of the meeting.
    let envelope: [Double]
    let duration: Double
    var position: Double?
    var chapters: [Double] = []
    var tint: Color?
    var seek: ((Double) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            canvas
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        seek?(max(0, min(duration, value.location.x / max(1, proxy.size.width) * duration)))
                    },
                    including: seek == nil ? .none : .all
                )
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Audio"))
        .accessibilityValue(Text(verbatim: MeetingTime.short(position ?? 0)))
    }

    private var canvas: some View {
        Canvas { context, size in
            let cell: CGFloat = size.height < 30 ? 3 : 4
            let columns = max(1, Int(size.width / cell))
            let rows = max(3, Int(size.height / cell))
            let playhead = position.map { Int(($0 / max(duration, 1)) * Double(columns)) }
            let gaps = Set(chapters.map { Int(($0 / max(duration, 1)) * Double(columns)) })
            var played = Path()
            var ahead = Path()
            var floor = Path()
            for column in 0..<columns where !gaps.contains(column) {
                let index = min(envelope.count - 1, column * envelope.count / columns)
                let amplitude = envelope.isEmpty ? 0 : envelope[max(0, index)]
                for row in 0..<rows {
                    let distance = abs(Double(row) - Double(rows - 1) / 2) / (Double(rows - 1) / 2)
                    let inside =
                        distance <= amplitude
                        && Self.grain(Double(column) * 1.3, Double(row) * 0.7) < 0.9 - distance * 0.35
                    let centre = CGPoint(
                        x: CGFloat(column) * cell + cell / 2, y: CGFloat(row) * cell + cell / 2)
                    if inside {
                        let radius = cell * 0.36
                        let dot = CGRect(
                            x: centre.x - radius, y: centre.y - radius, width: radius * 2,
                            height: radius * 2)
                        if let playhead, column > playhead {
                            ahead.addEllipse(in: dot)
                        } else {
                            played.addEllipse(in: dot)
                        }
                    } else if distance < 0.15 {
                        let radius = cell * 0.16
                        floor.addEllipse(
                            in: CGRect(
                                x: centre.x - radius, y: centre.y - radius, width: radius * 2,
                                height: radius * 2))
                    }
                }
            }
            context.fill(floor, with: .color(theme.selection))
            context.fill(ahead, with: .color(theme.secondaryInk.opacity(0.32)))
            context.fill(played, with: .color(tint ?? theme.ink))
            if let playhead {
                context.fill(
                    Path(CGRect(x: CGFloat(playhead) * cell, y: 0, width: 2, height: size.height)),
                    with: .color(tint ?? theme.cobalt))
            }
        }
    }

    static func grain(_ x: Double, _ y: Double) -> Double {
        let value = sin(x * 127.1 + y * 311.7 + 47.3) * 43758.5453
        return value - value.rounded(.down)
    }

    /// The speech density of a transcript in `slices` slices: how much of each slice someone was
    /// speaking, weighted by how fast. Silence stays at the floor.
    static func envelope(of transcript: SpeakerTranscript, slices: Int = 240) -> [Double] {
        let duration = max(transcript.duration, 1)
        var values = Array(repeating: 0.0, count: slices)
        for turn in transcript.turns {
            let length = max(0.1, turn.end - turn.start)
            let words = Double(turn.text.split(whereSeparator: \.isWhitespace).count)
            let pace = min(1, words / length / 3.2)
            let first = Int(turn.start / duration * Double(slices))
            let last = min(slices - 1, Int(turn.end / duration * Double(slices)))
            guard first <= last else { continue }
            for slice in first...last {
                values[slice] = max(values[slice], 0.3 + 0.55 * pace + 0.15 * grain(Double(slice), 3))
            }
        }
        return values.map { min(1, $0) }
    }
}

// MARK: - Transcript beside the report

/// The conversation turn by turn. Follows the playhead, shows the turns the selected passage of the
/// report cites, and lets a turn's speaker be corrected.
struct MeetingTranscriptPanel: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings

    let transcript: SpeakerTranscript
    let citedTurns: Set<Int>
    let playback: MeetingPlayback
    let french: Bool
    let renameVoices: () -> Void

    @State private var search = ""
    @State private var searching = false

    private var speakerPrefix: String { tr(french, "Intervenant", "Speaker") }
    private var unknown: String { tr(french, "Voix incertaine", "Uncertain speaker") }

    private var turns: [SpeakerTurn] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.turns.filter { query.isEmpty || $0.text.localizedStandardContains(query) }
    }

    /// The turn being heard, only once something has been played.
    private var currentTurn: Int? {
        guard playback.player != nil else { return nil }
        return transcript.turns.last { $0.start <= playback.position + 0.2 }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(tr(french, "Transcription", "Transcript"))
                    .font(VoxoLTypography.font(size: 15, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Spacer()
                Button {
                    withAnimation(EditorialMotion.soft) {
                        searching.toggle()
                        if !searching { search = "" }
                    }
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 12))
                }
                .buttonStyle(HubButtonStyle(kind: .ghost))
                .help(tr(french, "Rechercher dans la conversation", "Search the conversation"))
                Menu {
                    Button(tr(french, "Copier la transcription", "Copy transcript")) {
                        meetings.copy(transcript, french: french)
                    }
                    Button(tr(french, "Renommer les voix…", "Rename voices…"), action: renameVoices)
                    Divider()
                    Button(tr(french, "Exporter en texte (.txt)", "Export as text (.txt)")) {
                        meetings.export(transcript, format: "txt", french: french)
                    }
                    Button(tr(french, "Exporter en sous-titres (.srt)", "Export as subtitles (.srt)")) {
                        meetings.export(transcript, format: "srt", french: french)
                    }
                    Button(tr(french, "Exporter en données (.json)", "Export as data (.json)")) {
                        meetings.export(transcript, format: "json", french: french)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.secondaryInk)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(theme.secondaryInk)
                .fixedSize()
            }
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(height: 44)

            if searching {
                TextField(tr(french, "Rechercher", "Search"), text: $search)
                    .textFieldStyle(.plain)
                    .font(VoxoLTypography.font(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if turns.isEmpty {
                            Text(tr(french, "Aucun passage.", "No passage."))
                                .font(VoxoLTypography.font(size: 13))
                                .foregroundStyle(theme.secondaryInk)
                                .padding(.horizontal, 8)
                        }
                        ForEach(turns) { turn in
                            turnRow(turn)
                                .id(turn.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 24)
                }
                .onChange(of: citedTurns) { _, ids in
                    guard let first = transcript.turns.first(where: { ids.contains($0.id) })?.id
                    else { return }
                    withAnimation(EditorialMotion.soft) { proxy.scrollTo(first, anchor: .center) }
                }
                .onChange(of: currentTurn) { _, id in
                    guard let id, playback.playing, citedTurns.isEmpty else { return }
                    withAnimation(EditorialMotion.soft) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(theme.well)
    }

    private func turnRow(_ turn: SpeakerTurn) -> some View {
        let speaker = turn.displayedSpeakerIDs.first
        let name = transcript.label(for: turn, prefix: speakerPrefix, unknown: unknown)
        let current = currentTurn == turn.id
        let cited = citedTurns.contains(turn.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                MeetingSpeakerBadge(speaker: speaker, name: name)
                Menu {
                    ForEach(transcript.speakerIDs, id: \.self) { id in
                        Button(transcript.name(for: id, prefix: speakerPrefix)) {
                            Task { await meetings.assign(speaker: id, turn: turn.id, document: transcript.id) }
                        }
                    }
                    Button(unknown) {
                        Task { await meetings.assign(speaker: nil, turn: turn.id, document: transcript.id) }
                    }
                    Divider()
                    Button(tr(french, "Renommer les voix…", "Rename voices…"), action: renameVoices)
                } label: {
                    Text(verbatim: name)
                        .font(VoxoLTypography.font(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(theme.ink).fixedSize()
                .help(tr(french, "Corriger l’intervenant", "Correct the speaker"))
                Spacer(minLength: 4)
                Button {
                    playback.play(transcript.audioReference, at: turn.start, french: french)
                } label: {
                    Text(verbatim: MeetingTime.short(turn.start))
                        .font(VoxoLTypography.font(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(current ? theme.cobalt : theme.secondaryInk)
                }
                .buttonStyle(.plain)
                .help(tr(french, "Écouter depuis ici", "Listen from here"))
            }
            Text(verbatim: turn.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.ink)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            current || cited ? theme.surface : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Times the way people say them: 4:12, 1:04:12.
enum MeetingTime {
    static func short(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
