import Foundation
import PDFKit
import UniformTypeIdentifiers

/// PDF → PNG / JPEG (one image per page; multi-page PDFs go into a folder) and PDF → TXT.
struct PDFConverter: Converter {
    let id = "pdf"
    var inputTypes: [UTType] { [.pdf] }
    /// Render scale: 2.0 = 144 dpi.
    var renderScale: CGFloat = 2.0

    func outputFormats(for input: UTType) -> [OutputFormat] { [.png, .jpeg, .txt] }

    func convert(
        input: URL, to format: OutputFormat, output: OutputReservation,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let document = PDFDocument(url: input) else { throw ConversionError.unreadableInput }
        if document.isLocked { throw ConversionError.locked }
        guard document.pageCount > 0 else { throw ConversionError.unreadableInput }

        if format.id == "txt" {
            let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ConversionError.noText }
            let out = try output.reserveFile(ext: "txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            progress(1)
            return out
        }

        let count = document.pageCount
        if count == 1 {
            let out = try output.reserveFile(ext: format.fileExtension)
            try writePage(document.page(at: 0), format: format, quality: options.imageQuality, to: out)
            progress(1)
            return out
        }

        let folder = try output.reserveDirectory()
        let digits = String(count).count
        for index in 0..<count {
            try Task.checkCancellation()
            let number = String(format: "%0\(digits)d", index + 1)
            let name = "\(output.baseName)-\(number).\(format.fileExtension)"
            try writePage(document.page(at: index), format: format, quality: options.imageQuality, to: folder.appendingPathComponent(name))
            progress(Double(index + 1) / Double(count))
        }
        return folder
    }

    private func writePage(_ page: PDFPage?, format: OutputFormat, quality: Double, to url: URL) throws {
        guard let page, let image = ImageCodec.render(page: page, scale: renderScale) else {
            throw ConversionError.outputFailed("Couldn't render a PDF page.")
        }
        try ImageCodec.write(image, formatID: format.id, quality: quality, to: url)
    }
}
