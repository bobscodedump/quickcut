import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests load the app; don't start monitors / prompts then.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        controller = AppController()
        controller?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

/// Wires DragMonitor → WheelPanelController → ConversionManager and owns the menu bar item.
@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private let settings = SettingsStore.shared
    private let registry = FormatRegistry.makeDefault()
    private let notifications = NotificationService()
    private let recents = RecentConversions.shared
    private let wheel = WheelPanelController()
    private lazy var dragMonitor = DragMonitor(settings: settings)
    private lazy var manager = ConversionManager(registry: registry, settings: settings, notifier: notifications, recents: recents)
    private var progressPanel: ProgressPanelController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func start() {
        notifications.start()
        recents.ensureLogExists()
        progressPanel = ProgressPanelController(manager: manager)
        setUpStatusItem()

        wheel.onSelect = { [weak self] formatID, urls in self?.manager.convert(urls: urls, formatID: formatID) }

        dragMonitor.zoneForPoint = { [weak self] in self?.wheel.zone(for: $0) ?? .outside }
        dragMonitor.isOwnWindowAt = { point in
            NSApp.windows.contains { $0.isVisible && $0.frame.contains(point) }
        }
        dragMonitor.onShow = { [weak self] urls, location in self?.showWheel(for: urls, at: location) }
        dragMonitor.onHide = { [weak self] _ in self?.wheel.hide() }
        dragMonitor.start()

        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo") || args.contains("--demo-many") { runDemo(many: args.contains("--demo-many")) }
        if !args.contains("--no-permission-prompt") { PermissionService.promptIfNeeded() }
    }

    func stop() { dragMonitor.stop() }

    private func showWheel(for urls: [URL], at location: NSPoint) {
        let targets = registry.targets(for: urls)
        guard !targets.isEmpty else {
            wheel.presentMessage("No conversions available", at: location)
            return
        }
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        wheel.presentWheel(targets: targets, title: title, subtitle: "Drop on a format", at: location, settings: settings)
    }

    /// `--demo` shows a sample wheel for screenshots / manual checks. `--demo-many` shows the "More…" ring.
    private func runDemo(many: Bool) {
        let targets = many ? OutputFormat.all.map { FormatTarget(format: $0, availability: $0.id == "ogg" ? .unavailable(reason: FFmpegConverter.installHint) : .available) }
                           : registry.targets(forTypes: [.png])
        let center = NSPoint(x: (NSScreen.main?.frame.midX ?? 600), y: (NSScreen.main?.frame.midY ?? 400))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            wheel.presentWheel(targets: targets, title: "photo.png", subtitle: "Drop on a format", at: center, settings: settings)
            if many {
                wheel.model.hovered = SliceRef(ring: .secondary, index: 2)
                wheel.expand()
            } else {
                wheel.model.hovered = SliceRef(ring: .primary, index: 1)
            }
        }
        if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--demo-snapshot=") }) {
            let path = String(arg.dropFirst("--demo-snapshot=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
                wheel.snapshot(to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { NSApp.terminate(nil) }
    }

    // MARK: Menu bar

    private var enabledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var recentItem: NSMenuItem!
    private var permissionItem: NSMenuItem!

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = LemonGlyph.menuBarImage()
        let menu = NSMenu()
        menu.delegate = self

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        recentItem = NSMenuItem(title: "Recent Conversions", action: nil, keyEquivalent: "")
        recentItem.submenu = NSMenu()
        permissionItem = NSMenuItem(title: "", action: #selector(openPermissions), keyEquivalent: "")
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: "Quit DragWheel", action: #selector(quitApp), keyEquivalent: "q")

        [enabledItem, loginItem, .separator(), recentItem, settingsItem, .separator(), permissionItem, .separator(), quit]
            .forEach { menu.addItem($0!) }
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        enabledItem.state = settings.isEnabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        permissionItem.title = PermissionService.statusTitle
        permissionItem.action = PermissionService.isAccessibilityGranted ? nil : #selector(openPermissions)

        let submenu = recentItem.submenu!
        submenu.removeAllItems()
        let existing = recents.recentOutputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            let none = NSMenuItem(title: "No recent conversions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for url in existing {
            let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
            entry.representedObject = url
            entry.target = self
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let log = NSMenuItem(title: "Open Conversion Log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        submenu.addItem(log)
    }

    @objc private func toggleEnabled() { settings.isEnabled.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nInstall DragWheel in /Applications and try again."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func openLog() { NSWorkspace.shared.open(recents.logURL) }
    @objc private func openPermissions() { PermissionService.openAccessibilitySettings() }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings)))
            window.title = "DragWheel Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
