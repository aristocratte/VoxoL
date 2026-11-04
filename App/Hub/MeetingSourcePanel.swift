import AppKit
import AVFoundation
import Observation
import SpeakerKit
import SwiftUI

@MainActor @Observable
private final class MeetingPlayback {
    private(set) var player: AVPlayer?
    private(set) var position = 0.0
    private(set) var playing = false
    var error: String?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var ownsScope = false
    @ObservationIgnored private var bookmark: Data?

    func play(_ reference: MeetingAudioReference?, at time: Double? = nil, french: Bool) {
        guard let reference else {
            error =
                french
                ? "Reliez le fichier audio d’origine pour écouter ce passage."
                : "Link the original audio file to listen to this passage."
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
                        french
                        ? "Le fichier a été déplacé. Reliez-le à nouveau."
                        : "The file moved. Link it again."
                    return
                }
                player = AVPlayer(url: url)
                bookmark = reference.bookmark
            }
            error = nil
            if let time { seek(time) }
            player?.play()
            playing = true
        } catch {
            stop()
            self.error = error.localizedDescription
        }
    }

    func pause() { player?.pause(); playing = false }
    func seek(_ time: Double) {
        player?.seek(
            to: CMTime(seconds: max(0, time), preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero)
        position = max(0, time)
    }
    func refresh() {
        if let time = player?.currentTime().seconds, time.isFinite { position = time }
        playing = player?.timeControlStatus == .playing
        if let failure = player?.currentItem?.error { error = failure.localizedDescription }
    }
    func stop() {
        player?.pause(); player = nil; playing = false
        if ownsScope { scopedURL?.stopAccessingSecurityScopedResource() }
        scopedURL = nil; ownsScope = false; bookmark = nil
    }
}

struct MeetingSourcePanel: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    let transcript: SpeakerTranscript
    let sourceIDs: [Int]
    let french: Bool
    let close: () -> Void
    @State private var playback = MeetingPlayback()
    @State private var tab = 0
    @State private var search = ""

    private var turns: [SpeakerTurn] {
        transcript.turns.filter { search.isEmpty || $0.text.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(french ? "Autour du document" : "Alongside your document")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(MeetingQuietButtonStyle()).accessibilityLabel(
                        french ? "Fermer" : "Close")
            }.padding(.horizontal, 18).padding(.top, 16)
            Picker("", selection: $tab) {
                Text(french ? "Sources" : "Sources").tag(0)
                Text(french ? "Notes" : "Notes").tag(1)
                Text(french ? "Actions" : "Actions").tag(2)
            }.pickerStyle(.segmented).labelsHidden().padding(16)
            if tab == 0 { sources }
            if tab == 1 { notes }
            if tab == 2 { actions }
        }
        .background(theme.canvas).foregroundStyle(theme.ink)
        .task {
            while !Task.isCancelled {
                playback.refresh()
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        .onDisappear { playback.stop() }
    }

    private var sources: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    if playback.playing {
                        playback.pause()
                    } else {
                        playback.play(transcript.audioReference, french: french)
                    }
                } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(MeetingQuietButtonStyle())
                .accessibilityLabel(
                    playback.playing ? "Pause" : (french ? "Lire l’audio" : "Play audio"))
                Slider(
                    value: Binding(
                        get: { min(playback.position, transcript.duration) }, set: playback.seek),
                    in: 0...max(1, transcript.duration)
                )
                .disabled(playback.player == nil)
                .accessibilityLabel(french ? "Position de lecture" : "Playback position")
                Text(SpeakerTranscript.timestamp(playback.position)).monospacedDigit().font(
                    .system(size: 10))
            }.padding(.horizontal, 14)
            if let error = playback.error {
                Text(error).font(.system(size: 11)).foregroundStyle(theme.warning).padding(
                    .horizontal, 18)
            }
            HStack {
                Text(
                    transcript.audioReference?.filename
                        ?? (french ? "Audio non relié" : "No audio linked")
                )
                .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(french ? "Relier" : "Link") { meetings.attachAudio(to: transcript.id) }
                    .buttonStyle(.plain).foregroundStyle(theme.cobalt)
            }.font(.system(size: 10)).foregroundStyle(theme.secondaryInk).padding(.horizontal, 18)
            TextField(
                french ? "Rechercher dans les échanges…" : "Search the conversation…", text: $search
            )
            .textFieldStyle(.roundedBorder).padding(.horizontal, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(turns) { turn in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(
                                        transcript.label(
                                            for: turn, prefix: french ? "Intervenant" : "Speaker",
                                            unknown: french
                                                ? "Voix incertaine" : "Uncertain speaker")
                                    )
                                    .lineLimit(1)
                                    Spacer()
                                    Button(SpeakerTranscript.timestamp(turn.start)) {
                                        playback.play(
                                            transcript.audioReference, at: turn.start,
                                            french: french)
                                    }.buttonStyle(.plain).foregroundStyle(theme.cobalt)
                                        .monospacedDigit()
                                }.font(.system(size: 10, weight: .medium))
                                Text(turn.text).font(.system(size: 13)).lineSpacing(4)
                                    .textSelection(.enabled)
                            }
                            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                sourceIDs.contains(turn.id)
                                    ? theme.cobaltSoft.opacity(0.5) : theme.surface,
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .id(turn.id)
                        }
                    }.padding(.horizontal, 14).padding(.bottom, 20)
                }
                .onChange(of: sourceIDs) { _, ids in
                    search = ""
                    if let id = ids.first { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear { if let id = sourceIDs.first { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(french ? "Vos notes personnelles" : "Your personal notes").font(
                .system(size: 14, weight: .medium))
            Text(
                french
                    ? "Ces notes restent distinctes des propos transcrits."
                    : "These notes are separate from the recorded conversation."
            )
            .font(.system(size: 11)).foregroundStyle(theme.secondaryInk)
            TextEditor(
                text: Binding(
                    get: { transcript.personalNotes ?? "" },
                    set: { text in
                        meetings.updateMeeting(transcript.id) { $0.personalNotes = text }
                    })
            )
            .font(.system(size: 14)).scrollContentBackground(.hidden)
            .frame(minHeight: 130).padding(8).background(
                theme.surface, in: RoundedRectangle(cornerRadius: 10))
            if !(transcript.markers ?? []).isEmpty {
                Text(french ? "Moments marqués" : "Bookmarked moments").font(
                    .system(size: 12, weight: .semibold))
                ScrollView {
                    ForEach(transcript.markers ?? []) { marker in
                        HStack {
                            Button(SpeakerTranscript.timestamp(marker.time)) {
                                playback.play(
                                    transcript.audioReference, at: marker.time, french: french)
                                tab = 0
                            }.buttonStyle(.plain).foregroundStyle(theme.cobalt)
                            TextField(
                                french ? "Ajouter une note…" : "Add a note…",
                                text: Binding(
                                    get: { marker.note },
                                    set: { text in
                                        meetings.updateMeeting(transcript.id) { record in
                                            if let i = record.markers?.firstIndex(where: {
                                                $0.id == marker.id
                                            }) {
                                                record.markers?[i].note = text
                                            }
                                        }
                                    }))
                        }.font(.system(size: 12)).padding(.vertical, 6)
                    }
                }.frame(maxHeight: 200)
            }
        }.padding(.horizontal, 18).padding(.bottom, 18)
    }

    private var actions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let tasks =
                    meetings.reports[transcript.id]?.content.blocks.filter { $0.kind == .task }
                    ?? []
                if tasks.isEmpty {
                    Text(
                        french
                            ? "Les actions du document apparaîtront ici. Vous pouvez transformer un paragraphe en action depuis la barre de mise en forme."
                            : "Document tasks appear here. Turn a paragraph into a task using the formatting bar."
                    )
                    .font(.system(size: 13)).foregroundStyle(theme.secondaryInk)
                }
                ForEach(tasks) { task in
                    Toggle(
                        isOn: Binding(
                            get: { task.checked },
                            set: { checked in
                                guard var content = meetings.reports[transcript.id]?.content,
                                    let index = content.blocks.firstIndex(where: {
                                        $0.id == task.id
                                    })
                                else { return }
                                content.blocks[index].checked = checked
                                meetings.updateDocument(content, for: transcript.id)
                            })
                    ) {
                        Text(task.text).font(.system(size: 13)).strikethrough(task.checked)
                    }.toggleStyle(.checkbox)
                }
            }.padding(18)
        }
    }
}
