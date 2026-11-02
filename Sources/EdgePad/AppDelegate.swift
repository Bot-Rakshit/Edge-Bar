import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private let levels = LevelsModel()
    private let live = LiveState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var watcher: DeviceWatcher?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }
        Log.trimIfLarge()
        Log.write("EdgePad launched (accessibility: \(AXIsProcessTrusted() ? "yes" : "no"))")
        settings.applyAppearance()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = IconFactory.menuBarIcon()
            button.action = #selector(togglePopover)
            button.target = self
            button.toolTip = "EdgePad"
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuView(
            settings: settings, levels: levels,
            openSettings: { [weak self] in self?.openSettings() },
            openSetup: { [weak self] in self?.openSetup() },
            quit: { NSApp.terminate(nil) }))

        let manager = MultitouchManager.shared
        manager.apply(settings.engineConfig, magicMouse: settings.magicMouse)
        manager.start()
        settings.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                manager.apply(self.settings.engineConfig, magicMouse: self.settings.magicMouse)
            }
            .store(in: &cancellables)

        CursorFreeze.shared.installTapIfNeeded()
        ClickGuard.shared.installTapIfNeeded()
        live.$trusted
            .removeDuplicates()
            .sink { trusted in
                if trusted {
                    CursorFreeze.shared.installTapIfNeeded()
                    ClickGuard.shared.installTapIfNeeded()
                }
            }
            .store(in: &cancellables)

        // Haptic pings from scripts and agents: `EdgePad --buzz done`.
        DistributedNotificationCenter.default().addObserver(forName: .init("com.rakshit.edgepad.buzz"), object: nil, queue: .main) { [weak self] note in
            guard self?.settings.hapticPings == true else { return }
            let pattern = note.object as? String ?? "done"
            Log.write("haptic ping: \(pattern)")
            MultitouchManager.shared.performer.haptics.playPattern(pattern)
        }
        live.start()

        // Pick the trackpad back up after sleep or when a Magic Trackpad reconnects.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Log.write("woke from sleep, restarting devices")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MultitouchManager.shared.restart() }
        }
        watcher = DeviceWatcher {
            Log.write("multitouch devices changed, restarting")
            MultitouchManager.shared.restart()
        }
        watcher?.start()

        if !settings.hasCompletedSetup || !AXIsProcessTrusted() {
            openSetup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CursorFreeze.shared.end()
        MultitouchManager.shared.stop()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            levels.startPolling()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        levels.stopPolling()
    }

    private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, live: live, devices: MultitouchManager.shared.activeDevices,
                                    openSetup: { [weak self] in self?.openSetup() })
            settingsWindow = makeWindow(title: "EdgePad Settings", view: view)
        }
        show(settingsWindow)
    }

    private func openSetup() {
        popover.performClose(nil)
        if setupWindow == nil {
            let model = OnboardingModel(settings: settings)
            let view = OnboardingView(model: model, settings: settings, live: live, levels: levels, finish: { [weak self] in
                guard let self else { return }
                self.settings.hasCompletedSetup = true
                self.setupWindow?.close()
                // Point straight at where EdgePad lives from now on.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.togglePopover() }
            })
            let window = makeWindow(title: "Welcome to EdgePad", view: view)
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.center()
            setupWindow = window
        }
        show(setupWindow)
    }

    private func makeWindow<V: View>(title: String, view: V) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func show(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == settingsWindow { settingsWindow = nil }
        if window == setupWindow { setupWindow = nil }
    }
}
