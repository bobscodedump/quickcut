import XCTest
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import DragWheel

// MARK: - AVIF / ICO / ICNS

final class IconAndAVIFTests: DWTestCase {
    let converter = ImageConverter()

    private func frames(_ url: URL) -> [(Int, Int)] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(src)).compactMap { i in
            guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return nil }
            return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
    }

    func testAVIF() async throws {
        try XCTSkipUnless(ImageCodec.canEncodeNatively("avif"))
        let src = try Fixtures.png(at: url("pic.png"))
        let out = try await convert(converter, src, to: .avif)
        XCTAssertEqual(out.lastPathComponent, "pic.avif")
        let info = try XCTUnwrap(imageInfo(out))
        XCTAssertEqual(info.type, "public.avif")
        XCTAssertEqual(info.width, 64); XCTAssertEqual(info.height, 48)
    }

    func testICOHasSquareSizesUpTo256() async throws {
        let src = try Fixtures.png(at: url("logo.png"), width: 600, height: 300, alpha: true)
        let out = try await convert(converter, src, to: .ico)
        XCTAssertEqual(imageInfo(out)?.type, "com.microsoft.ico")
        let f = frames(out)
        XCTAssertGreaterThanOrEqual(f.count, 5)
        XCTAssertTrue(f.allSatisfy { $0.0 == $0.1 && $0.0 <= 256 }, "\(f)")
        XCTAssertTrue(f.contains { $0.0 == 256 })
    }

    func testICNSFromNonSquareImage() async throws {
        let src = try Fixtures.png(at: url("app.png"), width: 1024, height: 700)
        let out = try await convert(converter, src, to: .icns)
        XCTAssertEqual(imageInfo(out)?.type, "com.apple.icns")
        let f = frames(out)
        XCTAssertGreaterThanOrEqual(f.count, 4)
        XCTAssertTrue(f.allSatisfy { $0.0 == $0.1 }, "\(f)")
    }

    func testTinyImageStillProducesAnIcon() async throws {
        let src = try Fixtures.png(at: url("tiny.png"), width: 10, height: 10)
        let out = try await convert(converter, src, to: .ico)
        XCTAssertEqual(frames(out).map(\.0), [16])
    }
}

// MARK: - OCR

final class OCRTests: DWTestCase {
    func testImageToText() async throws {
        let src = try Fixtures.textImage(at: url("sign.png"), text: "HELLO DRAGWHEEL 2026")
        let out = try await convert(ImageConverter(), src, to: .txt)
        XCTAssertEqual(out.lastPathComponent, "sign.txt")
        let text = try String(contentsOf: out, encoding: .utf8).uppercased()
        XCTAssertTrue(text.contains("HELLO"), text)
        XCTAssertTrue(text.contains("DRAGWHEEL"), text)
    }

    func testScannedPDFToTextFallsBackToOCR() async throws {
        let png = try Fixtures.textImage(at: url("scan.png"), text: "INVOICE NUMBER 4711")
        let pdf = try await convert(ImageConverter(), png, to: .pdf)
        XCTAssertEqual((PDFDocument(url: pdf)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "", "fixture must have no text layer")
        let out = try await convert(PDFConverter(), pdf, to: .txt)
        let text = try String(contentsOf: out, encoding: .utf8).uppercased()
        XCTAssertTrue(text.contains("INVOICE"), text)
        XCTAssertTrue(text.contains("4711"), text)
    }

    func testImageWithoutTextFailsCleanly() async throws {
        let src = try Fixtures.png(at: url("blank.png"), width: 200, height: 200)
        do {
            _ = try await convert(ImageConverter(), src, to: .txt)
            XCTFail("expected noText")
        } catch let error as ConversionError {
            guard case .noText = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("blank.txt").path))
    }

    func testLineAssemblyOrder() {
        // Vision boxes: origin bottom-left, so higher y = earlier line.
        let items: [(box: CGRect, text: String)] = [
            (CGRect(x: 0.5, y: 0.80, width: 0.2, height: 0.05), "world"),
            (CGRect(x: 0.1, y: 0.40, width: 0.2, height: 0.05), "second"),
            (CGRect(x: 0.1, y: 0.81, width: 0.2, height: 0.05), "hello"),
        ]
        XCTAssertEqual(TextRecognizer.assemble(items), "hello world\nsecond")
    }
}

// MARK: - Documents → PDF

final class DocumentPDFTests: DWTestCase {
    let converter = DocumentPDFConverter()
    let marker = "DragWheel marker 4711"

    private func pdfText(_ url: URL) -> String { PDFDocument(url: url)?.string ?? "" }

    func testEveryDocumentTypeToSearchablePDF() async throws {
        let txt = url("doc.txt")
        try marker.write(to: txt, atomically: true, encoding: .utf8)
        // Make RTF / DOCX / ODT / HTML fixtures with textutil.
        var inputs = [txt]
        for format in [OutputFormat.rtf, .docx, .odt] {
            let made = try await convert(DocumentConverter(), txt, to: format)
            let renamed = url("from-\(format.id).\(format.fileExtension)")
            try FileManager.default.moveItem(at: made, to: renamed)
            inputs.append(renamed)
        }
        let html = url("page.html")
        try "<html><body><h1>Title</h1><p>\(marker)</p></body></html>".write(to: html, atomically: true, encoding: .utf8)
        let md = url("notes.md")
        try "# Notes\n\nSome **bold** text: \(marker)\n".write(to: md, atomically: true, encoding: .utf8)
        inputs += [html, md]

        for input in inputs {
            let out = try await convert(converter, input, to: .pdf)
            XCTAssertEqual(out.pathExtension, "pdf")
            XCTAssertTrue(pdfText(out).contains(marker), "\(input.lastPathComponent): \(pdfText(out))")
        }
    }

    func testLongDocumentIsPaginated() async throws {
        let txt = url("long.txt")
        let lines = (1...400).map { "Line number \($0) of a long document." }
        try lines.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
        let out = try await convert(converter, txt, to: .pdf)
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertGreaterThan(doc.pageCount, 3)
        XCTAssertTrue(doc.string?.contains("Line number 400") == true, "no text may be lost at the end")
        let size = doc.page(at: 0)!.bounds(for: .mediaBox).size
        XCTAssertEqual(size, PDFPaginator.defaultPageSize)
    }

    func testEmptyDocumentGivesOnePage() throws {
        let out = url("empty.pdf")
        XCTAssertEqual(try PDFPaginator.write(NSAttributedString(string: ""), to: out), 1)
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 1)
    }

    func testTextIsDrawnBlackEvenInDarkMode() throws {
        let text = NSAttributedString(string: "XXXXXXXX", attributes: [.font: NSFont.boldSystemFont(ofSize: 60), .foregroundColor: NSColor.labelColor])
        let out = url("dark.pdf")
        var thrown: Error?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            do { try PDFPaginator.write(text, to: out) } catch { thrown = error }
        }
        if let thrown { throw thrown }
        let page = try XCTUnwrap(PDFDocument(url: out)?.page(at: 0))
        let image = try XCTUnwrap(ImageCodec.render(page: page, scale: 1))
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let px = UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)
        XCTAssertTrue(stride(from: 0, to: px.count, by: 4).contains { px[$0] < 60 }, "expected dark text on the white page")
    }
}

// MARK: - Merge PDF

final class MergePDFTests: DWTestCase {
    let converter = MergePDFConverter()

    private func merge(_ inputs: [URL]) async throws -> URL {
        let r = OutputReservation(directory: dir, baseName: converter.outputBaseName(for: inputs))
        return try await converter.convert(inputs: inputs, output: r, options: .init()) { _ in }
    }

    func testMergesPDFsAndImagesInFinderNameOrder() async throws {
        let b = try Fixtures.pdf(at: url("page 10.pdf"), pages: ["Bravo one", "Bravo two"])
        let a = try Fixtures.pdf(at: url("page 2.pdf"), pages: ["Alpha one"])
        let img = try Fixtures.png(at: url("zz photo.png"), width: 400, height: 300)
        let out = try await merge([b, img, a])
        XCTAssertEqual(out.lastPathComponent, "Merged.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 4)
        XCTAssertTrue(doc.page(at: 0)?.string?.contains("Alpha") == true, "\"page 2\" sorts before \"page 10\"")
        XCTAssertTrue(doc.page(at: 1)?.string?.contains("Bravo one") == true)
        XCTAssertTrue(doc.page(at: 2)?.string?.contains("Bravo two") == true)
        XCTAssertEqual(doc.page(at: 3)?.bounds(for: .mediaBox).size, CGSize(width: 400, height: 300))
        // Inputs untouched.
        XCTAssertEqual(PDFDocument(url: b)?.pageCount, 2)
    }

    func testLargeImagesAreScaledToPageSize() async throws {
        let big = try Fixtures.png(at: url("big.png"), width: 3000, height: 1500)
        let other = try Fixtures.png(at: url("small.png"), width: 100, height: 100)
        let out = try await merge([big, other])
        let size = try XCTUnwrap(PDFDocument(url: out)?.page(at: 0)?.bounds(for: .mediaBox).size)
        XCTAssertEqual(size.width, 842, accuracy: 1)
        XCTAssertEqual(size.height, 421, accuracy: 1)
    }

    func testSecondMergeGetsNumberedName() async throws {
        let a = try Fixtures.pdf(at: url("a.pdf"), pages: ["a"])
        let b = try Fixtures.pdf(at: url("b.pdf"), pages: ["b"])
        _ = try await merge([a, b])
        let second = try await merge([a, b])
        XCTAssertEqual(second.lastPathComponent, "Merged 2.pdf")
    }

    func testAcceptance() {
        XCTAssertTrue(converter.accepts(.pdf))
        XCTAssertTrue(converter.accepts(.jpeg))
        XCTAssertFalse(converter.accepts(.svg))
        XCTAssertFalse(converter.accepts(.plainText))
    }
}

// MARK: - Folder ↔ ZIP

final class ArchiveTests: DWTestCase {
    let converter = ArchiveConverter()

    private func makeFolder(_ name: String, in parent: URL? = nil) throws -> URL {
        let folder = (parent ?? dir).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "a".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: folder.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    func testFolderToZipAndBackWithoutDoubleNesting() async throws {
        let folder = try makeFolder("Photos")
        let zip = try await convert(converter, folder, to: .zip)
        XCTAssertEqual(zip.lastPathComponent, "Photos.zip")
        let entries = try await Fixtures.zipEntries(zip)
        XCTAssertTrue(entries.contains("Photos/a.txt"), "\(entries)")
        XCTAssertTrue(entries.contains("Photos/sub/b.txt"), "\(entries)")

        // Extract elsewhere: the single top-level folder lands directly in the destination.
        let out = url("out"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let moved = out.appendingPathComponent("Photos.zip")
        try FileManager.default.moveItem(at: zip, to: moved)
        let extracted = try await convert(converter, moved, to: .extract)
        XCTAssertEqual(extracted.lastPathComponent, "Photos")
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("sub/b.txt"), encoding: .utf8), "b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("Photos").path))

        // Extracting again never overwrites the first copy.
        let again = try await convert(converter, moved, to: .extract)
        XCTAssertEqual(again.lastPathComponent, "Photos 2")
        // No staging directories are left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasPrefix(".dragwheel") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testAppBundleZipKeepsFullName() async throws {
        let app = try makeFolder("Tool.app")
        let zip = try await convert(converter, app, to: .zip)
        XCTAssertEqual(zip.lastPathComponent, "Tool.app.zip")
    }

    func testArchiveWithSeveralTopLevelItemsIsWrappedInAFolder() async throws {
        try "1".write(to: url("one.txt"), atomically: true, encoding: .utf8)
        try "2".write(to: url("two.txt"), atomically: true, encoding: .utf8)
        let r = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/zip"), arguments: ["-q", "bundle.zip", "one.txt", "two.txt"], currentDirectory: dir)
        XCTAssertEqual(r.status, 0)
        let extracted = try await convert(converter, url("bundle.zip"), to: .extract)
        XCTAssertEqual(extracted.lastPathComponent, "bundle")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: extracted.path)), ["one.txt", "two.txt"])
    }

    func testTarGzWithSingleFile() async throws {
        let src = url("src"); try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let tgz = url("notes.tar.gz")
        let r = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-czf", tgz.path, "-C", src.path, "note.txt"])
        XCTAssertEqual(r.status, 0)
        try "existing".write(to: url("note.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(FormatRegistry.makeDefault().targets(for: [tgz]).map(\.format.id), ["extract"])
        let extracted = try await convert(converter, tgz, to: .extract)
        XCTAssertEqual(extracted.lastPathComponent, "note 2.txt")
        XCTAssertEqual(try String(contentsOf: extracted, encoding: .utf8), "hello")
        XCTAssertEqual(try String(contentsOf: url("note.txt"), encoding: .utf8), "existing")
    }

    func testArchiveBaseName() {
        XCTAssertEqual(ArchiveConverter.archiveBaseName(URL(fileURLWithPath: "/x/photos.tar.gz")), "photos")
        XCTAssertEqual(ArchiveConverter.archiveBaseName(URL(fileURLWithPath: "/x/photos.zip")), "photos")
        XCTAssertEqual(ArchiveConverter.archiveBaseName(URL(fileURLWithPath: "/x/v1.2.tgz")), "v1.2")
    }

    func testCorruptArchiveFailsCleanly() async throws {
        let bad = url("bad.zip")
        try Data("definitely not a zip".utf8).write(to: bad)
        do { _ = try await convert(converter, bad, to: .extract); XCTFail("expected failure") } catch {}
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(contents, ["bad.zip"], "no staging or placeholder may be left: \(contents)")
    }
}

final class ZipAllTests: DWTestCase {
    let converter = ZipAllConverter()

    private func zipAll(_ inputs: [URL]) async throws -> URL {
        let r = OutputReservation(directory: dir, baseName: converter.outputBaseName(for: inputs))
        return try await converter.convert(inputs: inputs, output: r, options: .init()) { _ in }
    }

    func testItemsFromOneFolder() async throws {
        let folder = url("Folder"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        let file = url("-dash.txt"); try "y".write(to: file, atomically: true, encoding: .utf8)
        let out = try await zipAll([folder, file])
        XCTAssertEqual(out.lastPathComponent, "Archive.zip")
        let entries = try await Fixtures.zipEntries(out)
        XCTAssertTrue(entries.contains("Folder/inner.txt"), "\(entries)")
        XCTAssertTrue(entries.contains("-dash.txt"), "names starting with '-' must not be read as options: \(entries)")
        XCTAssertFalse(entries.contains { $0.hasSuffix(".DS_Store") })
    }

    func testItemsFromDifferentFoldersWithSameName() async throws {
        let d1 = url("one"), d2 = url("two")
        for d in [d1, d2] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "1".write(to: d1.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try "2".write(to: d2.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        let out = try await zipAll([d1.appendingPathComponent("x.txt"), d2.appendingPathComponent("x.txt")])
        let entries = try await Fixtures.zipEntries(out)
        XCTAssertEqual(Set(entries), ["x.txt", "x 2.txt"])
    }
}

// MARK: - LibreOffice

final class LibreOfficeTests: DWTestCase {
    private func fakeTools(_ body: String) throws -> ToolLocator {
        try Fixtures.script(at: url("bin/soffice"), body)
        return ToolLocator(searchDirectories: [url("bin").path], includePATH: false)
    }

    private let writesOutput = """
    while [ $# -gt 0 ]; do
      case "$1" in
        --convert-to) ext="$2"; shift ;;
        --outdir) out="$2"; shift ;;
        -*) ;;
        *) in="$1" ;;
      esac
      shift
    done
    base=$(basename "$in"); base="${base%.*}"
    echo "converted to $ext" > "$out/$base.$ext"
    """

    func testAvailability() throws {
        let none = LibreOfficeConverter(tools: ToolLocator(searchDirectories: [], includePATH: false))
        XCTAssertEqual(none.availability(of: .pdf), .unavailable(reason: LibreOfficeConverter.installHint))
        let fake = LibreOfficeConverter(tools: try fakeTools("exit 0"))
        XCTAssertEqual(fake.availability(of: .pdf), .available)
    }

    func testOutputsPerDocumentKind() {
        let lo = LibreOfficeConverter()
        func outs(_ ext: String) -> [String] { lo.outputFormats(for: UTType(filenameExtension: ext)!).map(\.id) }
        XCTAssertEqual(outs("docx"), ["pdf", "odt"])
        XCTAssertEqual(outs("rtf"), ["pdf", "docx", "odt"])
        XCTAssertEqual(outs("pptx"), ["pdf", "odp"])
        XCTAssertEqual(outs("key"), ["pdf", "pptx", "odp"])
        XCTAssertEqual(outs("xlsx"), ["pdf", "ods", "csv"])
        XCTAssertEqual(outs("numbers"), ["pdf", "xlsx", "ods", "csv"])
        XCTAssertEqual(outs("csv"), ["xlsx", "ods"])
        XCTAssertEqual(outs("txt"), [])
    }

    func testCommandLine() {
        let args = LibreOfficeConverter.arguments(
            input: URL(fileURLWithPath: "/in/deck.pptx"), format: .pdf,
            outDir: URL(fileURLWithPath: "/tmp/out"), profile: URL(fileURLWithPath: "/tmp/profile", isDirectory: true)
        )
        XCTAssertEqual(args.first, "-env:UserInstallation=file:///tmp/profile/")
        XCTAssertTrue(args.contains("--headless"))
        XCTAssertEqual(Array(args.suffix(5)), ["--convert-to", "pdf", "--outdir", "/tmp/out", "/in/deck.pptx"])
    }

    func testPlumbingWithFakeSoffice() async throws {
        let converter = LibreOfficeConverter(tools: try fakeTools(writesOutput))
        let deck = url("deck.pptx"); try Data("fake pptx".utf8).write(to: deck)
        let out = try await convert(converter, deck, to: .pdf)
        XCTAssertEqual(out.lastPathComponent, "deck.pdf")
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "converted to pdf\n")
        // Second run → numbered name; existing output untouched.
        let second = try await convert(converter, deck, to: .pdf)
        XCTAssertEqual(second.lastPathComponent, "deck 2.pdf")
    }

    func testSofficeThatProducesNothingFailsCleanly() async throws {
        let converter = LibreOfficeConverter(tools: try fakeTools("echo 'Error: source file could not be loaded' >&2; exit 0"))
        let sheet = url("sheet.xlsx"); try Data("x".utf8).write(to: sheet)
        do {
            _ = try await convert(converter, sheet, to: .pdf)
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be loaded"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("sheet.pdf").path))
    }

    func testRealLibreOfficeIfInstalled() async throws {
        try XCTSkipIf(ToolLocator.shared.locateSoffice() == nil, "LibreOffice not installed")
        let txt = url("memo.txt"); try "Hello from LibreOffice".write(to: txt, atomically: true, encoding: .utf8)
        let docx = try await convert(DocumentConverter(), txt, to: .docx)
        let pdf = try await convert(LibreOfficeConverter(), docx, to: .pdf)
        XCTAssertTrue(PDFDocument(url: pdf)?.string?.contains("Hello from LibreOffice") == true)
    }
}
