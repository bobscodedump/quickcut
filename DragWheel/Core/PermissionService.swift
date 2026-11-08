import AppKit
import ApplicationServices

/// DragWheel detects drags with global mouse monitors and polls `NSEvent.modifierFlags`, which need no
/// permission. Accessibility is *optional*: it lets macOS deliver global key events (instant Shift/Esc
/// reaction). This service reports the status and offers a shortcut to the right System Settings pane.
@MainActor
enum PermissionService {
    static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let inputMonitoringPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
    private static let suppressKey = "suppressAccessibilityPrompt"

    static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    static var statusTitle: String {
        isAccessibilityGranted ? "Accessibility: Granted ✓" : "Accessibility: Not granted — click to open Settings"
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(accessibilityPane)
    }

    /// Called at launch. Shows an explanatory prompt (with a button to the right pane) if not trusted.
    static func promptIfNeeded() {
        guard !isAccessibilityGranted, !UserDefaults.standard.bool(forKey: suppressKey) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Grant Accessibility access to DragWheel"
        alert.informativeText = """
        DragWheel watches for the trigger key while you drag files. Without Accessibility access it falls back \
        to polling, which works but may react a moment late to Shift and Esc.

        Click “Open System Settings”, enable DragWheel under Privacy & Security → Accessibility, then relaunch the app. \
        If the entry is already listed, remove it and add it again (rebuilt ad-hoc signed apps lose the grant).
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't remind me again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressKey) }
        if response == .alertFirstButtonReturn { openAccessibilitySettings() }
    }
}
