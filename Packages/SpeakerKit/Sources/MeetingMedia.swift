@preconcurrency import AVFoundation
import Foundation

/// Extracts only audio tracks. No video frames enter the transcription pipeline.
public enum MeetingMedia {
    /// First-release import contract. Longer recordings are split by the caller.
    public static let maximumDurationSeconds: Double = 2 * 60 * 60

    /// A locally readable audio source kept alive across ASR and diarization.
    /// Temporary extracted audio is deleted explicitly by ``cleanup()``.
    public struct PreparedAudio: Sendable {
        public let url: URL
        public let durationSeconds: Double
        private let temporary: Bool

        fileprivate init(url: URL, durationSeconds: Double, temporary: Bool) {
            self.url = url
            self.durationSeconds = durationSeconds
            self.temporary = temporary
        }

        public func cleanup() {
            guard temporary else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// User-facing failures before model inference begins.
    public enum ImportError: LocalizedError {
        case noAudio, invalidDuration, unsupported

        /// Localized explanation of the rejected input.
        public var errorDescription: String? {
            switch self {
            case .noAudio: String(localized: "This file contains no audio track.")
            case .invalidDuration:
                String(localized: "Choose a non-empty recording up to two hours long.")
            case .unsupported: String(localized: "This media format could not be read.")
            }
        }
    }

    /// Produces one audio-only source without decoding video frames. Single-track
    /// audio stays on the original file; video or multi-track media is mixed into
    /// one temporary M4A that can be consumed incrementally by downstream models.
    public static func prepare(_ url: URL) async throws -> PreparedAudio {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ImportError.noAudio }
        let duration = try await asset.load(.duration)
        guard
            duration.seconds.isFinite,
            duration.seconds > 0,
            duration.seconds <= maximumDurationSeconds
        else {
            throw ImportError.invalidDuration
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if tracks.count == 1, videoTracks.isEmpty {
            // Keep the original audio fast path lossless when AVAudioFile supports its container.
            if (try? AVAudioFile(forReading: url)) != nil {
                return PreparedAudio(
                    url: url,
                    durationSeconds: duration.seconds,
                    temporary: false
                )
            }
            // Audio-only containers unsupported by AVAudioFile still go through extraction.
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
        do {
            try await export.export(to: temporary, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        try Task.checkCancellation()
        return PreparedAudio(
            url: temporary,
            durationSeconds: duration.seconds,
            temporary: true
        )
    }

    /// Compatibility loader for callers that still need a complete waveform.
    /// New long-form inference should prefer ``prepare(_:)`` and stream the file.
    public static func load(_ url: URL) async throws -> [Float] {
        let prepared = try await prepare(url)
        defer { prepared.cleanup() }
        try Task.checkCancellation()
        return try SpeakerAudio.load(prepared.url)
    }
}
