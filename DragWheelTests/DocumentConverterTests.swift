import XCTest
import UniformTypeIdentifiers
@testable import DragWheel

final class DocumentConverterTests: DWTestCase {
    let converter = DocumentConverter()
    let marker = "DragWheel marker héllo ✓"

    func testTXTToEveryDocumentFormat() async throws {
        let src = url("note.txt")
        try marker.write(to: src, atomically: true, encoding: .utf8)
        for format in [OutputFormat.rtf, .html, .docx, .odt] {
            let out = try await convert(converter, src, to: format)
            XCTAssertEqual(out.lastPathComponent, "note.\(format.fileExtension)")
            XCTAssertGreaterThan(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize!, 0, format.id)
        }
        // Content survives a DOCX → TXT round trip (including non-ASCII).
        let docx = url("note.docx")
        let back = try await convert(converter, docx, to: .txt)
        XCTAssertTrue(try String(contentsOf: back, encoding: .utf8).contains(marker))
    }

    func testRTFAndHTMLAndODTToTXT() async throws {
        let src = url("src.txt")
        try marker.write(to: src, atomically: true, encoding: .utf8)
        for format in [OutputFormat.rtf, .html, .odt] {
            let doc = try await convert(converter, src, to: format)
            let renamed = dir.appendingPathComponent("from-\(format.id).\(format.fileExtension)")
            try FileManager.default.moveItem(at: doc, to: renamed)
            let txt = try await convert(converter, renamed, to: .txt)
            XCTAssertTrue(try String(contentsOf: txt, encoding: .utf8).contains(marker), format.id)
        }
    }

    func testExistingOutputIsNeverOverwritten() async throws {
        let src = url("dup.txt")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        let existing = url("dup.rtf")
        try "PRECIOUS".write(to: existing, atomically: true, encoding: .utf8)
        let out = try await convert(converter, src, to: .rtf)
        XCTAssertEqual(out.lastPathComponent, "dup 2.rtf")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "PRECIOUS")
    }

    func testPlainTextFileWithoutExtensionStillConverts() async throws {
        let src = url("README")
        try marker.write(to: src, atomically: true, encoding: .utf8)
        // Launch Services recognises extensionless text by content, so it's offered and converts.
        let registry = FormatRegistry.makeDefault()
        XCTAssertEqual(FileTypeResolver.contentType(of: src), .plainText)
        XCTAssertTrue(registry.targets(for: [src]).contains { $0.format.id == "rtf" })
        let out = try await convert(converter, src, to: .rtf)
        XCTAssertEqual(out.lastPathComponent, "README.rtf")
        let back = try await convert(converter, out, to: .txt)
        XCTAssertTrue(try String(contentsOf: back, encoding: .utf8).contains(marker))
    }

    func testAcceptanceRules() {
        XCTAssertTrue(converter.accepts(.plainText))
        XCTAssertFalse(converter.accepts(UTType("public.swift-source")!))
        XCTAssertFalse(converter.accepts(UTType("net.daringfireball.markdown")!))
        XCTAssertFalse(converter.accepts(.png))
    }
}

final class MarkdownConverterTests: DWTestCase {
    let converter = MarkdownConverter()

    func testMarkdownToHTML() async throws {
        let src = url("readme.md")
        try """
        # Title

        Some **bold**, *italic* and `code <b>` text with a [link](https://example.com).

        - one
        - two

        1. first
        2. second

        > quoted

        ```
        let x = 1 < 2
        ```

        ---
        """.write(to: src, atomically: true, encoding: .utf8)
        let out = try await convert(converter, src, to: .html)
        XCTAssertEqual(out.lastPathComponent, "readme.html")
        let html = try String(contentsOf: out, encoding: .utf8)
        for expected in ["<h1>Title</h1>", "<strong>bold</strong>", "<em>italic</em>", "<code>code &lt;b&gt;</code>",
                         "<a href=\"https://example.com\">link</a>", "<ul><li>one</li><li>two</li></ul>",
                         "<ol><li>first</li><li>second</li></ol>", "<blockquote>", "let x = 1 &lt; 2", "<hr>", "<title>readme</title>"] {
            XCTAssertTrue(html.contains(expected), "missing \(expected)\n\(html)")
        }
    }

    func testMarkdownFileTypeIsRecognised() throws {
        let src = url("a.md")
        try "# hi".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertEqual(FormatRegistry.makeDefault().targets(for: [src]).map(\.format.id), ["pdf", "html"])
    }
}
