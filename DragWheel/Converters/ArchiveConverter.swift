import Foundation
import UniformTypeIdentifiers

/// Folder / package → ZIP (via ditto, same as Finder's Compress) and archive → extracted contents.
struct ArchiveConverter: Converter {
    let id = "archive"
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")

    /// Matched exactly: many document formats (DOCX, EPUB, Pages…) *conform* to zip but aren't archives.
    static let archiveIdentifiers: Set<String> = [
        "public.zip-archive", "public.tar-archive", "org.gnu.gnu-zip-tar-archive", "org.gnu.gnu-zip-archive",
        "public.bzip2-archive", "public.tar-bzip2-archive", "org.tukaani.xz-archive", "org.7-zip.7-zip-archive",
    ]

    var inputTypes: [UTType] { [.directory] + Self.archiveIdentifiers.compactMap { UTType($0) } }

    func accepts(_ type: UTType) -> Bool {
        type.conforms(to: .directory) || Self.archiveIdentifiers.contains(type.identifier)
    }

    func outputFormats(for input: UTType) -> [OutputFormat] {
        if Self.archiveIdentifiers.contains(input.identifier) { return [.extract] }
        if input.conforms(to: .directory) { return [.zip] }
        return []
    }

    func convert(
        input: URL, to format: OutputFormat, output: OutputReservation,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        switch format.id {
        case "zip": return try await compress(input, output: output, progress: progress)
        case "extract": return try await extract(input, output: output, progress: progress)
        default: throw ConversionError.unsupported("Unsupported archive operation.")
        }
    }

    // MARK: Compress

    private func compress(_ input: URL, output: OutputReservation, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("dragwheel-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: temp) }
        progress(0.1)
        let result = try await ProcessRunner.run(
            executable: Self.ditto, arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, temp.path]
        )
        guard result.status == 0 else { throw ConversionError.toolFailed(tool: "ditto", message: result.stderr) }
        // "Photos" → "Photos.zip", "Tool.app" → "Tool.app.zip" (like Finder).
        let out = try output.reserveFile(ext: "zip", baseName: input.lastPathComponent)
        try output.commit(temp: temp, to: out)
        progress(1)
        return out
    }

    // MARK: Extract

    /// "photos.tar.gz" → "photos"
    static func archiveBaseName(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        return name.isEmpty ? "Archive" : name
    }

    private func extract(_ input: URL, output: OutputReservation, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        // Stage next to the destination so the final move is a cheap rename on the same volume.
        let staging = output.directory.appendingPathComponent(".dragwheel-extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        progress(0.1)
        let isZip = FileTypeResolver.contentType(of: input)?.identifier == "public.zip-archive"
        let (tool, args) = isZip
            ? (Self.ditto, ["-x", "-k", input.path, staging.path])
            : (Self.tar, ["-xf", input.path, "-C", staging.path])
        let result = try await ProcessRunner.run(executable: tool, arguments: args)
        guard result.status == 0 else {
            throw ConversionError.toolFailed(tool: tool.lastPathComponent, message: result.stderr)
        }
        progress(0.8)

        let items = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
        guard !items.isEmpty else { throw ConversionError.outputFailed("The archive is empty.") }

        let destination: URL
        if items.count == 1, let item = items.first {
            // A single top-level item is placed directly (no "foo/foo/…" double nesting).
            if FileTypeResolver.isDirectory(item) {
                destination = try output.reserveDirectory(baseName: item.lastPathComponent)
            } else {
                destination = try output.reserveFile(ext: item.pathExtension, baseName: item.deletingPathExtension().lastPathComponent)
            }
            _ = try fm.replaceItemAt(destination, withItemAt: item)
        } else {
            destination = try output.reserveDirectory(baseName: Self.archiveBaseName(input))
            for item in items {
                try fm.moveItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
            }
        }
        progress(1)
        return destination
    }
}
