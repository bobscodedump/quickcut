import AppKit
import UserNotifications

struct BatchSummary {
    let formatName: String
    let succeeded: [URL]
    let failures: [(source: URL, message: String)]
    let notes: [String]
    var total: Int { succeeded.count + failures.count }
}

@MainActor
protocol ConversionNotifying: AnyObject {
    func batchFinished(_ summary: BatchSummary)
}

/// Native notifications; clicking one reveals the output in Finder.
@MainActor
final class NotificationService: NSObject, ConversionNotifying, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter traps when there is no real app bundle (e.g. command line tools).
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func batchFinished(_ summary: BatchSummary) {
        let content = UNMutableNotificationContent()
        let notes = summary.notes.isEmpty ? "" : "\n" + Set(summary.notes).sorted().joined(separator: "\n")

        if summary.failures.isEmpty {
            content.title = "Converted to \(summary.formatName)"
            if let only = summary.succeeded.first, summary.succeeded.count == 1 {
                content.body = "\(only.lastPathComponent) — click to reveal." + notes
            } else {
                content.body = "\(summary.succeeded.count) files converted — click to reveal." + notes
            }
        } else if summary.succeeded.isEmpty {
            content.title = "Conversion to \(summary.formatName) failed"
            let first = summary.failures[0]
            content.body = summary.failures.count == 1
                ? "\(first.source.lastPathComponent): \(first.message)"
                : "\(summary.failures.count) files failed. First error: \(first.message)"
        } else {
            content.title = "Converted \(summary.succeeded.count) of \(summary.total) to \(summary.formatName)"
            content.body = "\(summary.failures.count) failed: \(summary.failures[0].message)" + notes
        }
        content.sound = .default
        content.userInfo = ["paths": summary.succeeded.map(\.path)]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center?.add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let paths = response.notification.request.content.userInfo["paths"] as? [String] ?? []
        DispatchQueue.main.async {
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
