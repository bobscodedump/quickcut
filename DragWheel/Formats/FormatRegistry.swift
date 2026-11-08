import Foundation
import UniformTypeIdentifiers

/// A format that can be offered for a set of files, plus whether it can run right now.
struct FormatTarget: Identifiable, Equatable, Sendable {
    let format: OutputFormat
    let availability: Availability
    var id: String { format.id }
}

/// Maps UTTypes to the conversions that can be done on them, and picks the converter for each file.
final class FormatRegistry: Sendable {
    let converters: [any Converter]
    let batchConverters: [any BatchConverter]

    init(converters: [any Converter], batchConverters: [any BatchConverter] = []) {
        self.converters = converters
        self.batchConverters = batchConverters
    }

    /// Default converter set. Order matters: the first *available* converter for a format wins,
    /// so dependency-free converters (AVFoundation) are listed before ffmpeg.
    static func makeDefault(tools: ToolLocator = .shared) -> FormatRegistry {
        FormatRegistry(
            converters: [
                ImageConverter(tools: tools),
                PDFConverter(),
                DocumentConverter(),
                MarkdownConverter(),
                LibreOfficeConverter(tools: tools),   // before DocumentPDFConverter: better fidelity when installed
                DocumentPDFConverter(),
                ArchiveConverter(),
                AVFoundationConverter(),
                FFmpegConverter(tools: tools),
            ],
            batchConverters: [MergePDFConverter(), ZipAllConverter()]
        )
    }

    /// Keeps existing files, folders and packages; drops missing and non-file URLs.
    static func eligibleItems(_ urls: [URL]) -> [URL] {
        urls.filter { FileTypeResolver.isConvertibleItem($0) }
    }

    // MARK: Targets

    /// Formats every one of the files can be converted to (intersection), ordered available-first then by commonness.
    func targets(for urls: [URL]) -> [FormatTarget] {
        let files = Self.eligibleItems(urls)
        guard !files.isEmpty else { return [] }
        let types = files.map { FileTypeResolver.contentType(of: $0) }
        guard !types.contains(where: { $0 == nil }) else { return [] }
        return targets(forTypes: types.compactMap { $0 })
    }

    func targets(forTypes types: [UTType]) -> [FormatTarget] {
        guard !types.isEmpty else { return [] }
        let perType = types.map { candidates(for: $0) }
        guard var common = perType.first else { return [] }
        for next in perType.dropFirst() {
            common = common.filter { next[$0.key] != nil }
            for (id, target) in common {
                // Multi-file: a format is only usable if every file's converter is available.
                if case .unavailable = next[id]!.availability, case .available = target.availability {
                    common[id] = next[id]
                }
            }
        }
        if types.count >= 2 {
            for batch in batchConverters where types.allSatisfy(batch.accepts) {
                common[batch.format.id] = FormatTarget(format: batch.format, availability: batch.availability())
            }
        }
        return common.values.sorted(by: Self.ordering)
    }

    func batchConverter(for formatID: String) -> (any BatchConverter)? {
        batchConverters.first { $0.format.id == formatID }
    }

    private static func ordering(_ a: FormatTarget, _ b: FormatTarget) -> Bool {
        if a.availability.isAvailable != b.availability.isAvailable { return a.availability.isAvailable }
        return a.format.commonness < b.format.commonness
    }

    /// formatID -> best target for one input type
    private func candidates(for type: UTType) -> [String: FormatTarget] {
        var result: [String: FormatTarget] = [:]
        for converter in converters where converter.accepts(type) {
            for format in converter.outputFormats(for: type) {
                let target = FormatTarget(format: format, availability: converter.availability(of: format))
                if let existing = result[format.id], existing.availability.isAvailable { continue }
                result[format.id] = target
            }
        }
        return result
    }

    // MARK: Resolution

    /// Picks the converter that will convert `url` to `formatID` (first available, otherwise first capable).
    func resolve(url: URL, formatID: String) -> (converter: any Converter, format: OutputFormat)? {
        guard let type = FileTypeResolver.contentType(of: url) else { return nil }
        return resolve(type: type, formatID: formatID)
    }

    func resolve(type: UTType, formatID: String) -> (converter: any Converter, format: OutputFormat)? {
        var fallback: (any Converter, OutputFormat)?
        for converter in converters where converter.accepts(type) {
            guard let format = converter.outputFormats(for: type).first(where: { $0.id == formatID }) else { continue }
            if converter.availability(of: format).isAvailable { return (converter, format) }
            if fallback == nil { fallback = (converter, format) }
        }
        return fallback
    }
}
