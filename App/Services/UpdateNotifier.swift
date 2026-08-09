import AppKit
import Observation

/// Watches the release feed and tells the user when a newer version exists.
///
/// The About screen already had a manual "check for updates" button, but a
/// button nobody presses ships no update: a copy installed on another Mac would
/// sit on an old version indefinitely. This runs the same version comparison on
/// its own — at launch and periodically after — and exposes the result two
/// ways: a native alert the first time a version is seen, and a standing badge
/// in the sidebar for as long as the update is still waiting. The alert is easy
/// to dismiss by reflex; the badge is what remains.
///
/// It reports; it does not install. A true silent updater needs Sparkle plus a
/// notarised build so the downloaded app clears Gatekeeper on other machines,
/// and that is gated on an Apple Developer subscription. Until then, "download"
/// opens the release page and the user re-runs the installer.
@Observable
@MainActor
final class UpdateNotifier {
    static let shared = UpdateNotifier()

    /// The newer release, once one is found. Drives the sidebar badge.
    private(set) var available: UpdateCheck.Release?

    /// Set while a check is in flight, so a manual retry can show progress.
    private(set) var isChecking = false

    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private let lastNotifiedKey = "voxol.lastNotifiedUpdateVersion"

    // Long enough that the feed is never hammered, short enough that a machine
    // left running for days still notices a release the day it lands.
    @ObservationIgnored private let interval: Duration = .seconds(6 * 60 * 60)

    private init() {}

    /// Starts checking: once now, then on a slow repeating cycle.
    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(announce: true)
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Re-reads the feed. `announce` gates only the alert — the badge always
    /// follows the feed, so a manual check from Settings cannot leave the
    /// sidebar showing something stale.
    func check(announce: Bool) async {
        guard let feed = URL(string: UpdateFeed.releasesURL) else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: feed)
            let releases = try UpdateCheck.releases(fromGitHubJSON: data)
            let current = BugReportComposer.Environment.current().applicationVersion
            let update = UpdateCheck.availableUpdate(current: current, releases: releases)
            available = update
            guard announce, let update else { return }
            // One alert per version: the same prompt on every launch teaches
            // the user to dismiss it without reading, and the badge is already
            // carrying the message from then on.
            guard update.version != UserDefaults.standard.string(forKey: lastNotifiedKey)
            else { return }
            present(update)
        } catch {
            // A failed check — offline, rate limited — must never interrupt the
            // app, and must not clear a badge that was legitimately raised by
            // an earlier successful check.
        }
    }

    /// Opens the release page for the pending update.
    func openDownloadPage() {
        guard let available else { return }
        NSWorkspace.shared.open(available.url)
    }

    private func present(_ update: UpdateCheck.Release) {
        UserDefaults.standard.set(update.version, forKey: lastNotifiedKey)
        let alert = NSAlert()
        alert.messageText = "VoxoL \(update.version) est disponible"
        alert.informativeText =
            "Une nouvelle version est prête. Elle s'installe en glissant VoxoL "
            + "dans Applications, comme la première fois."
        alert.addButton(withTitle: "Télécharger")
        alert.addButton(withTitle: "Plus tard")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.url)
        }
    }
}
