import XCTest
import UniformTypeIdentifiers
@testable import DragWheel

final class FormatRegistryTests: DWTestCase {
    private let noTools = ToolLocator(searchDirectories: [], includePATH: false)

    private func registry(tools: ToolLocator? = nil) -> FormatRegistry {
        FormatRegistry.makeDefault(tools: tools ?? noTools)
    }

    private func ids(_ targets: [FormatTarget]) -> Set<String> { Set(targets.map(\.format.id)) }

    func testPNGTargetsExcludeItself() {
        let t = registry().targets(forTypes: [.png])
        XCTAssertEqual(ids(t), ["jpeg", "heic", "tiff", "gif", "bmp", "webp", "avif", "ico", "icns", "pdf", "txt"])
    }

    func testJPEGTargetsExcludeJPEGButIncludePNG() {
        let t = ids(registry().targets(forTypes: [.jpeg]))
        XCTAssertTrue(t.contains("png"))
        XCTAssertFalse(t.contains("jpeg"))
    }

    func testPDFTargets() {
        XCTAssertEqual(ids(registry().targets(forTypes: [.pdf])), ["png", "jpeg", "txt"])
        XCTAssertEqual(registry().resolve(type: .pdf, formatID: "txt")?.converter.id, "pdf")
    }

    func testDocumentTargets() {
        let docx = UTType("org.openxmlformats.wordprocessingml.document")!
        XCTAssertEqual(ids(registry().targets(forTypes: [docx])), ["txt", "rtf", "html", "odt", "pdf"])
        XCTAssertEqual(ids(registry().targets(forTypes: [.plainText])), ["rtf", "html", "docx", "odt", "pdf"])
        XCTAssertEqual(ids(registry().targets(forTypes: [.rtf])), ["txt", "html", "docx", "odt", "pdf"])
        XCTAssertEqual(ids(registry().targets(forTypes: [.html])), ["txt", "rtf", "docx", "odt", "pdf"])
        // Without LibreOffice, DOCX → PDF falls back to the built-in converter (available, not greyed out).
        let pdf = registry().targets(forTypes: [docx]).first { $0.format.id == "pdf" }
        XCTAssertEqual(pdf?.availability, .available)
        XCTAssertEqual(registry().resolve(type: docx, formatID: "pdf")?.converter.id, "document-pdf")
    }

    func testMarkdownOnlyConvertsToHTML() {
        let md = UTType("net.daringfireball.markdown")!
        XCTAssertEqual(ids(registry().targets(forTypes: [md])), ["html", "pdf"])
    }

    func testSourceCodeAndJSONAreNotTreatedAsPlainText() {
        XCTAssertTrue(registry().targets(forTypes: [UTType("public.swift-source")!]).isEmpty)
        XCTAssertTrue(registry().targets(forTypes: [.json]).isEmpty)
    }

    func testMultiFileIntersection() {
        let r = registry()
        // PNG + JPEG: everything except what only one of them offers, plus the batch targets.
        XCTAssertEqual(ids(r.targets(forTypes: [.png, .jpeg])),
                       ["heic", "tiff", "gif", "bmp", "webp", "avif", "ico", "icns", "pdf", "txt", "merge-pdf", "zip-all"])
        // Image + PDF: JPEG and TXT are common; both can be merged.
        XCTAssertEqual(ids(r.targets(forTypes: [.png, .pdf])), ["jpeg", "txt", "merge-pdf", "zip-all"])
        // Image + document: each can become its own PDF, or everything can be zipped together.
        XCTAssertEqual(ids(r.targets(forTypes: [.png, .plainText])), ["pdf", "zip-all"])
        // Video + document: nothing in common except zipping.
        XCTAssertEqual(ids(r.targets(forTypes: [.mpeg4Movie, .plainText])), ["zip-all"])
        XCTAssertTrue(r.targets(forTypes: []).isEmpty)
        // Batch targets need at least two items, and Merge PDF is the first slice.
        XCTAssertFalse(ids(r.targets(forTypes: [.png])).contains("merge-pdf"))
        XCTAssertEqual(r.targets(forTypes: [.pdf, .pdf]).first?.format.id, "merge-pdf")
    }

    func testFFmpegFormatsAreUnavailableWithoutFFmpeg() {
        let t = registry().targets(forTypes: [.mpeg4Movie])
        let mkv = t.first { $0.format.id == "mkv" }
        XCTAssertEqual(mkv?.availability, .unavailable(reason: "Install ffmpeg: brew install ffmpeg"))
        // AVFoundation fallback: MP4 → MOV and → M4A work without ffmpeg.
        XCTAssertEqual(t.first { $0.format.id == "mov" }?.availability, .available)
        XCTAssertEqual(t.first { $0.format.id == "m4a" }?.availability, .available)
        XCTAssertFalse(t.contains { $0.format.id == "mp4" })
        // Available targets sort before unavailable ones.
        let firstUnavailable = t.firstIndex { !$0.availability.isAvailable }!
        XCTAssertTrue(t[..<firstUnavailable].allSatisfy { $0.availability.isAvailable })
        XCTAssertTrue(t[firstUnavailable...].allSatisfy { !$0.availability.isAvailable })
    }

    func testVideoAndAudioTargetsWithFFmpegPresent() throws {
        let fake = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        let exe = fake.appendingPathComponent("ffmpeg")
        try "#!/bin/sh\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let r = registry(tools: ToolLocator(searchDirectories: [fake.path], includePATH: false))

        let video = r.targets(forTypes: [.mpeg4Movie])
        XCTAssertEqual(ids(video), ["mov", "mkv", "webm", "gif", "mp3", "m4a", "wav"])
        XCTAssertTrue(video.allSatisfy { $0.availability.isAvailable })

        let audio = r.targets(forTypes: [UTType(filenameExtension: "flac")!])
        XCTAssertEqual(ids(audio), ["mp3", "m4a", "wav", "aac", "ogg"])
        let mp3 = r.targets(forTypes: [.mp3])
        XCTAssertEqual(ids(mp3), ["m4a", "wav", "aac", "flac", "ogg"])
    }

    func testWebPAvailabilityDependsOnEncoder() {
        let without = registry().targets(forTypes: [.png]).first { $0.format.id == "webp" }
        XCTAssertEqual(without?.availability.isAvailable, false)
        XCTAssertEqual(without?.availability.reason, "Install a WebP encoder: brew install webp")
    }

    func testFoldersOfferZipAndMixedSelectionsOfferZipAll() throws {
        let folder = dir.appendingPathComponent("Folder.png", isDirectory: true) // image-like name must not matter
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = try Fixtures.png(at: url("a.png"))
        let r = registry()
        XCTAssertEqual(ids(r.targets(for: [folder])), ["zip"])
        XCTAssertEqual(ids(r.targets(for: [folder, file])), ["zip-all"])
        XCTAssertEqual(FormatRegistry.eligibleItems([folder, file, url("missing.png")]), [folder, file])
    }

    func testArchivesOfferExtractButDocumentsThatAreZipsDoNot() {
        XCTAssertEqual(ids(registry().targets(forTypes: [.zip])), ["extract"])
        XCTAssertEqual(ids(registry().targets(forTypes: [UTType(filenameExtension: "tgz")!])), ["extract"])
        let docx = UTType("org.openxmlformats.wordprocessingml.document")!
        XCTAssertFalse(ids(registry().targets(forTypes: [docx])).contains("extract"))
    }

    func testOfficeFormatsAreGreyedOutWithoutLibreOffice() {
        let pptx = registry().targets(forTypes: [UTType(filenameExtension: "pptx")!])
        XCTAssertEqual(ids(pptx), ["pdf", "odp"])
        XCTAssertTrue(pptx.allSatisfy { $0.availability == .unavailable(reason: LibreOfficeConverter.installHint) })
        XCTAssertEqual(ids(registry().targets(forTypes: [.commaSeparatedText])), ["xlsx", "ods"])
    }

    func testFilesWithoutExtensionAreSniffed() throws {
        let noExt = try Fixtures.png(at: url("mystery"))
        XCTAssertEqual(FileTypeResolver.contentType(of: noExt), .png)
        XCTAssertTrue(registry().targets(for: [noExt]).contains { $0.format.id == "jpeg" })

        let junk = url("junk")
        try Data([1, 2, 3, 4, 5, 6, 7, 8]).write(to: junk)
        XCTAssertTrue(registry().targets(for: [junk]).isEmpty)
    }

    func testNonexistentFileYieldsNoTargets() {
        XCTAssertTrue(registry().targets(for: [url("ghost.png")]).isEmpty)
    }

    func testResolvePrefersAvailableConverter() {
        let r = registry()
        XCTAssertEqual(r.resolve(type: .quickTimeMovie, formatID: "mp4")?.converter.id, "avfoundation")
        XCTAssertEqual(r.resolve(type: .png, formatID: "pdf")?.converter.id, "image")
        XCTAssertEqual(r.resolve(type: .pdf, formatID: "png")?.converter.id, "pdf")
        XCTAssertNil(r.resolve(type: .png, formatID: "docx"))
    }

    func testEveryCatalogSymbolExists() {
        for format in OutputFormat.all {
            XCTAssertNotNil(NSImage(systemSymbolName: format.symbolName, accessibilityDescription: nil), "\(format.id): missing SF Symbol \(format.symbolName)")
        }
    }

    func testCatalogIDsAreUnique() {
        XCTAssertEqual(Set(OutputFormat.all.map(\.id)).count, OutputFormat.all.count)
        XCTAssertEqual(Set(OutputFormat.all.map(\.commonness)).count, OutputFormat.all.count)
    }
}
