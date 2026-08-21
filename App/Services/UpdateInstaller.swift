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

    private var panel: NSPanel?

    private init() {}

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
            let (downloaded, _) = try await URLSession.shared.download(from: diskImageURL)
            // The download lands with a random name; hdiutil wants a .dmg.
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoxoL-\(update.version)-\(UUID().uuidString).dmg")
            try FileManager.default.moveItem(at: downloaded, to: staged)
            defer { try? FileManager.default.removeItem(at: staged) }

            phase = .installing
            try await Task.detached(priority: .userInitiated) {
                try Self.installDiskImage(at: staged)
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

    // MARK: - The install itself, off the main thread

    private nonisolated static func installDiskImage(at imageURL: URL) throws {
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

        let destination = URL(fileURLWithPath: "/Applications/VoxoL.app")
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
        script.arguments = ["-c", "sleep 0.8; /usr/bin/open /Applications/VoxoL.app"]
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
        panel.title = "Mise à jour"
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

        var errorDescription: String? {
            switch self {
            case .noApplicationInImage:
                "Le téléchargement ne contient pas d'application."
            case .wrongApplication(let identifier):
                "L'image contient « \(identifier) », pas VoxoL."
            case .wrongTeam(let team):
                "Le téléchargement est signé par une autre équipe (\(team))."
            case .mountFailed:
                "L'image disque n'a pas pu être ouverte."
            case .unreadableSignature:
                "La signature du téléchargement est illisible."
            case .toolFailed(let tool, let status):
                "\(URL(fileURLWithPath: tool).lastPathComponent) a échoué (\(status))."
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
                progressRow("Téléchargement…")
            case .installing:
                progressRow("Installation dans Applications…")
            case .relaunching:
                progressRow("Redémarrage…")
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "La mise à jour intégrée a échoué : \(reason)")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button {
                            installer.dismissPanel()
                        } label: {
                            Text(verbatim: "Fermer")
                        }
                        Button {
                            installer.openReleasePage(UpdateNotifier.shared.available)
                        } label: {
                            Text(verbatim: "Ouvrir la page de téléchargement")
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    // Verbatim on purpose: the alert this panel accompanies is written in
    // French directly (NSAlert has no LocalizedStringKey path), and half-
    // localizing one flow is worse than none. Localize both together.
    private func progressRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(verbatim: label).font(.system(size: 12))
        }
    }
}
