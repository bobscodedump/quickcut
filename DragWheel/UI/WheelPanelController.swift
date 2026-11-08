import AppKit
import SwiftUI

/// Borderless, transparent, non-activating panel that floats above everything (including full-screen apps).
final class WheelPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Allow the expanded second ring to extend past the screen edge instead of being shoved back.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The wheel's content view. Registered once for file URLs; it routes drag events to the slice under the
/// cursor (each slice behaves as its own drop target: highlight on enter, un-highlight on exit, convert on drop).
final class WheelDropView: NSView {
    weak var model: WheelModel?
    var onHover: ((SliceRef?) -> Void)?
    var onDrop: ((SliceRef, [URL]) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    @MainActor private func slice(for info: NSDraggingInfo) -> SliceRef? {
        guard let model else { return nil }
        let point = convert(info.draggingLocation, from: nil)
        let g = WheelGeometry(scale: model.scale)
        return g.hit(
            point: point, center: CGPoint(x: bounds.midX, y: bounds.midY),
            primaryCount: model.primary.count, secondaryCount: model.secondary.count, expanded: model.expanded
        )
    }

    @MainActor private func update(_ info: NSDraggingInfo) -> NSDragOperation {
        let ref = slice(for: info)
        onHover?(ref)
        guard let slice = model?.slice(at: ref), slice.isEnabled, !slice.isMore else { return [] }
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { MainActor.assumeIsolated { update(sender) } }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { MainActor.assumeIsolated { update(sender) } }
    override func draggingExited(_ sender: NSDraggingInfo?) { MainActor.assumeIsolated { onHover?(nil) } }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let ref = slice(for: sender), let slice = model?.slice(at: ref), slice.isEnabled, !slice.isMore else { return false }
            let urls = DragMonitor.fileURLs(on: sender.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            onDrop?(ref, urls)
            return true
        }
    }
}

@MainActor
final class WheelPanelController {
    let model = WheelModel()
    private let panel = WheelPanel()
    private let dropView = WheelDropView(frame: .zero)
    private var anchor = CGPoint.zero
    private var hideToken = 0
    private var hoverExpandTask: Task<Void, Never>?
    private(set) var isVisible = false

    /// Called when a file is dropped on an enabled slice.
    var onSelect: ((String, [URL]) -> Void)?

    init() {
        let host = NSHostingView(rootView: WheelView(model: model))
        host.autoresizingMask = [.width, .height]
        dropView.autoresizingMask = [.width, .height]
        host.frame = dropView.bounds
        dropView.addSubview(host)
        dropView.model = model
        panel.contentView = dropView
        dropView.onHover = { [weak self] in self?.hoverChanged($0) }
        dropView.onDrop = { [weak self] ref, urls in self?.dropped(ref, urls) }
    }

    var windowFrame: NSRect? { isVisible ? panel.frame : nil }

    /// Renders the panel's own view hierarchy to a PNG (debug / `--demo-snapshot`; needs no screen-recording permission).
    func snapshot(to url: URL) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Cursor position relative to the wheel (drives the visibility policy).
    func zone(for point: NSPoint) -> WheelZone {
        guard isVisible else { return .outside }
        if model.message != nil { return .hub }
        let distance = hypot(point.x - anchor.x, point.y - anchor.y)
        return WheelGeometry(scale: model.scale).zone(distance: distance, expanded: model.expanded)
    }

    // MARK: Presenting

    func presentWheel(targets: [FormatTarget], title: String, subtitle: String, at mouse: NSPoint, settings: SettingsStore) {
        let layout = WheelLayout.build(targets: targets, showUnavailable: settings.showUnavailable)
        guard !layout.primary.isEmpty else { presentMessage("No conversions available", at: mouse); return }
        model.message = nil
        model.primary = layout.primary
        model.secondary = layout.secondary
        model.expanded = false
        model.hovered = nil
        model.scale = CGFloat(settings.wheelSize)
        model.centerTitle = title
        model.centerSubtitle = subtitle
        let side = WheelGeometry(scale: model.scale).panelSide(expanded: false)
        anchor = Self.clampedCenter(for: mouse, side: side)
        show(side: side)
    }

    func presentMessage(_ text: String, at mouse: NSPoint) {
        model.message = text
        model.primary = []
        model.secondary = []
        model.hovered = nil
        model.expanded = false
        anchor = CGPoint(x: mouse.x + 90, y: mouse.y - 40)
        show(size: NSSize(width: 260, height: 70), ignoreMouse: true)
    }

    private func show(side: CGFloat) { show(size: NSSize(width: side, height: side), ignoreMouse: false) }

    private func show(size: NSSize, ignoreMouse: Bool) {
        hideToken += 1
        panel.ignoresMouseEvents = ignoreMouse
        panel.setFrame(NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2, width: size.width, height: size.height), display: false)
        model.isPresented = false
        panel.orderFrontRegardless()
        isVisible = true
        DispatchQueue.main.async { [weak self] in self?.model.isPresented = true }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        hoverExpandTask?.cancel()
        hideToken += 1
        let token = hideToken
        model.isPresented = false
        model.hovered = nil
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard let self, self.hideToken == token else { return }
            self.panel.orderOut(nil)
            self.model.expanded = false
        }
    }

    // MARK: Hover / drop

    private func hoverChanged(_ ref: SliceRef?) {
        guard model.hovered != ref else { return }
        model.hovered = ref
        hoverExpandTask?.cancel()
        if let slice = model.slice(at: ref), slice.isMore, !model.expanded {
            hoverExpandTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self?.expand()
            }
        }
    }

    func expand() {
        guard !model.expanded, !model.secondary.isEmpty else { return }
        let side = WheelGeometry(scale: model.scale).panelSide(expanded: true)
        panel.setFrame(NSRect(x: anchor.x - side / 2, y: anchor.y - side / 2, width: side, height: side), display: true)
        model.expanded = true
    }

    private func dropped(_ ref: SliceRef, _ urls: [URL]) {
        guard let slice = model.slice(at: ref) else { return }
        onSelect?(slice.id, urls)
        hide()
    }

    private static func clampedCenter(for mouse: NSPoint, side: CGFloat) -> CGPoint {
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let half = side / 2
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo > hi ? (lo + hi) / 2 : min(max(v, lo), hi) }
        return CGPoint(x: clamp(mouse.x, visible.minX + half, visible.maxX - half), y: clamp(mouse.y, visible.minY + half, visible.maxY - half))
    }
}
