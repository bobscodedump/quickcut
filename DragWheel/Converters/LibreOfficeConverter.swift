import Foundation
import UniformTypeIdentifiers

/// Office / OpenDocument / iWork conversions through LibreOffice running headless (optional install).
struct LibreOfficeConverter: Converter {
    let id = "libreoffice"
    let tools: ToolLocator
    static let installHint = "Install LibreOffice: brew install --cask libreoffice"

    init(tools: ToolLocator = .shared) { self.tools = tools }

    enum Kind: Equatable { case text, presentation, spreadsheet, csv }

    private static func types(_ exts: [String]) -> [UTType] { exts.compactMap { UTType(filenameExtension: $0) } }
    private static let textTypes = types(["docx", "doc", "odt", "rtf", "pages"])
    private static let presentationTypes = types(["pptx", "ppt", "odp", "key"])
    private static let spreadsheetTypes = types(["xlsx", "xls", "ods", "numbers"])

    static func kind(of type: UTType) -> Kind? {
        if type.conforms(to: .commaSeparatedText) { return .csv }
        if textTypes.contains(where: { type.conforms(to: $0) }) { return .text }
        if presentationTypes.contains(where: { type.conforms(to: $0) }) { return .presentation }
        if spreadsheetTypes.contains(where: { type.conforms(to: $0) }) { return .spreadsheet }
        return nil
    }

    var inputTypes: [UTType] { Self.textTypes + Self.presentationTypes + Self.spreadsheetTypes + [.commaSeparatedText] }

    func accepts(_ type: UTType) -> Bool { Self.kind(of: type) != nil }

    func outputFormats(for input: UTType) -> [OutputFormat] {
        switch Self.kind(of: input) {
        case .text: return excludingSelf([.pdf, .docx, .odt], input: input)
        case .presentation: return excludingSelf([.pdf, .pptx, .odp], input: input)
        case .spreadsheet: return excludingSelf([.pdf, .xlsx, .ods, .csv], input: input)
        case .csv: return [.xlsx, .ods]
        case nil: return []
        }
    }

    func availability(of format: OutputFormat) -> Availability {
        tools.locateSoffice() != nil ? .available : .unavailable(reason: Self.installHint)
    }

    /// The soffice command line for one conversion (separate profile per job so jobs can run in parallel).
    static func arguments(input: URL, format: OutputFormat, outDir: URL, profile: URL) -> [String] {
        ["-env:UserInstallation=\(profile.absoluteString)",
         "--headless", "--norestore", "--nologo", "--nodefault", "--nolockcheck",
         "--convert-to", format.fileExtension, "--outdir", outDir.path, input.path]
    }

    func convert(
        input: URL, to format: OutputFormat, output: OutputReservation,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let soffice = tools.locateSoffice() else {
            throw ConversionError.toolMissing(tool: "LibreOffice", hint: "Run: brew install --cask libreoffice")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("dragwheel-lo-\(UUID().uuidString)", isDirectory: true)
        let outDir = work.appendingPathComponent("out", isDirectory: true)
        let profile = work.appendingPathComponent("profile", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        progress(0.1)
        let result = try await ProcessRunner.run(
            executable: soffice, arguments: Self.arguments(input: input, format: format, outDir: outDir, profile: profile)
        )
        // soffice can exit 0 without producing anything, so check for the file.
        guard let produced = try fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil).first else {
            throw ConversionError.toolFailed(tool: "LibreOffice", message: result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        let out = try output.reserveFile(ext: format.fileExtension)
        try output.commit(temp: produced, to: out)
        progress(1)
        return out
    }
}
