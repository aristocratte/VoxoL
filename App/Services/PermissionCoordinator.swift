import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Observation

enum VoxoLPermission: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case inputMonitoring

    var id: String { rawValue }
}

enum VoxoLPermissionStatus: Equatable {
    case notRequested
    case requesting
    case granted
    case denied
    case restricted
}

@MainActor
@Observable
final class PermissionCoordinator {
    static let shared = PermissionCoordinator()

    private(set) var microphone: VoxoLPermissionStatus = .notRequested
    private(set) var accessibility: VoxoLPermissionStatus = .notRequested
    private(set) var inputMonitoring: VoxoLPermissionStatus = .notRequested

    /// macOS answers `AXIsProcessTrusted` / `CGPreflightListenEventAccess` synchronously with the
    /// value from *before* the user replies to the system prompt. Without this, the row would flip
    /// to "denied" while the prompt is still on screen. We keep the request pending until the real
    /// state changes, or until the user has clearly walked away from it.
    @ObservationIgnored private var pendingSince: [VoxoLPermission: Date] = [:]

    private static let pendingTimeout: TimeInterval = 120

    var requiredPermissionsGranted: Bool {
        microphone == .granted && accessibility == .granted && inputMonitoring == .granted
    }

    var hasPendingRequest: Bool {
        !pendingSince.isEmpty || microphone == .requesting
    }

    /// Re-checks while a permission is still missing.
    ///
    /// macOS never tells an app that its authorisation changed, and granting
    /// one happens in System Settings — another app entirely. Without this the
    /// state was read once at launch and never again, so the only way to make
    /// the app notice a permission it already had was to quit and relaunch it.
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pollTimer: Timer?

    init() {
        refresh()
        // Coming back from System Settings is the moment the answer changed.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                PermissionCoordinator.shared.refresh()
                PermissionCoordinator.shared.startPolling()
            }
        }
        startPolling()
    }

    /// Accessibility and input monitoring can be granted without the app ever
    /// losing focus, so the activation notification alone would miss them. The
    /// poll stops as soon as nothing is outstanding, and this object lives for
    /// the process lifetime, so there is nothing to tear down.
    private func startPolling() {
        guard pollTimer == nil, !requiredPermissionsGranted else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                PermissionCoordinator.shared.pollOnce()
            }
        }
    }

    private func pollOnce() {
        refresh()
        guard requiredPermissionsGranted else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func status(for permission: VoxoLPermission) -> VoxoLPermissionStatus {
        switch permission {
        case .microphone:
            microphone
        case .accessibility:
            accessibility
        case .inputMonitoring:
            inputMonitoring
        }
    }

    func refresh() {
        if microphone != .requesting {
            microphone = Self.microphoneStatus()
        }
        accessibility = resolve(.accessibility, isGranted: AXIsProcessTrusted())
        inputMonitoring = resolve(.inputMonitoring, isGranted: CGPreflightListenEventAccess())
    }

    private func resolve(
        _ permission: VoxoLPermission,
        isGranted: Bool
    ) -> VoxoLPermissionStatus {
        guard !isGranted else {
            pendingSince[permission] = nil
            return .granted
        }
        if let started = pendingSince[permission] {
            guard Date().timeIntervalSince(started) > Self.pendingTimeout else {
                return .requesting
            }
            pendingSince[permission] = nil
        }
        return Self.wasRequested(permission) ? .denied : .notRequested
    }

    func request(_ permission: VoxoLPermission) async {
        switch permission {
        case .microphone:
            await requestMicrophone()
        case .accessibility:
            requestAccessibility()
        case .inputMonitoring:
            requestInputMonitoring()
        }
    }

    func openSystemSettings(for permission: VoxoLPermission) {
        let privacyPane: String
        switch permission {
        case .microphone:
            privacyPane = "Privacy_Microphone"
        case .accessibility:
            privacyPane = "Privacy_Accessibility"
        case .inputMonitoring:
            privacyPane = "Privacy_ListenEvent"
        }
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)"
            )
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func monitorChanges() async {
        while !Task.isCancelled {
            refresh()
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
    }

    private func requestMicrophone() async {
        let current = Self.microphoneStatus()
        guard current == .notRequested else {
            if current == .denied {
                openSystemSettings(for: .microphone)
            }
            microphone = current
            return
        }

        microphone = .requesting
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = Self.microphoneStatus()
    }

    private func requestAccessibility() {
        guard !AXIsProcessTrusted() else {
            pendingSince[.accessibility] = nil
            accessibility = .granted
            return
        }
        Self.rememberRequest(.accessibility)
        pendingSince[.accessibility] = Date()
        accessibility = .requesting
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    private func requestInputMonitoring() {
        guard !CGPreflightListenEventAccess() else {
            pendingSince[.inputMonitoring] = nil
            inputMonitoring = .granted
            return
        }
        Self.rememberRequest(.inputMonitoring)
        pendingSince[.inputMonitoring] = Date()
        inputMonitoring = .requesting
        _ = CGRequestListenEventAccess()
        refresh()
    }

    private static func microphoneStatus() -> VoxoLPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .notRequested
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .authorized:
            .granted
        @unknown default:
            .restricted
        }
    }

    private static func wasRequested(_ permission: VoxoLPermission) -> Bool {
        UserDefaults.standard.bool(forKey: requestKey(for: permission))
    }

    private static func rememberRequest(_ permission: VoxoLPermission) {
        UserDefaults.standard.set(true, forKey: requestKey(for: permission))
    }

    private static func requestKey(for permission: VoxoLPermission) -> String {
        "voxol.permissionRequested.\(permission.rawValue)"
    }
}
