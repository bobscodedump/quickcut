import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image ↔ image (ImageIO), image → PDF, and image → TXT (OCR via Vision).
/// WebP encoding uses cwebp or ffmpeg because ImageIO can't encode it.
struct ImageConverter: Converter {
    let id = "image"
    let tools: ToolLocator
    var inputTypes: [UTType] { [.image] }

    init(tools: ToolLocator = .shared) { self.tools = tools }

    func accepts(_ type: UTType) -> Bool {
        type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    func outputFormats(for input: UTType) -> [OutputFormat] {
        excludingSelf([.png, .jpeg, .heic, .tiff, .gif, .bmp, .webp, .avif, .ico, .icns, .pdf, .txt], input: input)
    }

    func availability(of format: OutputFormat) -> Availability {
        switch format.id {
        case "heic", "avif", "ico", "icns":
            return ImageCodec.canEncodeNatively(format.id) ? .available : .unavailable(reason: "This Mac can't encode \(format.displayName).")
        case "webp":
            if ImageCodec.canEncodeNatively("webp") || tools.isAvailable("cwebp") || tools.isAvailable("ffmpeg") { return .available }
            return .unavailable(reason: "Install a WebP encoder: brew install webp")
        default:
            return .available
        }
    }

    func convert(
        input: URL, to format: OutputFormat, output: OutputReservation,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        progress(0.05)
        let image = try ImageCodec.load(url: input)
        try Task.checkCancellation()
        progress(0.4)
        let out = try output.reserveFile(ext: format.fileExtension)
        switch format.id {
        case "pdf":
            try ImageCodec.writePDF(image, to: out)
        case "txt":
            let text = try TextRecognizer.recognize(image)
            guard !text.isEmpty else { throw ConversionError.noText }
            try text.write(to: out, atomically: true, encoding: .utf8)
        case "webp" where !ImageCodec.canEncodeNatively("webp"):
            try await encodeWebP(image, to: out, quality: options.imageQuality)
        default:
            try ImageCodec.write(image, formatID: format.id, quality: options.imageQuality, to: out)
        }
        progress(1)
        return out
    }

    private func encodeWebP(_ image: CGImage, to out: URL, quality: Double) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dragwheel-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try ImageCodec.write(image, formatID: "png", quality: 1, to: temp)
        let q = String(Int((quality * 100).rounded()))
        if let cwebp = tools.locate("cwebp") {
            let result = try await ProcessRunner.run(executable: cwebp, arguments: ["-quiet", "-q", q, temp.path, "-o", out.path])
            guard result.status == 0 else { throw ConversionError.toolFailed(tool: "cwebp", message: result.stderr + result.stdout) }
        } else if let ffmpeg = tools.locate("ffmpeg") {
            let result = try await ProcessRunner.run(
                executable: ffmpeg,
                arguments: ["-nostdin", "-y", "-loglevel", "error", "-i", temp.path, "-c:v", "libwebp", "-quality", q, out.path]
            )
            guard result.status == 0 else { throw ConversionError.toolFailed(tool: "ffmpeg", message: result.stderr) }
        } else {
            throw ConversionError.toolMissing(tool: "cwebp", hint: "Install it with: brew install webp")
        }
    }
}
