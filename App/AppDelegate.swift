import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var mainWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads a preference, including the SwiftUI views built
        // further down: registering after a read leaves that read on the old
        // default.
        DefaultSettings.register()

        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
            if arguments.contains("--product-audit-preview") {
                NSApplication.shared.setActivationPolicy(.regular)
                let requestedWidth = UserDefaults.standard.double(forKey: "voxol.auditWidth")
                let requestedHeight = UserDefaults.standard.double(forKey: "voxol.auditHeight")
                let previewSize = NSSize(
                    width: requestedWidth > 0 ? max(1100, requestedWidth) : 1320,
                    height: requestedHeight > 0 ? max(720, requestedHeight) : 800)
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: previewSize),
                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                    backing: .buffered, defer: false)
                window.title = "VoxoL — Product audit preview"
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.contentViewController = NSHostingController(
                    rootView: ProductAuditPreviewRoot())
                window.setContentSize(previewSize)
                mainWindowController = NSWindowController(window: window)
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                if let index = arguments.firstIndex(of: "--product-audit-screenshot"),
                    arguments.indices.contains(index + 1)
                {
                    let output = URL(fileURLWithPath: arguments[index + 1])
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        if let search = UserDefaults.standard.string(forKey: "voxol.auditSearch") {
                            window.makeFirstResponder(nil)
                            let event = NSEvent.keyEvent(
                                with: .keyDown, location: .zero, modifierFlags: .command,
                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                characters: "f", charactersIgnoringModifiers: "f",
                                isARepeat: false, keyCode: 3)
                            let handled =
                                event.map { window.performKeyEquivalent(with: $0) } ?? false
                            try? await Task.sleep(for: .milliseconds(150))
                            let editor = window.firstResponder as? NSTextView
                            print(
                                "AUDIT_SEARCH_FOCUS: shortcut=\(handled) fieldEditor=\(editor?.isFieldEditor == true)"
                            )
                            if editor?.isFieldEditor == true {
                                editor?.insertText(
                                    search, replacementRange: editor?.selectedRange() ?? NSRange())
                            }
                            try? await Task.sleep(for: .milliseconds(300))
                            if UserDefaults.standard.bool(forKey: "voxol.auditEscape"),
                                let escape = NSEvent.keyEvent(
                                    with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                    characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                    isARepeat: false, keyCode: 53)
                            {
                                window.sendEvent(escape)
                                try? await Task.sleep(for: .milliseconds(300))
                                print(
                                    "AUDIT_SEARCH_ESCAPE: empty=\(editor?.string.isEmpty == true)")
                            }
                        }
                        guard let view = window.contentView,
                            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                        else {
                            print("AUDIT_CAPTURE_FAILED: no native backing view")
                            NSApplication.shared.terminate(nil)
                            return
                        }
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        do {
                            guard let png = bitmap.representation(using: .png, properties: [:])
                            else {
                                throw CocoaError(.fileWriteUnknown)
                            }
                            try FileManager.default.createDirectory(
                                at: output.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
                            try png.write(to: output, options: .atomic)
                            print(
                                "AUDIT_CAPTURE: \(output.path) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)"
                            )
                        } catch {
                            print("AUDIT_CAPTURE_FAILED: \(error)")
                        }
                        NSApplication.shared.terminate(nil)
                    }
                }
                return
            }
            if arguments.contains("--speaker-preview") {
                NSApplication.shared.setActivationPolicy(.regular)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered, defer: false)
                window.title = "VoxoL — Speakers Preview"
                window.minSize = NSSize(width: 900, height: 620)
                window.contentViewController = NSHostingController(rootView: SpeakerPreviewRoot())
                mainWindowController = NSWindowController(window: window)
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                return
            }
        #endif
        if arguments.contains(CaptureProbeRunner.argument) {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task {
                await CaptureProbeRunner.runAndExit(arguments: arguments)
            }
            return
        }
        if arguments.contains(DictionaryImportRunner.argument) {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task {
                await DictionaryImportRunner.runAndExit(arguments: arguments)
            }
            return
        }
        if arguments.contains(PolisherSmokeRunner.argument) {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task {
                await PolisherSmokeRunner.runAndExit(arguments: arguments)
            }
            return
        }

        // A regular app: Dock icon, Cmd-Tab, a window you can find again after
        // clicking away. It was .accessory with LSUIElement set, which makes a
        // menu-bar-only utility — defensible for something you invoke by
        // hotkey, but it left no way to reach the app like any other, and the
        // menu-bar item stays either way.
        NSApplication.shared.setActivationPolicy(.regular)
        VoiceCapsuleController.shared.prepare()
        DictationSessionCoordinator.shared.activate()
        prepareMainWindow()

        // A copy installed on another Mac would otherwise never learn a newer
        // release exists unless the user happened to open Settings and press
        // the button. Check at launch, then keep checking.
        UpdateNotifier.shared.start()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 300)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                openMainWindow: { [weak self] in
                    self?.showMainWindow()
                },
                previewCapsule: {
                    VoiceCapsuleController.shared.playPreview()
                }
            )
        )
        self.popover = popover

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = VoxoLBrand.statusItemImage()
            button.image?.accessibilityDescription = "VoxoL"
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "VoxoL"
        }
        self.statusItem = statusItem

        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorder = MeetingRecorder.activeRecorder
        let meetings = MeetingsStore.activeStore
        let history = TranscriptStore.activeStore
        if let recorder, recorder.state != .recording && recorder.state != .paused {
            return .terminateCancel
        }
        guard
            recorder != nil || history?.hasUnprotectedChanges == true
                || meetings?.saveState == .saving || meetings?.saveState == .failed
        else { return .terminateNow }

        // Finish audio and both stores before allowing the process to exit.
        Task {
            await recorder?.stop()
            await meetings?.flushPendingSaves()
            await history?.flushPendingSaves()
            let saved = meetings?.saveState != .failed && history?.hasUnprotectedChanges != true
            sender.reply(toApplicationShouldTerminate: saved)
            if !saved {
                showMainWindow()
                let alert = NSAlert()
                alert.messageText = String(localized: "Some changes could not be saved")
                alert.informativeText = String(
                    localized:
                        "VoxoL has stayed open to protect your recent changes. Retry saving from the affected page before quitting."
                )
                alert.addButton(withTitle: String(localized: "Keep VoxoL open"))
                if let window = mainWindowController?.window {
                    alert.beginSheetModal(for: window) { _ in }
                }
            }
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        DictationSessionCoordinator.shared.deactivate()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func prepareMainWindow() {
        guard mainWindowController == nil else {
            return
        }

        // The Hub is a two-column reading interface: a sidebar, a page of results and a column of
        // numbers. Below roughly 1100 points the numbers fold away and the rows start truncating,
        // so that is the floor rather than a size anyone should have to discover by resizing.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "VoxoL"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 1_100, height: 720)
        window.isReleasedWhenClosed = false
        // The hosting controller is installed first on purpose: assigning it resizes the window
        // to SwiftUI's ideal size, which would undo any frame set before it.
        window.contentViewController = NSHostingController(rootView: MainRootView())

        // A remembered frame is restored the moment the autosave name is set, and it can be
        // smaller than the Hub needs — saved by an older build, or clamped by AppKit. The window
        // is grown back to a comfortable size measured against the screen actually available: a
        // hard-coded 880 points of height does not fit a 14-inch display once the menu bar and
        // the Dock are subtracted.
        window.setFrameAutosaveName("voxol.mainWindow")
        let usable =
            (window.screen ?? NSScreen.main)?.visibleFrame.size
            ?? NSSize(width: 1_440, height: 900)
        let preferredSize = NSSize(
            width: min(1_320, max(window.minSize.width, usable.width - 120)),
            height: min(900, max(window.minSize.height, usable.height - 48))
        )
        if window.frame.width < preferredSize.width || window.frame.height < preferredSize.height {
            window.setContentSize(preferredSize)
            window.center()
        }

        mainWindowController = NSWindowController(window: window)
    }

    private func showMainWindow() {
        prepareMainWindow()
        popover?.performClose(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}
