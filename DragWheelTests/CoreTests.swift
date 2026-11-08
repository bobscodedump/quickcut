import XCTest
import UniformTypeIdentifiers
@testable import DragWheel

final class OutputReservationTests: DWTestCase {
    func testNumberingNeverOverwrites() throws {
        let r = OutputReservation(directory: dir, baseName: "photo")
        try "keep".write(to: url("photo.jpg"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try r.reserveFile(ext: "jpg").lastPathComponent, "photo 2.jpg")
        XCTAssertEqual(try r.reserveFile(ext: "jpg").lastPathComponent, "photo 3.jpg")
        XCTAssertEqual(try String(contentsOf: url("photo.jpg"), encoding: .utf8), "keep")
        XCTAssertEqual(try r.reserveFile(ext: "png").lastPathComponent, "photo.png")
    }

    func testRollbackOnlyRemovesOwnItems() throws {
        try "keep".write(to: url("a.jpg"), atomically: true, encoding: .utf8)
        let r = OutputReservation(directory: dir, baseName: "a")
        let mine = try r.reserveFile(ext: "jpg")
        let folder = try r.reserveDirectory()
        r.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("a.jpg").path))
    }

    func testConcurrentReservationsAreUnique() async throws {
        let names = await withTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<40 {
                group.addTask { [dir] in
                    (try? OutputReservation(directory: dir!, baseName: "same").reserveFile(ext: "png").lastPathComponent) ?? "ERR"
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(names).count, 40)
        XCTAssertFalse(names.contains("ERR"))
    }

    func testBaseNameOverride() throws {
        let r = OutputReservation(directory: dir, baseName: "ignored")
        XCTAssertEqual(try r.reserveFile(ext: "zip", baseName: "Tool.app").lastPathComponent, "Tool.app.zip")
        XCTAssertEqual(try r.reserveFile(ext: "zip", baseName: "Tool.app").lastPathComponent, "Tool.app 2.zip")
        XCTAssertEqual(try r.reserveDirectory(baseName: "photos").lastPathComponent, "photos")
    }

    func testExtensionlessAndFolderNames() throws {
        let r = OutputReservation(directory: dir, baseName: "README")
        XCTAssertEqual(try r.reserveFile(ext: "txt").lastPathComponent, "README.txt")
        XCTAssertEqual(try r.reserveDirectory().lastPathComponent, "README")
        XCTAssertEqual(try r.reserveDirectory().lastPathComponent, "README 2")
    }
}

final class OutputLocationResolverTests: DWTestCase {
    func testNextToOriginal() throws {
        let src = try Fixtures.png(at: url("a.png"))
        let loc = OutputLocationResolver.resolve(for: src, mode: .nextToOriginal, fixedFolder: nil)
        XCTAssertEqual(loc.directory.standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertNil(loc.note)
    }

    func testFixedFolder() throws {
        let fixed = url("out"); try FileManager.default.createDirectory(at: fixed, withIntermediateDirectories: true)
        let src = try Fixtures.png(at: url("a.png"))
        let loc = OutputLocationResolver.resolve(for: src, mode: .fixedFolder, fixedFolder: fixed)
        XCTAssertEqual(loc.directory, fixed)
        XCTAssertNil(loc.note)
    }

    func testMissingFixedFolderFallsBackNextToOriginal() throws {
        let src = try Fixtures.png(at: url("a.png"))
        let loc = OutputLocationResolver.resolve(for: src, mode: .fixedFolder, fixedFolder: url("nope"))
        XCTAssertEqual(loc.directory.standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertNotNil(loc.note)
    }

    func testReadOnlyFolderFallsBackToDownloadsWithNote() throws {
        let ro = url("readonly"); try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        let src = try Fixtures.png(at: ro.appendingPathComponent("locked.png"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro.path) }
        let downloads = url("Downloads"); try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        let loc = OutputLocationResolver.resolve(for: src, mode: .nextToOriginal, fixedFolder: nil, downloads: downloads)
        XCTAssertEqual(loc.directory, downloads)
        XCTAssertEqual(loc.note, "Saved to Downloads because readonly is read-only.")
    }
}

final class FileTypeResolverTests: DWTestCase {
    func testSniffing() throws {
        let png = try Fixtures.png(at: url("x1"))
        XCTAssertEqual(FileTypeResolver.sniff(png), .png)
        let pdf = try Fixtures.pdf(at: url("x2"), pages: ["a"])
        XCTAssertEqual(FileTypeResolver.sniff(pdf), .pdf)
        let wav = try Fixtures.wav(at: url("x3"))
        XCTAssertEqual(FileTypeResolver.sniff(wav), .wav)
        let jpeg = url("x4"); try Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]).write(to: jpeg)
        XCTAssertEqual(FileTypeResolver.sniff(jpeg), .jpeg)
        XCTAssertNil(FileTypeResolver.sniff(url("missing")))
    }

    func testConvertibleItems() throws {
        XCTAssertTrue(FileTypeResolver.isConvertibleItem(dir))
        XCTAssertTrue(FileTypeResolver.isConvertibleItem(try Fixtures.png(at: url("a.png"))))
        XCTAssertFalse(FileTypeResolver.isConvertibleItem(url("missing.png")))
        XCTAssertFalse(FileTypeResolver.isConvertibleItem(URL(string: "https://example.com/a.png")!))
    }

    func testSymlinkedFolderIsTypedAsFolder() throws {
        let link = url("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("..", isDirectory: true))
        XCTAssertEqual(FileTypeResolver.contentType(of: link)?.conforms(to: .directory), true)
    }
}

final class WheelLayoutTests: XCTestCase {
    private func targets(_ n: Int, unavailableFrom: Int = .max) -> [FormatTarget] {
        OutputFormat.all.prefix(n).enumerated().map { i, f in
            FormatTarget(format: f, availability: i >= unavailableFrom ? .unavailable(reason: "nope") : .available)
        }
    }

    func testUpToEightSlicesFitOnOneRing() {
        let (p, s) = WheelLayout.build(targets: targets(8), showUnavailable: true)
        XCTAssertEqual(p.count, 8); XCTAssertTrue(s.isEmpty)
        XCTAssertFalse(p.contains { $0.isMore })
    }

    func testMoreThanEightShowsSevenPlusMoreAndSecondRing() {
        let input = targets(12)
        let (p, s) = WheelLayout.build(targets: input, showUnavailable: true)
        XCTAssertEqual(p.count, 8)
        XCTAssertEqual(p.prefix(7).map(\.id), input.prefix(7).map(\.format.id))
        XCTAssertTrue(p[7].isMore)
        XCTAssertEqual(s.map(\.id), input.dropFirst(7).map(\.format.id))
    }

    func testHidingUnavailableFormats() {
        let (shown, _) = WheelLayout.build(targets: targets(6, unavailableFrom: 4), showUnavailable: true)
        XCTAssertEqual(shown.count, 6)
        XCTAssertEqual(shown.filter { !$0.isEnabled }.count, 2)
        XCTAssertEqual(shown.last?.disabledReason, "nope")
        let (hidden, _) = WheelLayout.build(targets: targets(6, unavailableFrom: 4), showUnavailable: false)
        XCTAssertEqual(hidden.count, 4)
        XCTAssertTrue(hidden.allSatisfy(\.isEnabled))
    }
}

final class WheelGeometryTests: XCTestCase {
    let g = WheelGeometry(scale: 1)
    let c = CGPoint(x: 300, y: 300)

    private func hit(_ dx: CGFloat, _ dy: CGFloat, n: Int = 4, m: Int = 3, expanded: Bool = false) -> SliceRef? {
        g.hit(point: CGPoint(x: c.x + dx, y: c.y + dy), center: c, primaryCount: n, secondaryCount: m, expanded: expanded)
    }

    func testSlicesAreLaidOutClockwiseFromTop() {
        XCTAssertEqual(hit(0, -100), SliceRef(ring: .primary, index: 0))   // 12 o'clock
        XCTAssertEqual(hit(100, 0), SliceRef(ring: .primary, index: 1))    // 3 o'clock
        XCTAssertEqual(hit(0, 100), SliceRef(ring: .primary, index: 2))    // 6 o'clock
        XCTAssertEqual(hit(-100, 0), SliceRef(ring: .primary, index: 3))   // 9 o'clock
    }

    func testHubAndOutsideAreNotSlices() {
        XCTAssertNil(hit(0, 0))
        XCTAssertNil(hit(0, -(g.innerRadius - 5)))
        XCTAssertNil(hit(0, -(g.outerRadius + 5)))
    }

    func testSecondaryRingOnlyWhenExpanded() {
        let dy = -(g.secondaryInner + g.secondaryOuter) / 2
        XCTAssertNil(hit(0, dy, expanded: false))
        XCTAssertEqual(hit(0, dy, expanded: true), SliceRef(ring: .secondary, index: 0))
        XCTAssertEqual(hit(-dy, 0.01, expanded: true), SliceRef(ring: .secondary, index: 1)) // 3 o'clock: 90° → index 1 of 3 (120° each, first centered on 0°)
    }

    func testSingleSliceCoversTheWholeRing() {
        XCTAssertEqual(hit(100, 0, n: 1), SliceRef(ring: .primary, index: 0))
        XCTAssertEqual(hit(-100, 0, n: 1), SliceRef(ring: .primary, index: 0))
    }

    func testScaleAffectsSizes() {
        let big = WheelGeometry(scale: 1.4)
        XCTAssertEqual(big.outerRadius, g.outerRadius * 1.4, accuracy: 0.001)
        XCTAssertGreaterThan(big.panelSide(expanded: false), g.panelSide(expanded: false))
        XCTAssertGreaterThan(g.panelSide(expanded: true), g.panelSide(expanded: false))
    }

    func testZones() {
        XCTAssertEqual(g.zone(distance: 10, expanded: false), .hub)
        XCTAssertEqual(g.zone(distance: 100, expanded: false), .ring)
        XCTAssertEqual(g.zone(distance: g.outerRadius + 40, expanded: false), .outside)
        XCTAssertEqual(g.zone(distance: g.outerRadius + 40, expanded: true), .ring)
    }

    func testSlicePathsStayWithinTheirRing() {
        let path = g.slicePath(ring: .primary, index: 2, count: 6, center: c)
        let box = path.boundingRect
        XCTAssertLessThanOrEqual(box.width, g.outerRadius * 2)
        for dx in stride(from: -200, through: 200, by: 20) {
            for dy in stride(from: -200, through: 200, by: 20) {
                let p = CGPoint(x: c.x + CGFloat(dx), y: c.y + CGFloat(dy))
                if path.contains(p) {
                    let r = hypot(CGFloat(dx), CGFloat(dy))
                    XCTAssertTrue(r >= g.innerRadius - 1 && r <= g.outerRadius + 1)
                    XCTAssertEqual(g.hit(point: p, center: c, primaryCount: 6, secondaryCount: 0, expanded: false), SliceRef(ring: .primary, index: 2))
                }
            }
        }
    }
}

final class WheelVisibilityPolicyTests: XCTestCase {
    func testShowsWhenTriggerPressed() {
        var p = WheelVisibilityPolicy()
        XCTAssertEqual(p.update(triggerDown: false, escapeDown: false, zone: .outside), .none)
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .outside), .show)
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .hub), .none, "already shown")
    }

    func testReleasingTriggerBeforeReachingSlicesDismisses() {
        var p = WheelVisibilityPolicy()
        _ = p.update(triggerDown: true, escapeDown: false, zone: .outside)
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .hub), .none)
        XCTAssertEqual(p.update(triggerDown: false, escapeDown: false, zone: .hub), .hide(.triggerReleased))
        // Pressing again re-shows.
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .hub), .show)
    }

    func testReleasingTriggerAfterReachingSlicesKeepsWheel() {
        var p = WheelVisibilityPolicy()
        _ = p.update(triggerDown: true, escapeDown: false, zone: .hub)
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .ring), .none)
        XCTAssertEqual(p.update(triggerDown: false, escapeDown: false, zone: .ring), .none)
        XCTAssertEqual(p.update(triggerDown: false, escapeDown: false, zone: .hub), .none)
    }

    func testLeavingTheWheelAfterReachingItDismissesUntilRetrigger() {
        var p = WheelVisibilityPolicy()
        _ = p.update(triggerDown: true, escapeDown: false, zone: .hub)
        _ = p.update(triggerDown: true, escapeDown: false, zone: .ring)
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .outside), .hide(.leftWheel))
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .outside), .none, "must not re-open while trigger still held")
        XCTAssertEqual(p.update(triggerDown: false, escapeDown: false, zone: .outside), .none)
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .outside), .show)
    }

    func testEscapeDismissesAndSuppressesUntilTriggerReleased() {
        var p = WheelVisibilityPolicy()
        _ = p.update(triggerDown: true, escapeDown: false, zone: .hub)
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: true, zone: .hub), .hide(.escape))
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .hub), .none)
        _ = p.update(triggerDown: false, escapeDown: false, zone: .hub)
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .hub), .show)
    }

    func testEscapeWhileHiddenPreventsShowing() {
        var p = WheelVisibilityPolicy()
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: true, zone: .outside), .none)
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .outside), .none)
    }

    func testDragEndHidesAndResets() {
        var p = WheelVisibilityPolicy()
        _ = p.update(triggerDown: true, escapeDown: false, zone: .hub)
        XCTAssertEqual(p.dragEnded(), .hide(.dragEnded))
        XCTAssertEqual(p.dragEnded(), .none)
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .hub), .show, "fresh state for the next drag")
    }

    func testMovingAwayWithTriggerHeldBeforeReachingSlicesKeepsWheel() {
        var p = WheelVisibilityPolicy()
        _ = p.update(triggerDown: true, escapeDown: false, zone: .hub)
        XCTAssertEqual(p.update(triggerDown: true, escapeDown: false, zone: .outside), .none)
        XCTAssertEqual(p.update(triggerDown: false, escapeDown: false, zone: .outside), .hide(.triggerReleased))
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "DragWheelTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testDefaults() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertTrue(s.isEnabled)
        XCTAssertEqual(s.outputMode, .nextToOriginal)
        XCTAssertEqual(s.triggerModifier, .shift)
        XCTAssertEqual(s.imageQuality, 0.85, accuracy: 0.001)
        XCTAssertEqual(s.wheelSize, 1.0, accuracy: 0.001)
        XCTAssertTrue(s.showUnavailable)
        XCTAssertNil(s.fixedFolderURL)
    }

    func testValuesPersist() {
        let defaults = freshDefaults()
        let s = SettingsStore(defaults: defaults)
        s.isEnabled = false; s.outputMode = .fixedFolder; s.fixedFolderPath = "/tmp/out"
        s.imageQuality = 0.5; s.triggerModifier = .option; s.wheelSize = 1.3; s.showUnavailable = false
        let again = SettingsStore(defaults: defaults)
        XCTAssertFalse(again.isEnabled)
        XCTAssertEqual(again.outputMode, .fixedFolder)
        XCTAssertEqual(again.fixedFolderURL?.path, "/tmp/out")
        XCTAssertEqual(again.conversionOptions.imageQuality, 0.5, accuracy: 0.001)
        XCTAssertEqual(again.triggerModifier, .option)
        XCTAssertEqual(again.triggerModifier.flags, .option)
        XCTAssertEqual(again.wheelSize, 1.3, accuracy: 0.001)
        XCTAssertFalse(again.showUnavailable)
    }

    func testOutOfRangeValuesAreClamped() {
        let d = freshDefaults()
        d.set(7.0, forKey: "wheelSize"); d.set(0.0, forKey: "imageQuality")
        let s = SettingsStore(defaults: d)
        XCTAssertEqual(s.wheelSize, 1.4, accuracy: 0.001)
        XCTAssertEqual(s.imageQuality, 0.1, accuracy: 0.001)
    }

    func testAllTriggerModifiersMapToDistinctFlags() {
        XCTAssertEqual(Set(TriggerModifier.allCases.map { $0.flags.rawValue }).count, 4)
    }
}
