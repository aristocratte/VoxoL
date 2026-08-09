import AppKit

/// Tells the user, on launch, when a newer release exists.
///
/// The About screen already has a manual "check for updates" button, but a
/// button nobody presses ships no update: a copy installed on another Mac
/// would sit on an old version indefinitely. This runs the same version
/// comparison automatically, once per launch, and surfaces the result as a
/// native alert — no notification permission, no dependency on the Hub UI.
///
/// It reports; it does not install. A true silent updater needs Sparkle plus a
/// notarised build so the downloaded app clears Gatekeeper on other machines,
/// and that is gated on an Apple Developer subscription. Until then, "download"
/// opens the release page and the user re-runs the installer — which, with the
/// correct feed URL, is the part that was actually broken.
@MainActor
enum UpdateNotifier {
    private static let lastNotifiedKey = "voxol.lastNotifiedUpdateVersion"

    /// Checks the release feed in the background and alerts if there is a newer
    /// version than the running build.
    static func checkOnLaunch() {
        Task { await check() }
    }

    static func check() async {
        guard let feed = URL(string: UpdateFeed.releasesURL) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: feed)
            let releases = try UpdateCheck.releases(fromGitHubJSON: data)
            let current = BugReportComposer.Environment.current().applicationVersion
            guard
                let update = UpdateCheck.availableUpdate(
                    current: current,
                    releases: releases
                )
            else { return }
            // One alert per version: seeing the same prompt on every launch
            // teaches the user to dismiss it without reading.
            guard
                update.version
                    != UserDefaults.standard.string(forKey: lastNotifiedKey)
            else { return }
            present(update)
        } catch {
            // A failed check — offline, rate limited — must never interrupt the
            // app. The manual button in Settings remains available.
        }
    }

    private static func present(_ update: UpdateCheck.Release) {
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
