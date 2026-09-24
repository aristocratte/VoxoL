@preconcurrency import AVFoundation
import Foundation

/// Extracts only audio tracks. No video frames enter the transcription pipeline.
public enum MeetingMedia {
    /// User-facing failures before model inference begins.
    public enum ImportError: LocalizedError {
        case noAudio, invalidDuration, unsupported

        /// Localized explanation of the rejected input.
        public var errorDescription: String? {
            switch self {
            case .noAudio: String(localized: "This file contains no audio track.")
            case .invalidDuration:
                String(localized: "Choose a non-empty recording up to one hour long.")
            case .unsupported: String(localized: "This media format could not be read.")
            }
        }
    }

    /// Mixes concurrent audio tracks (including microphone + call recordings).
    /// The temporary audio file is removed on success, failure and cancellation.
    public static func load(_ url: URL) async throws -> [Float] {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ImportError.noAudio }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0, duration.seconds <= 3600 else {
            throw ImportError.invalidDuration
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if tracks.count == 1, videoTracks.isEmpty {
            // Keep the original audio fast path lossless when AVAudioFile supports its container.
            do { return try SpeakerAudio.load(url) } catch is CancellationError {
                throw CancellationError()
            } catch { /* Audio-only MOV containers may still require extraction. */  }
        }
        let composition = AVMutableComposition()
        for source in tracks {
            try Task.checkCancellation()
            guard
                let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw ImportError.unsupported }
            let range = try await source.load(.timeRange)
            try track.insertTimeRange(range, of: source, at: range.start)
        }
        guard
            let export = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw ImportError.unsupported }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxol-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await export.export(to: temporary, as: .m4a)
        try Task.checkCancellation()
        return try SpeakerAudio.load(temporary)
    }
}
