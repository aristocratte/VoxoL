import AppKit
import Observation

/// Downloads and installs a release from inside the app.
///
/// The first updater opened the GitHub page and left the user to finish the
/// job in a browser and the Finder — five manual steps to apply a fix the app
/// already knew about. Sparkle would do this silently, but it needs a
/// notarised build and a signing key; everything short of that is possible
/// today: fetch the disk image, verify that what is inside is genuinely this
/// app signed by the same authority, swap it into place, relaunch.
///
/// Every failure falls back to the release page — the browser flow is the
/// safety net, not the product.
@MainActor
@Observable
final class UpdateInstaller {
    enum Phase: Equatable {
        case idle
        case downloading
        case installing
        case relaunching
        case failed(String)
    }

    static let shared = UpdateInstaller()

    private(set) var phase = Phase.idle
    private(set) var version = ""
    /// Download completion in [0, 1], nil while the size is unknown.
    private(set) var downloadProgress: Double?

    private var panel: NSPanel?

    private init() {}

    /// The update flow lives outside SwiftUI's string catalog (an alert and a floating panel),
    /// so it reads the interface language itself instead of always speaking French.
    /// Where this copy lives, so an app kept in ~/Applications is updated where it is rather
    /// than duplicated into /Applications. A copy running from a mounted disk image or from a
    /// translocated path cannot be replaced in place, so it installs into /Applications.
    nonisolated static var installedBundleURL: URL {
        let running = Bundle.main.bundleURL
        let path = running.path
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            return URL(fileURLWithPath: "/Applications/VoxoL.app")
        }
        return running
    }

    nonisolated static var french: Bool {
        UserDefaults.standard.string(forKey: "voxol.interfaceLanguage") == "fr"
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing, .relaunching: true
        case .idle, .failed: false
        }
    }

    /// Runs the full update: download, verify, swap, relaunch.
    func install(_ update: UpdateCheck.Release) async {
        guard !isBusy else { return }
        guard let diskImageURL = update.diskImageURL else {
            // No installable asset on the release — the page is all there is.
            NSWorkspace.shared.open(update.url)
            return
        }
        version = update.version
        presentPanel()
        do {
            phase = .downloading
            downloadProgress = nil
            // The download lands with a random name; hdiutil wants a .dmg.
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoxoL-\(update.version)-\(UUID().uuidString).dmg")
            try await downloadReportingProgress(from: diskImageURL, to: staged)
            defer { try? FileManager.default.removeItem(at: staged) }

            phase = .installing
            let announced = update.version
            let current = BugReportComposer.Environment.current().applicationVersion
            try await Task.detached(priority: .userInitiated) {
                try Self.installDiskImage(at: staged, announced: announced, current: current)
            }.value

            phase = .relaunching
            relaunch()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Falls back to the browser after a failure.
    func openReleasePage(_ update: UpdateCheck.Release?) {
        if let update {
            NSWorkspace.shared.open(update.url)
        }
        dismissPanel()
    }

    func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
        if case .failed = phase {
            phase = .idle
        }
    }

    /// Downloads with byte-level progress into `destination`.
    ///
    /// `URLSession.download(from:)` is one line but reports nothing until it
    /// is done; a silent ten-megabyte wait reads as a hang, and a user who
    /// thinks the updater hung force-quits it mid-replace. The delegate path
    /// costs the boilerplate below and buys the one thing a progress bar is
    /// for: proof of life.
    private func downloadReportingProgress(from url: URL, to destination: URL) async throws {
        let delegate = DownloadDelegate(destination: destination) { [weak self] progress in
            Task { @MainActor in self?.downloadProgress = progress }
        }
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        private let destination: URL
        private let onProgress: @Sendable (Double?) -> Void
        var continuation: CheckedContinuation<Void, Error>?

        init(destination: URL, onProgress: @escaping @Sendable (Double?) -> Void) {
            self.destination = destination
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else {
                onProgress(nil)
                return
            }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // The file at `location` is deleted the moment this returns, so
            // the move happens here or not at all.
            do {
                // A refusal arrives as a small error page, which would otherwise be saved as
                // the disk image and reported later as an image that cannot be opened.
                if let http = downloadTask.response as? HTTPURLResponse,
                    !(200..<300).contains(http.statusCode)
                {
                    throw InstallError.downloadRefused(http.statusCode)
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            if let error {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume()
            }
            continuation = nil
        }
    }

    // MARK: - The install itself, off the main thread

    private nonisolated static func installDiskImage(
        at imageURL: URL,
        announced: String,
        current: String
    ) throws {
        let mountPoint = try attach(imageURL)
        defer { detach(mountPoint) }

        let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw InstallError.noApplicationInImage
        }
        let mounted = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)

        // The checks that make self-replacement safe: what is about to be
        // installed must be this bundle, validly signed, by the same team.
        // `codesign --verify` walks the whole bundle, so a truncated download
        // also fails here. The team anchor matters most: a valid signature
        // plus the right bundle identifier proves integrity, not identity —
        // anyone can sign a bundle named com.voxol.VoxoL. The running app's
        // own team is the trust root, so the check needs no hardcoded value
        // and survives a future move to a Developer ID certificate.
        let identifier = try codesignField(of: mounted, field: "Identifier")
        guard identifier == Bundle.main.bundleIdentifier else {
            throw InstallError.wrongApplication(identifier)
        }
        let candidateTeam = try codesignField(of: mounted, field: "TeamIdentifier")
        let currentTeam = try? codesignField(of: Bundle.main.bundleURL, field: "TeamIdentifier")
        if let currentTeam, currentTeam != "not set" {
            guard candidateTeam == currentTeam else {
                throw InstallError.wrongTeam(candidateTeam)
            }
        }

        // Same team is not enough: an older build signed by that team, attached to a newer
        // tag, would install as an update and bring its defects back.
        let bundleVersion =
            Bundle(url: mounted)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard
            UpdateCheck.canInstall(
                bundleVersion: bundleVersion, over: current, announced: announced)
        else {
            throw InstallError.unexpectedVersion(bundleVersion)
        }

        let destination = installedBundleURL
        let staging = URL(
            fileURLWithPath: NSTemporaryDirectory()
        ).appendingPathComponent("VoxoL-staged-\(UUID().uuidString).app")
        try run("/bin/cp", ["-Rp", mounted.path, staging.path])
        // Downloads carry quarantine; a quarantined unnotarised app is exactly
        // the Gatekeeper prompt this installer exists to avoid. Clearing it is
        // legitimate here because the signature was just verified above.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])

        // Replace, keeping the old bundle until the new one is in place: the
        // running executable keeps working from its unlinked inode, and a
        // failure between the two moves leaves an app in the Trash rather
        // than none at all.
        let previous = URL(
            fileURLWithPath: NSTemporaryDirectory()
        ).appendingPathComponent("VoxoL-previous-\(UUID().uuidString).app")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: destination, to: previous)
        }
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            // Put the old app back rather than leaving /Applications empty.
            try? FileManager.default.moveItem(at: previous, to: destination)
            throw error
        }
        try? FileManager.default.removeItem(at: previous)
        _ = try? runCapturing(
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                + "LaunchServices.framework/Support/lsregister",
            ["-f", destination.path]
        )
    }

    private nonisolated static func attach(_ imageURL: URL) throws -> String {
        let output = try runCapturing(
            "/usr/bin/hdiutil",
            ["attach", imageURL.path, "-nobrowse", "-readonly", "-plist"]
        )
        guard
            let data = output.data(using: .utf8),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil
            ) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw InstallError.mountFailed
        }
        return mountPoint
    }

    private nonisolated static func detach(_ mountPoint: String) {
        _ = try? runCapturing("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"])
    }

    private nonisolated static func codesignField(
        of bundle: URL,
        field: String
    ) throws -> String {
        try run("/usr/bin/codesign", ["--verify", "--deep", bundle.path])
        let details = try runCapturing(
            "/usr/bin/codesign", ["-d", "--verbose=2", bundle.path],
            mergeStandardError: true
        )
        for line in details.split(whereSeparator: \.isNewline)
        where line.hasPrefix("\(field)=") {
            return String(line.dropFirst(field.count + 1))
        }
        throw InstallError.unreadableSignature
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.toolFailed(tool, process.terminationStatus)
        }
        return process.terminationStatus
    }

    private nonisolated static func runCapturing(
        _ tool: String,
        _ arguments: [String],
        mergeStandardError: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        if mergeStandardError {
            process.standardError = pipe
        }
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.toolFailed(tool, process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func relaunch() {
        // The delay lets this process exit before the new one starts, so the
        // fresh bundle is read from disk rather than the unlinked old inode.
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", Self.installedBundleURL.path]
        try? script.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Progress panel

    private func presentPanel() {
        guard panel == nil else {
            panel?.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 128),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = tr(Self.french, "Mise à jour", "Update")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(
            rootView: UpdateInstallerPanelView(installer: self)
        )
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    enum InstallError: LocalizedError {
        case noApplicationInImage
        case wrongApplication(String)
        case wrongTeam(String)
        case mountFailed
        case unreadableSignature
        case toolFailed(String, Int32)
        case downloadRefused(Int)
        case unexpectedVersion(String)

        var errorDescription: String? {
            let french = UpdateInstaller.french
            return switch self {
            case .noApplicationInImage:
                tr(
                    french, "Le téléchargement ne contient pas d’application.",
                    "The download does not contain an application.")
            case .wrongApplication(let identifier):
                tr(
                    french, "L’image contient « \(identifier) », pas VoxoL.",
                    "The image contains “\(identifier)”, not VoxoL.")
            case .wrongTeam(let team):
                tr(
                    french, "Le téléchargement est signé par une autre équipe (\(team)).",
                    "The download is signed by a different team (\(team)).")
            case .mountFailed:
                tr(
                    french, "L’image disque n’a pas pu être ouverte.",
                    "The disk image could not be opened.")
            case .unreadableSignature:
                tr(
                    french, "La signature du téléchargement est illisible.",
                    "The download’s signature could not be read.")
            case .toolFailed(let tool, let status):
                tr(
                    french,
                    "\(URL(fileURLWithPath: tool).lastPathComponent) a échoué (\(status)).",
                    "\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(status)).")
            case .downloadRefused(let status):
                tr(
                    french, "Le serveur a refusé le téléchargement (erreur \(status)).",
                    "The server refused the download (error \(status)).")
            case .unexpectedVersion(let version):
                tr(
                    french,
                    "Le téléchargement contient la version \(version.isEmpty ? "inconnue" : version), pas celle annoncée.",
                    "The download contains version \(version.isEmpty ? "unknown" : version), not the one announced."
                )
            }
        }
    }
}

import SwiftUI

/// The small floating card that narrates the install.
private struct UpdateInstallerPanelView: View {
    let installer: UpdateInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "VoxoL \(installer.version)")
                .font(.system(size: 13, weight: .semibold))
            switch installer.phase {
            case .idle:
                EmptyView()
            case .downloading:
                VStack(alignment: .leading, spacing: 6) {
                    if let progress = installer.downloadProgress {
                        ProgressView(value: progress)
                        Text(
                            verbatim: tr(
                                UpdateInstaller.french, "Téléchargement… \(Int(progress * 100)) %",
                                "Downloading… \(Int(progress * 100))%")
                        )
                        .font(.system(size: 12))
                    } else {
                        progressRow(tr(UpdateInstaller.french, "Téléchargement…", "Downloading…"))
                    }
                }
            case .installing:
                progressRow(
                    tr(
                        UpdateInstaller.french, "Installation dans Applications…",
                        "Installing into Applications…"))
            case .relaunching:
                progressRow(tr(UpdateInstaller.french, "Redémarrage…", "Restarting…"))
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        verbatim: tr(
                            UpdateInstaller.french, "La mise à jour intégrée a échoué : \(reason)",
                            "The built-in update failed: \(reason)")
                    )
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button {
                            installer.dismissPanel()
                        } label: {
                            Text(verbatim: tr(UpdateInstaller.french, "Fermer", "Close"))
                        }
                        Button {
                            installer.openReleasePage(UpdateNotifier.shared.available)
                        } label: {
                            Text(
                                verbatim: tr(
                                    UpdateInstaller.french, "Ouvrir la page de téléchargement",
                                    "Open the download page"))
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    // Verbatim on purpose: the alert this panel accompanies has no LocalizedStringKey path, so
    // both pick their words from the interface language at the call site.
    private func progressRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(verbatim: label).font(.system(size: 12))
        }
    }
}
