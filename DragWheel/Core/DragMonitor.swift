import AppKit
import ApplicationServices

/// Detects "files are being dragged" and tells its owner when to show / hide the wheel.
///
/// Detection: global monitors for mouse down / dragged / up. A file drag is in progress when the drag
/// pasteboard's changeCount changed since mouse-down and it holds file URLs. Because global monitors
/// don't see events while the cursor is over our own wheel, a 30 Hz timer additionally polls the
/// mouse buttons, modifier flags and cursor location — none of which require any permission.
@MainActor
final class DragMonitor {
    private enum Phase {
        case idle
        case pressed(changeCount: Int)
        case ignored
        case fileDrag(urls: [URL])
    }

    private let settings: SettingsStore
    private var monitors: [Any] = []
    private var timer: Timer?
    private var phase: Phase = .idle
    private var policy = WheelVisibilityPolicy()

    /// Trigger pressed during a file drag: show the wheel for these files at this screen location.
    var onShow: (([URL], NSPoint) -> Void)?
    var onHide: ((WheelVisibilityPolicy.HideReason) -> Void)?
    /// Where the cursor is relative to the wheel.
    var zoneForPoint: ((NSPoint) -> WheelZone)?
    /// True if the location is on one of our own windows (drags starting there are ignored).
    var isOwnWindowAt: ((NSPoint) -> Bool)?

    init(settings: SettingsStore) { self.settings = settings }

    func start() {
        guard monitors.isEmpty else { return }
        // Mouse events need no permission. Key-type events (flagsChanged / keyDown) would trigger the Input
        // Monitoring prompt, so they're only added when Accessibility is already granted; otherwise the
        // 30 Hz poll (NSEvent.modifierFlags, CGEventSource.keyState) covers Shift and Esc.
        var mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if AXIsProcessTrusted() { mask.formUnion([.flagsChanged, .keyDown]) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type) }
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        endDrag()
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown: beginPress()
        case .leftMouseUp: endDrag()
        default: tick()
        }
    }

    private func beginPress() {
        endDrag()
        guard settings.isEnabled else { return }
        let location = NSEvent.mouseLocation
        if isOwnWindowAt?(location) == true { phase = .ignored; startTimer(); return }
        phase = .pressed(changeCount: NSPasteboard(name: .drag).changeCount)
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func endDrag() {
        timer?.invalidate()
        timer = nil
        if case .idle = phase { return }
        phase = .idle
        if case .hide(let reason) = policy.dragEnded() { onHide?(reason) }
    }

    private func tick() {
        if case .idle = phase { return }
        if !settings.isEnabled { endDrag(); return }
        if NSEvent.pressedMouseButtons & 1 == 0 { endDrag(); return }

        if case .pressed(let changeCount) = phase {
            let pasteboard = NSPasteboard(name: .drag)
            guard pasteboard.changeCount != changeCount else { return }
            let urls = Self.fileURLs(on: pasteboard)
            phase = urls.isEmpty ? .ignored : .fileDrag(urls: urls)
        }
        guard case .fileDrag(let urls) = phase else { return }

        let location = NSEvent.mouseLocation
        let triggerDown = NSEvent.modifierFlags.contains(settings.triggerModifier.flags)
        let escapeDown = CGEventSource.keyState(.combinedSessionState, key: 53)
        let zone = zoneForPoint?(location) ?? .outside

        switch policy.update(triggerDown: triggerDown, escapeDown: escapeDown, zone: zone) {
        case .none: break
        case .show: onShow?(urls, location)
        case .hide(let reason): onHide?(reason)
        }
    }

    /// File and folder URLs on the drag pasteboard.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return FormatRegistry.eligibleItems(objects.map { URL(fileURLWithPath: $0.path) })
    }
}
