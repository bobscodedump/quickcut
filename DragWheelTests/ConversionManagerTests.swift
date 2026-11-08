import XCTest
import UniformTypeIdentifiers
@testable import DragWheel

/// Records how many conversions run at once.
private actor Gauge {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

private struct FakeConverter: Converter {
    let id = "fake"
    var inputTypes: [UTType] { [.plainText] }
    var delay: UInt64 = 0
    var gauge: Gauge?
    var failing = false

    func accepts(_ type: UTType) -> Bool { type == .plainText }
    func outputFormats(for input: UTType) -> [OutputFormat] { [.rtf] }

    func convert(input: URL, to format: OutputFormat, output: OutputReservation, options: ConversionOptions,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let out = try output.reserveFile(ext: format.fileExtension)
        await gauge?.enter()
        defer { Task { await gauge?.leave() } }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if failing { throw ConversionError.outputFailed("boom") }
        try Data("converted".utf8).write(to: out)
        progress(1)
        return out
    }
}

@MainActor
private final class RecordingNotifier: ConversionNotifying {
    var summaries: [BatchSummary] = []
    func batchFinished(_ summary: BatchSummary) { summaries.append(summary) }
}

@MainActor
final class ConversionManagerTests: DWTestCase {
    private var settings: SettingsStore!
    private var notifier: RecordingNotifier!
    private var recents: RecentConversions!

    override func setUpWithError() throws {
        try super.setUpWithError()
        MainActor.assumeIsolated {
            let suite = "DragWheelTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            settings = SettingsStore(defaults: defaults)
            notifier = RecordingNotifier()
            recents = RecentConversions(defaults: defaults, logURL: dir.appendingPathComponent("log/conversions.log"))
        }
    }

    private func manager(_ converter: FakeConverter, concurrency: Int = 3) -> ConversionManager {
        ConversionManager(registry: FormatRegistry(converters: [converter]), settings: settings, notifier: notifier, recents: recents, concurrency: concurrency)
    }

    private func textFile(_ name: String) throws -> URL {
        let u = url(name); try "hello".write(to: u, atomically: true, encoding: .utf8); return u
    }

    func testConvertsNextToOriginalAndKeepsOriginal() async throws {
        let src = try textFile("a.txt")
        let m = manager(FakeConverter())
        m.convert(urls: [src], formatID: "rtf")
        await m.waitUntilIdle()

        XCTAssertEqual(try String(contentsOf: url("a.rtf"), encoding: .utf8), "converted")
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "hello")
        XCTAssertEqual(notifier.summaries.count, 1)
        XCTAssertEqual(notifier.summaries[0].succeeded.map(\.lastPathComponent), ["a.rtf"])
        XCTAssertTrue(notifier.summaries[0].failures.isEmpty)
        XCTAssertTrue(m.jobs.isEmpty)
        XCTAssertEqual(recents.recentOutputs.map(\.lastPathComponent), ["a.rtf"])
        XCTAssertTrue(try String(contentsOf: recents.logURL, encoding: .utf8).contains("a.txt"))
    }

    func testRepeatedConversionsGetNumberedNames() async throws {
        let src = try textFile("b.txt")
        let m = manager(FakeConverter())
        for _ in 0..<3 { m.convert(urls: [src], formatID: "rtf"); await m.waitUntilIdle() }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".rtf") }), ["b.rtf", "b 2.rtf", "b 3.rtf"])
    }

    func testAtMostThreeConversionsRunConcurrently() async throws {
        let gauge = Gauge()
        let files = try (1...9).map { try textFile("f\($0).txt") }
        let m = manager(FakeConverter(delay: 120_000_000, gauge: gauge))
        m.convert(urls: files, formatID: "rtf")
        await m.waitUntilIdle()
        let peak = await gauge.peak
        XCTAssertEqual(peak, 3, "should run 3 at a time")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".rtf") }.count, 9)
        XCTAssertEqual(notifier.summaries.count, 1, "a batch produces a single summary notification")
        XCTAssertEqual(notifier.summaries[0].succeeded.count, 9)
    }

    func testFailureIsReportedAndLeavesNoPlaceholder() async throws {
        let src = try textFile("c.txt")
        let m = manager(FakeConverter(failing: true))
        m.convert(urls: [src], formatID: "rtf")
        await m.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("c.rtf").path))
        XCTAssertEqual(notifier.summaries.count, 1)
        XCTAssertEqual(notifier.summaries[0].failures.first?.message, "boom")
        XCTAssertTrue(notifier.summaries[0].succeeded.isEmpty)
        XCTAssertTrue(try String(contentsOf: recents.logURL, encoding: .utf8).contains("FAIL"))
    }

    func testDirectoriesAndUnsupportedFilesAreIgnored() async throws {
        let folder = url("folder.txt"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let m = manager(FakeConverter())
        m.convert(urls: [folder], formatID: "rtf")
        await m.waitUntilIdle()
        XCTAssertTrue(notifier.summaries.isEmpty)

        let png = try Fixtures.png(at: url("x.png"))
        m.convert(urls: [png], formatID: "rtf")
        await m.waitUntilIdle()
        XCTAssertEqual(notifier.summaries.first?.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("x.rtf").path))
    }

    func testFixedFolderOutput() async throws {
        let out = url("elsewhere"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        settings.outputMode = .fixedFolder
        settings.fixedFolderPath = out.path
        let src = try textFile("d.txt")
        let m = manager(FakeConverter())
        m.convert(urls: [src], formatID: "rtf")
        await m.waitUntilIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("d.rtf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("d.rtf").path))
    }

    func testMixedBatchReportsPartialSuccess() async throws {
        let good = try textFile("ok.txt")
        let bad = try Fixtures.png(at: url("img.png")) // FakeConverter rejects PNG
        let m = manager(FakeConverter())
        m.convert(urls: [good, bad], formatID: "rtf")
        await m.waitUntilIdle()
        XCTAssertEqual(notifier.summaries.count, 1)
        XCTAssertEqual(notifier.summaries[0].succeeded.count, 1)
        XCTAssertEqual(notifier.summaries[0].failures.count, 1)
    }

    func testRealPipelineEndToEnd() async throws {
        let png = try Fixtures.png(at: url("pic.png"))
        let pdf = try Fixtures.pdf(at: url("doc.pdf"), pages: ["x"])
        let m = ConversionManager(registry: .makeDefault(), settings: settings, notifier: notifier, recents: recents)
        m.convert(urls: [png, pdf], formatID: "jpeg")
        await m.waitUntilIdle()
        XCTAssertEqual(notifier.summaries.first?.succeeded.count, 2)
        XCTAssertEqual(imageInfo(url("pic.jpg"))?.type, "public.jpeg")
        XCTAssertEqual(imageInfo(url("doc.jpg"))?.type, "public.jpeg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path) && FileManager.default.fileExists(atPath: pdf.path))
    }
}
