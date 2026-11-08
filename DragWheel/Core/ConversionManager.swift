import Foundation
import Combine

/// Counting semaphore for async code.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

@MainActor
final class ConversionJob: ObservableObject, Identifiable {
    enum State: Equatable { case queued, running, succeeded, failed(String), cancelled }

    let id = UUID()
    let source: URL
    let formatName: String
    /// What the progress panel shows ("photo.png", or "5 files" for a batch).
    let displayName: String
    @Published var progress: Double = 0
    @Published var state: State = .queued
    /// Becomes true once a job has been running for a while (drives the floating progress indicator).
    @Published var showsProgress = false
    var task: Task<Void, Never>?

    init(source: URL, formatName: String, displayName: String? = nil) {
        self.source = source
        self.formatName = formatName
        self.displayName = displayName ?? source.lastPathComponent
    }

    var isActive: Bool { state == .queued || state == .running }
}

@MainActor
final class ConversionManager: ObservableObject {
    @Published private(set) var jobs: [ConversionJob] = []

    private let registry: FormatRegistry
    private let settings: SettingsStore
    private let recents: RecentConversions
    private weak var notifier: ConversionNotifying?
    private let semaphore: AsyncSemaphore
    private var allTasks: [Task<Void, Never>] = []
    /// Delay before the floating progress indicator appears.
    var progressDelay: Duration = .seconds(1)

    init(registry: FormatRegistry, settings: SettingsStore, notifier: ConversionNotifying?, recents: RecentConversions = .shared, concurrency: Int = 3) {
        self.registry = registry
        self.settings = settings
        self.notifier = notifier
        self.recents = recents
        self.semaphore = AsyncSemaphore(limit: concurrency)
    }

    var visibleJobs: [ConversionJob] { jobs.filter { $0.showsProgress && $0.isActive } }

    private final class Batch {
        var outputs: [URL] = []
        var failures: [(source: URL, message: String)] = []
        var notes: [String] = []
        var remaining: Int
        init(remaining: Int) { self.remaining = remaining }
    }

    /// Converts each item to `formatID`, up to 3 at a time. Batch formats (Merge PDF, ZIP All) turn all
    /// items into a single output. Originals are never modified.
    func convert(urls: [URL], formatID: String) {
        let items = FormatRegistry.eligibleItems(urls)
        guard !items.isEmpty, let format = OutputFormat.format(withID: formatID) else { return }

        if let converter = registry.batchConverter(for: formatID) {
            let label = items.count == 1 ? items[0].lastPathComponent : "\(items.count) files"
            let job = ConversionJob(source: items[0], formatName: format.displayName, displayName: label)
            start(job, batch: Batch(remaining: 1)) { [weak self] in
                guard let self else { return .failure(CancellationError()) }
                return await self.performBatch(converter, items: items, job: job)
            }
            return
        }

        let batch = Batch(remaining: items.count)
        for url in items {
            let job = ConversionJob(source: url, formatName: format.displayName)
            start(job, batch: batch) { [weak self] in
                guard let self else { return .failure(CancellationError()) }
                return await self.perform(job: job, formatID: formatID)
            }
        }
    }

    private typealias Work = @MainActor () async -> Result<(URL, String?), Error>

    private func start(_ job: ConversionJob, batch: Batch, work: @escaping Work) {
        jobs.append(job)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(job: job, batch: batch, work: work)
        }
        job.task = task
        allTasks.append(task)
    }

    func cancel(_ job: ConversionJob) { job.task?.cancel() }

    /// Waits for every queued job (used by tests).
    func waitUntilIdle() async {
        while true {
            let pending = allTasks
            allTasks.removeAll()
            if pending.isEmpty { return }
            for task in pending { await task.value }
        }
    }

    private func run(job: ConversionJob, batch: Batch, work: Work) async {
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }

        var outcome: Result<(URL, String?), Error>
        if Task.isCancelled {
            outcome = .failure(CancellationError())
        } else {
            job.state = .running
            let delay = progressDelay
            Task { [weak self, weak job] in
                try? await Task.sleep(for: delay)
                guard let job, job.isActive else { return }
                job.showsProgress = true
                self?.objectWillChange.send()
            }
            outcome = await work()
        }

        switch outcome {
        case .success(let (output, note)):
            job.state = .succeeded
            batch.outputs.append(output)
            if let note { batch.notes.append(note) }
            recents.record(source: job.source, output: output, formatName: job.formatName)
        case .failure(let error):
            let isCancel = error is CancellationError
            let message = isCancel ? "Cancelled" : error.localizedDescription
            job.state = isCancel ? .cancelled : .failed(message)
            if !isCancel {
                batch.failures.append((job.source, message))
                recents.recordFailure(source: job.source, formatName: job.formatName, message: message)
            }
        }

        jobs.removeAll { $0.id == job.id }
        batch.remaining -= 1
        if batch.remaining == 0, !(batch.outputs.isEmpty && batch.failures.isEmpty) {
            notifier?.batchFinished(BatchSummary(formatName: job.formatName, succeeded: batch.outputs, failures: batch.failures, notes: batch.notes))
        }
    }

    private func performBatch(_ converter: any BatchConverter, items: [URL], job: ConversionJob) async -> Result<(URL, String?), Error> {
        for item in items {
            guard let type = FileTypeResolver.contentType(of: item), converter.accepts(type) else {
                return .failure(ConversionError.unsupported("\(item.lastPathComponent) can't be included in \(converter.format.displayName)."))
            }
        }
        if case .unavailable(let reason) = converter.availability() {
            return .failure(ConversionError.unsupported(reason))
        }
        let location = OutputLocationResolver.resolve(for: items[0], mode: settings.outputMode, fixedFolder: settings.fixedFolderURL)
        let reservation = OutputReservation(directory: location.directory, baseName: converter.outputBaseName(for: items))
        let options = settings.conversionOptions
        let work = Task.detached(priority: .userInitiated) { () -> URL in
            try await converter.convert(inputs: items, output: reservation, options: options) { value in
                Task { @MainActor [weak job] in job?.progress = value }
            }
        }
        do {
            let output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            return .success((output, location.note))
        } catch {
            reservation.rollback()
            return .failure(error)
        }
    }

    private func perform(job: ConversionJob, formatID: String) async -> Result<(URL, String?), Error> {
        let source = job.source
        guard let plan = registry.resolve(url: source, formatID: formatID) else {
            return .failure(ConversionError.unsupported("\(source.lastPathComponent) can't be converted to this format."))
        }
        if case .unavailable(let reason) = plan.converter.availability(of: plan.format) {
            return .failure(ConversionError.unsupported(reason))
        }
        let location = OutputLocationResolver.resolve(for: source, mode: settings.outputMode, fixedFolder: settings.fixedFolderURL)
        let reservation = OutputReservation(directory: location.directory, baseName: source.deletingPathExtension().lastPathComponent)
        let options = settings.conversionOptions
        let converter = plan.converter
        let format = plan.format

        let work = Task.detached(priority: .userInitiated) { () -> URL in
            try await converter.convert(input: source, to: format, output: reservation, options: options) { value in
                Task { @MainActor [weak job] in job?.progress = value }
            }
        }
        do {
            let output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            return .success((output, location.note))
        } catch {
            reservation.rollback()
            return .failure(error)
        }
    }
}
