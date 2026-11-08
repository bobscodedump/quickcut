import XCTest
import PDFKit
@testable import DragWheel

final class PDFConverterTests: DWTestCase {
    let converter = PDFConverter()

    func testSinglePagePDFToPNGWritesAFile() async throws {
        let pdf = try Fixtures.pdf(at: url("doc.pdf"), pages: ["Only page"])
        let out = try await convert(converter, pdf, to: .png)
        XCTAssertEqual(out.lastPathComponent, "doc.png")
        let info = try XCTUnwrap(imageInfo(out))
        XCTAssertEqual(info.type, "public.png")
        XCTAssertEqual(info.width, 600) // 300pt × 2
        XCTAssertEqual(info.height, 400)
    }

    func testMultiPagePDFToJPEGWritesAFolderWithOneImagePerPage() async throws {
        let pdf = try Fixtures.pdf(at: url("book.pdf"), pages: ["One", "Two", "Three"])
        let out = try await convert(converter, pdf, to: .jpeg)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(out.lastPathComponent, "book")
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(files, ["book-1.jpg", "book-2.jpg", "book-3.jpg"])
        for f in files { XCTAssertEqual(imageInfo(out.appendingPathComponent(f))?.type, "public.jpeg") }

        // A second conversion must not merge into / overwrite the first folder.
        let again = try await convert(converter, pdf, to: .jpeg)
        XCTAssertEqual(again.lastPathComponent, "book 2")
    }

    func testRenderedPageIsNotBlank() async throws {
        let pdf = try Fixtures.pdf(at: url("t.pdf"), pages: ["HELLO HELLO HELLO"])
        let out = try await convert(converter, pdf, to: .png)
        let image = try ImageCodec.load(url: out)
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)
        XCTAssertTrue(stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] < 128 }, "expected dark text pixels")
        XCTAssertEqual(bytes[0], 255, "background should be white")
    }

    func testPDFToText() async throws {
        let pdf = try Fixtures.pdf(at: url("words.pdf"), pages: ["Hello DragWheel", "Second page"])
        let out = try await convert(converter, pdf, to: .txt)
        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(text.contains("Hello DragWheel"))
        XCTAssertTrue(text.contains("Second page"))
    }

    func testPDFWithoutTextFailsWithNoTextError() async throws {
        let png = try Fixtures.png(at: url("img.png"))
        let pdf = try await convert(ImageConverter(), png, to: .pdf)
        do {
            _ = try await convert(converter, pdf, to: .txt)
            XCTFail("expected failure")
        } catch let error as ConversionError {
            guard case .noText = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("img.txt").path))
    }

    func testGarbagePDFFails() async throws {
        let bad = url("bad.pdf")
        try Data("%PDF-nope".utf8).write(to: bad)
        do { _ = try await convert(converter, bad, to: .png); XCTFail("expected failure") } catch {}
    }
}
