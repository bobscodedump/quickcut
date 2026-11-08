import AppKit
import UniformTypeIdentifiers

/// TXT / RTF / DOCX / ODT / DOC / HTML / Markdown → PDF without external tools:
/// the document is loaded as an attributed string and laid out into pages with TextKit.
/// The resulting PDF keeps real, searchable text.
struct DocumentPDFConverter: Converter {
    let id = "document-pdf"
    static let markdown = UTType("net.daringfireball.markdown")

    private let textTypes = DocumentConverter()

    var inputTypes: [UTType] { textTypes.inputTypes + [Self.markdown].compactMap { $0 } }

    func accepts(_ type: UTType) -> Bool {
        if let md = Self.markdown, type.conforms(to: md) { return true }
        return textTypes.accepts(type)
    }

    func outputFormats(for input: UTType) -> [OutputFormat] { [.pdf] }

    func convert(
        input: URL, to format: OutputFormat, output: OutputReservation,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        progress(0.05)
        let text = try await Self.load(input, type: FileTypeResolver.contentType(of: input))
        try Task.checkCancellation()
        progress(0.5)
        let out = try output.reserveFile(ext: "pdf")
        _ = try PDFPaginator.write(text.value, to: out)
        progress(1)
        return out
    }

    /// Wrapper so the attributed string can cross from the main actor.
    struct Loaded: @unchecked Sendable { let value: NSAttributedString }

    static func load(_ url: URL, type: UTType?) async throws -> Loaded {
        if let type, let md = markdown, type.conforms(to: md) {
            guard let data = try? Data(contentsOf: url), let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw ConversionError.unreadableInput
            }
            let html = MarkdownConverter.document(markdown: source, title: url.deletingPathExtension().lastPathComponent)
            return try await importHTML(Data(html.utf8))
        }
        if let type, type.conforms(to: .html) {
            guard let data = try? Data(contentsOf: url) else { throw ConversionError.unreadableInput }
            return try await importHTML(data)
        }
        if type == .plainText || type == .utf8PlainText {
            guard let data = try? Data(contentsOf: url), let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw ConversionError.unreadableInput
            }
            return Loaded(value: NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black,
            ]))
        }
        var documentType: NSAttributedString.DocumentType?
        if let type {
            if let t = UTType("org.openxmlformats.wordprocessingml.document"), type.conforms(to: t) { documentType = .officeOpenXML }
            else if let t = UTType("org.oasis-open.opendocument.text"), type.conforms(to: t) { documentType = .openDocument }
            else if let t = UTType("com.microsoft.word.doc"), type.conforms(to: t) { documentType = .docFormat }
            else if type.conforms(to: .rtf) { documentType = .rtf }
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = documentType.map { [.documentType: $0] } ?? [:]
        do {
            return Loaded(value: try NSAttributedString(url: url, options: options, documentAttributes: nil))
        } catch {
            throw ConversionError.unreadableInput
        }
    }

    /// AppKit's HTML importer must run on the main thread.
    private static func importHTML(_ data: Data) async throws -> Loaded {
        try await MainActor.run {
            do {
                let value = try NSAttributedString(data: data, options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ], documentAttributes: nil)
                return Loaded(value: value)
            } catch {
                throw ConversionError.unreadableInput
            }
        }
    }
}

/// Lays out an attributed string on pages and draws them into a PDF.
enum PDFPaginator {
    /// US Letter in the US and Canada, A4 elsewhere.
    static var defaultPageSize: CGSize {
        let region = Locale.current.region?.identifier ?? ""
        return ["US", "CA"].contains(region) ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
    }

    /// Returns the number of pages written.
    @discardableResult
    static func write(_ text: NSAttributedString, to url: URL, pageSize: CGSize = defaultPageSize, margin: CGFloat = 54) throws -> Int {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let textSize = CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)

        var containers: [NSTextContainer] = []
        while containers.count < 10_000 {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            if range.length == 0, !containers.isEmpty {
                layout.removeTextContainer(at: containers.count) // nothing fits any more (e.g. an oversized item)
                break
            }
            containers.append(container)
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
        }

        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.outputFailed("Couldn't create \(url.lastPathComponent).")
        }
        // Draw with the light appearance so "label colour" text is black on the white page.
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            for container in containers {
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                ctx.translateBy(x: 0, y: pageSize.height)
                ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                let range = layout.glyphRange(for: container)
                let origin = CGPoint(x: margin, y: margin)
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
                NSGraphicsContext.restoreGraphicsState()
                ctx.restoreGState()
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return containers.count
    }
}
