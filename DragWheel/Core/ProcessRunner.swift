import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Thread-safe accumulator that also splits stdout into lines.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = ""
    private let lineHandler: (@Sendable (String) -> Void)?

    init(lineHandler: (@Sendable (String) -> Void)?) { self.lineHandler = lineHandler }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        data.append(chunk)
        if lineHandler != nil {
            pending += String(decoding: chunk, as: UTF8.self)
            while let range = pending.range(of: "\n") {
                lines.append(String(pending[..<range.lowerBound]))
                pending.removeSubrange(..<range.upperBound)
            }
        }
        lock.unlock()
        lines.forEach { lineHandler?($0) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Tracks launch / cancellation so `terminate()` is never sent to an unlaunched process.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var launched = false
    private(set) var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if launched, process.isRunning { process.terminate() }
    }

    /// Returns false if already cancelled.
    func launch() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        try process.run()
        launched = true
        return true
    }
}

enum ProcessRunner {
    /// Runs an executable without blocking a cooperative thread. Cancelling the task terminates the process.
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = OutputCollector(lineHandler: onStdoutLine)
        let err = OutputCollector(lineHandler: nil)
        outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = try? outPipe.fileHandleForReading.readToEnd() { out.append(rest) }
                    if let rest = try? errPipe.fileHandleForReading.readToEnd() { err.append(rest) }
                    if box.cancelled {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume(returning: ProcessResult(status: proc.terminationStatus, stdout: out.text, stderr: err.text))
                    }
                }
                do {
                    if try !box.launch() {
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        cont.resume(throwing: CancellationError())
                    }
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}
