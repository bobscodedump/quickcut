import Foundation
import UniformTypeIdentifiers

enum Availability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
    var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

struct ConversionOptions: Sendable, Equatable {
    /// 0.1...1.0, applies to JPEG / HEIC / WebP.
    var imageQuality: Double = 0.85
}

enum ConversionError: LocalizedError {
    case unreadableInput
    case unsupported(String)
    case toolMissing(tool: String, hint: String)
    case toolFailed(tool: String, message: String)
    case noText
    case locked
    case outputFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableInput: return "The file couldn't be read or decoded."
        case .unsupported(let m): return m
        case .toolMissing(let tool, let hint): return "\(tool) isn't installed. \(hint)"
        case .toolFailed(let tool, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = trimmed.count > 400 ? "…" + trimmed.suffix(400) : trimmed
            return tail.isEmpty ? "\(tool) failed." : "\(tool) failed: \(tail)"
        case .noText: return "No text could be found (OCR found nothing either)."
        case .locked: return "The PDF is password protected."
        case .outputFailed(let m): return m
        }
    }
}

/// A pluggable conversion backend.
///
/// To add a converter: implement this protocol and add an instance to `FormatRegistry.makeDefault`.
protocol Converter: Sendable {
    /// Stable identifier, used in logs.
    var id: String { get }
    /// Types this converter reads (matched with conformance, see `accepts`).
    var inputTypes: [UTType] { get }
    /// Whether this converter can read `type`. Default: conforms to any of `inputTypes`.
    func accepts(_ type: UTType) -> Bool
    /// Formats this converter can produce from `input` (must not include the input's own format).
    func outputFormats(for input: UTType) -> [OutputFormat]
    /// Whether `format` can be produced right now (e.g. a required tool is installed).
    func availability(of format: OutputFormat) -> Availability
    /// Performs the conversion. Reserve output names via `output` (never write elsewhere),
    /// report progress in 0...1, honor task cancellation, and return the produced file or folder.
    func convert(
        input: URL,
        to format: OutputFormat,
        output: OutputReservation,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

extension Converter {
    func accepts(_ type: UTType) -> Bool {
        inputTypes.contains { type.conforms(to: $0) }
    }

    func availability(of format: OutputFormat) -> Availability { .available }

    /// Removes formats that equal the input's own type (png → png makes no sense).
    func excludingSelf(_ formats: [OutputFormat], input: UTType) -> [OutputFormat] {
        formats.filter { format in
            guard let own = format.utType else { return true }
            return !input.conforms(to: own)
        }
    }
}

/// Several inputs → one output (e.g. merge into one PDF, zip a selection).
/// Offered only when 2 or more items are dropped and every one is accepted.
protocol BatchConverter: Sendable {
    var id: String { get }
    var format: OutputFormat { get }
    func accepts(_ type: UTType) -> Bool
    func availability() -> Availability
    /// Base name of the produced file, e.g. "Merged" → "Merged.pdf", "Merged 2.pdf"…
    func outputBaseName(for inputs: [URL]) -> String
    func convert(
        inputs: [URL],
        output: OutputReservation,
        options: ConversionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

extension BatchConverter {
    func availability() -> Availability { .available }
}

extension UTType {
    static func byExtension(_ ext: String) -> UTType? { UTType(filenameExtension: ext) }
}
