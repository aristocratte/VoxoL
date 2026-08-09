import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var mainWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
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
