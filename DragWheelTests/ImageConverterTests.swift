import XCTest
import UniformTypeIdentifiers
@testable import DragWheel

final class ImageConverterTests: DWTestCase {
    let converter = ImageConverter()

    func testPNGToEveryNativeFormat() async throws {
        let src = try Fixtures.png(at: url("photo.png"), width: 64, height: 48, alpha: true)
        let expected: [(OutputFormat, String)] = [(.jpeg, "public.jpeg"), (.tiff, "public.tiff"), (.gif, "com.compuserve.gif"), (.bmp, "com.microsoft.bmp")]
        for (format, uti) in expected {
            let out = try await convert(converter, src, to: format)
            XCTAssertEqual(out.lastPathComponent, "photo.\(format.fileExtension)")
            let info = try XCTUnwrap(imageInfo(out), "\(format.id) isn't a readable image")
            XCTAssertEqual(info.type, uti)
            XCTAssertEqual(info.width, 64); XCTAssertEqual(info.height, 48)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "original must remain")
    }

    func testHEICWhenSupported() async throws {
        try XCTSkipUnless(ImageCodec.canEncodeNatively("heic"), "no HEIC encoder")
        let src = try Fixtures.png(at: url("h.png"))
        let out = try await convert(converter, src, to: .heic)
        XCTAssertEqual(imageInfo(out)?.type, "public.heic")
    }

    func testJPEGToPNGAndQualityAffectsSize() async throws {
        let png = try Fixtures.png(at: url("q.png"), width: 256, height: 256)
        let high = try await convert(converter, png, to: .jpeg, options: ConversionOptions(imageQuality: 1.0))
        let low = try await convert(converter, png, to: .jpeg, options: ConversionOptions(imageQuality: 0.1))
        let highSize = try high.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let lowSize = try low.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        XCTAssertLessThan(lowSize, highSize)
        XCTAssertEqual(low.lastPathComponent, "q 2.jpg", "second output must get a numbered name, not overwrite")

        let back = try await convert(converter, high, to: .png)
        XCTAssertEqual(imageInfo(back)?.type, "public.png")
    }

    func testTransparentPNGToJPEGFlattensOntoWhite() async throws {
        let src = try Fixtures.png(at: url("alpha.png"), width: 20, height: 20, alpha: true)
        let out = try await convert(converter, src, to: .jpeg)
        let image = try ImageCodec.load(url: out)
        // Left half was 30% opaque blue-ish → must be much lighter than fully opaque, never black.
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -2, y: 0, width: 20, height: 20))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(Int(px[0]) + Int(px[1]) + Int(px[2]), 450, "transparent area should be flattened onto white")
    }

    func testImageToPDF() async throws {
        let src = try Fixtures.png(at: url("scan.png"), width: 120, height: 80)
        let out = try await convert(converter, src, to: .pdf)
        let doc = try XCTUnwrap(CGPDFDocument(out as CFURL))
        XCTAssertEqual(doc.numberOfPages, 1)
        let box = doc.page(at: 1)!.getBoxRect(.mediaBox)
        XCTAssertEqual(Int(box.width), 120); XCTAssertEqual(Int(box.height), 80)
    }

    func testWebPUsesExternalEncoderWhenAvailable() async throws {
        try XCTSkipUnless(ToolLocator.shared.isAvailable("cwebp") || ToolLocator.shared.isAvailable("ffmpeg") || ImageCodec.canEncodeNatively("webp"), "no WebP encoder")
        let src = try Fixtures.png(at: url("w.png"))
        let out = try await convert(converter, src, to: .webp)
        let head = try Data(contentsOf: out).prefix(12)
        XCTAssertEqual(String(decoding: head.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: head.suffix(4), as: UTF8.self), "WEBP")
        // And WebP can be decoded back.
        let back = try await convert(converter, out, to: .png)
        XCTAssertEqual(imageInfo(back)?.width, 64)
    }

    func testWebPFailsCleanlyWithoutAnyEncoder() async throws {
        try XCTSkipIf(ImageCodec.canEncodeNatively("webp"))
        let none = ImageConverter(tools: ToolLocator(searchDirectories: [], includePATH: false))
        XCTAssertEqual(none.availability(of: .webp).isAvailable, false)
        let src = try Fixtures.png(at: url("nw.png"))
        do {
            _ = try await convert(none, src, to: .webp)
            XCTFail("expected failure")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url("nw.webp").path), "failed conversion must not leave a placeholder behind")
        }
    }

    func testCorruptImageFailsAndLeavesNothingBehind() async throws {
        let bad = url("bad.png")
        try Data("not an image".utf8).write(to: bad)
        do {
            _ = try await convert(converter, bad, to: .jpeg)
            XCTFail("expected failure")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url("bad.jpg").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
        }
    }

    func testOutputFormatsExcludeOwnType() {
        XCTAssertFalse(converter.outputFormats(for: .png).contains(.png))
        XCTAssertFalse(converter.outputFormats(for: .jpeg).contains(.jpeg))
        XCTAssertTrue(converter.outputFormats(for: .heic).contains(.jpeg))
        XCTAssertFalse(converter.accepts(.svg))
    }
}
