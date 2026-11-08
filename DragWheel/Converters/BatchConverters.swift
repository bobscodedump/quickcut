import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Sorts like Finder ("scan 2" before "scan 10").
func finderOrder(_ urls: [URL]) -> [URL] {
    urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

/// PDFs and images → one PDF ("Merged.pdf"), in file-name order.
struct MergePDFConverter: BatchConverter {
    let id = "merge-pdf"
    let format = OutputFormat.mergePDF
    /// Images are scaled so their longest side is at most this many points (A4 height); pixels are kept.
    var maxImagePoints: CGFloat = 842

    func accepts(_ type: UTType) -> Bool {
        type.conforms(to: .pdf) || (type.conforms(to: .image) && !type.conforms(to: .svg))
    }

    func outputBaseName(for inputs: [URL]) -> String { "Merged" }

    func convert(
        inputs: [URL], output: OutputReservation, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let merged = PDFDocument()
        let ordered = finderOrder(inputs)
        for (index, url) in ordered.enumerated() {
            try Task.checkCancellation()
            if FileTypeResolver.contentType(of: url)?.conforms(to: .pdf) == true {
                guard let doc = PDFDocument(url: url) else { throw ConversionError.unsupported("\(url.lastPathComponent) couldn't be opened.") }
                if doc.isLocked { throw ConversionError.unsupported("\(url.lastPathComponent) is password protected.") }
                for pageIndex in 0..<doc.pageCount {
                    if let page = doc.page(at: pageIndex)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                }
            } else {
                let image = try ImageCodec.load(url: url)
                let longest = CGFloat(max(image.width, image.height))
                let scale = min(1, maxImagePoints / longest)
                let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                guard let page = PDFPage(image: NSImage(cgImage: image, size: size)) else {
                    throw ConversionError.unsupported("\(url.lastPathComponent) couldn't be added to the PDF.")
                }
                merged.insert(page, at: merged.pageCount)
            }
            progress(Double(index + 1) / Double(ordered.count) * 0.9)
        }
        guard merged.pageCount > 0 else { throw ConversionError.outputFailed("Nothing to merge.") }
        let out = try output.reserveFile(ext: "pdf")
        guard merged.write(to: out) else { throw ConversionError.outputFailed("Couldn't write the merged PDF.") }
        progress(1)
        return out
    }
}

/// Any selection of files and folders → one "Archive.zip" (like Finder's Compress).
struct ZipAllConverter: BatchConverter {
    let id = "zip-all"
    let format = OutputFormat.zipAll
    static let zipTool = URL(fileURLWithPath: "/usr/bin/zip")

    func accepts(_ type: UTType) -> Bool { true }
    func outputBaseName(for inputs: [URL]) -> String { "Archive" }

    func convert(
        inputs: [URL], output: OutputReservation, options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("dragwheel-zip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let tempZip = work.appendingPathComponent("archive.zip")

        let parents = Set(inputs.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        var args = ["-r", "-q"]
        let cwd: URL
        var names: [String] = []
        if parents.count == 1, let parent = parents.first {
            // Common case: everything is in one folder → archive the items by name, keep symlinks as links.
            args.append("-y")
            cwd = URL(fileURLWithPath: parent, isDirectory: true)
            names = inputs.map { $0.lastPathComponent }
        } else {
            // Items from different folders: stage symlinks with unique names; zip follows them.
            cwd = work.appendingPathComponent("stage", isDirectory: true)
            try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
            var used = Set<String>()
            for url in inputs {
                var name = url.lastPathComponent, n = 2
                while used.contains(name.lowercased()) {
                    let ext = url.pathExtension
                    let stem = url.deletingPathExtension().lastPathComponent
                    name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                    n += 1
                }
                used.insert(name.lowercased())
                try fm.createSymbolicLink(at: cwd.appendingPathComponent(name), withDestinationURL: url)
                names.append(name)
            }
        }
        args += [tempZip.path] + names.map { "./" + $0 } + ["-x", "*.DS_Store", "*__MACOSX*"]
        progress(0.1)
        let result = try await ProcessRunner.run(executable: Self.zipTool, arguments: args, currentDirectory: cwd)
        guard result.status == 0, fm.fileExists(atPath: tempZip.path) else {
            throw ConversionError.toolFailed(tool: "zip", message: result.stderr + result.stdout)
        }
        let out = try output.reserveFile(ext: "zip")
        try output.commit(temp: tempZip, to: out)
        progress(1)
        return out
    }
}
