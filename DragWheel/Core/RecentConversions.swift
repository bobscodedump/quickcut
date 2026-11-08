import Foundation

/// Keeps the last conversions (for the menu) and appends a plain-text log.
final class RecentConversions: @unchecked Sendable {
    static let shared = RecentConversions()

    private let defaults: UserDefaults
    let logURL: URL
    private let maxItems = 10
    private let key = "recentOutputs"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, logURL: URL? = nil) {
        self.defaults = defaults
        self.logURL = logURL ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DragWheel/conversions.log")
    }

    var recentOutputs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func record(source: URL, output: URL, formatName: String) {
        lock.lock(); defer { lock.unlock() }
        var paths = defaults.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == output.path }
        paths.insert(output.path, at: 0)
        defaults.set(Array(paths.prefix(maxItems)), forKey: key)
        append("OK    \(source.path) -> \(output.path) [\(formatName)]")
    }

    func recordFailure(source: URL, formatName: String, message: String) {
        lock.lock(); defer { lock.unlock() }
        append("FAIL  \(source.path) -> \(formatName): \(message)")
    }

    private func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    func ensureLogExists() {
        if !FileManager.default.fileExists(atPath: logURL.path) { append("Log created") }
    }
}
