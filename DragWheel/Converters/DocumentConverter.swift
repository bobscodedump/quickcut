import Foundation
import UniformTypeIdentifiers

/// TXT / RTF / HTML / DOCX / ODT / DOC conversions via /usr/bin/textutil.
struct DocumentConverter: Converter {
    let id = "textutil"
    static let textutil = URL(fileURLWithPath: "/usr/bin/textutil")

    var inputTypes: [UTType] {
        [.rtf, .html, UTType("org.openxmlformats.wordprocessingml.document"),
         UTType("org.oasis-open.opendocument.text"), UTType("com.microsoft.word.doc")].compactMap { $0 }
    }

    func accepts(_ type: UTType) -> Bool {
        // Plain text must match exactly: source code, JSON, CSV and Markdown all *conform* to plain text.
        if type == .plainText || type == .utf8PlainText { return true }
        return inputTypes.contains { type.conforms(to: $0) }
    }

    func outputFormats(for input: UTType) -> [OutputFormat] {
        let formats: [OutputFormat] = [.txt, .rtf, .html, .docx, .odt]
        if input == .plainText || input == .utf8PlainText { return formats.filter { $0.id != "txt" } }
        return excludingSelf(formats, input: input)
    }

    func availability(of format: OutputFormat) -> Availability {
        FileManager.default.isExecutableFile(atPath: Self.textutil.path)
            ? .available : .unavailable(reason: "/usr/bin/textutil is missing.")
    }

    func convert(
        input: URL, to format: OutputFormat, output: OutputReservation,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let out = try output.reserveFile(ext: format.fileExtension)
        progress(0.1)
        var args = ["-convert", format.fileExtension, "-output", out.path]
        let type = FileTypeResolver.contentType(of: input)
        if format.id == "txt" || type == .plainText || type == .utf8PlainText { args += ["-encoding", "UTF-8"] }
        args.append(input.path)
        let result = try await ProcessRunner.run(executable: Self.textutil, arguments: args)
        guard result.status == 0 else {
            throw ConversionError.toolFailed(tool: "textutil", message: result.stderr + result.stdout)
        }
        guard (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
            throw ConversionError.outputFailed("textutil produced an empty file.")
        }
        progress(1)
        return out
    }
}
