import AppKit
import SwiftUI
import Combine

struct JobRow: View {
    @ObservedObject var job: ConversionJob
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(job.displayName) → \(job.formatName)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.state == .queued || job.progress <= 0 {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                } else {
                    ProgressView(value: min(job.progress, 1)).progressViewStyle(.linear).controlSize(.small)
                }
            }
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel")
        }
    }
}

struct ProgressListView: View {
    @ObservedObject var manager: ConversionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Converting").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(manager.visibleJobs) { job in
                JobRow(job: job) { manager.cancel(job) }
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(VisualEffectBackground().clipShape(RoundedRectangle(cornerRadius: 14)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15)))
        .foregroundStyle(.white)
        .padding(8)
    }
}

/// Small floating progress indicator shown for long-running conversions.
@MainActor
final class ProgressPanelController {
    private let panel: WheelPanel
    private var cancellable: AnyCancellable?
    private let manager: ConversionManager

    init(manager: ConversionManager) {
        self.manager = manager
        panel = WheelPanel()
        panel.level = .floating
        let host = NSHostingView(rootView: ProgressListView(manager: manager))
        panel.contentView = host
        cancellable = manager.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func refresh() {
        guard !manager.visibleJobs.isEmpty else { panel.orderOut(nil); return }
        guard let host = panel.contentView as? NSHostingView<ProgressListView> else { return }
        let size = host.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 12, y: screen.visibleFrame.minY + 12)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}
