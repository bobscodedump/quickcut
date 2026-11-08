import Foundation
import UniformTypeIdentifiers

/// Video / audio conversions through ffmpeg (looked up in Homebrew dirs and PATH).
struct FFmpegConverter: Converter {
    let id = "ffmpeg"
    let tools: ToolLocator
    var inputTypes: [UTType] { [.movie, .video, .audio] }

    static let installHint = "Install ffmpeg: brew install ffmpeg"

    init(tools: ToolLocator = .shared) { self.tools = tools }

    private static let videoOutputs: [OutputFormat] = [.mp4, .mov, .mkv, .webm, .gif, .mp3, .m4a, .wav]
    private static let audioOutputs: [OutputFormat] = [.mp3, .m4a, .wav, .aac, .flac, .ogg]

    static func isVideo(_ type: UTType) -> Bool { type.conforms(to: .movie) || type.conforms(to: .video) }

    func outputFormats(for input: UTType) -> [OutputFormat] {
        if Self.isVideo(input) { return excludingSelf(Self.videoOutputs, input: input) }
        if input.conforms(to: .audio) { return excludingSelf(Self.audioOutputs, input: input) }
        return []
    }

    func availability(of format: OutputFormat) -> Availability {
        tools.isAvailable("ffmpeg") ? .available : .unavailable(reason: Self.installHint)
    }

    func convert(
        input: URL, to format: OutputFormat, output: OutputReservation,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let ffmpeg = tools.locate("ffmpeg") else {
            throw ConversionError.toolMissing(tool: "ffmpeg", hint: "Run: brew install ffmpeg")
        }
        let inputIsVideo = FileTypeResolver.contentType(of: input).map(Self.isVideo) ?? false
        let out = try output.reserveFile(ext: format.fileExtension)
        let duration = await probeDuration(of: input)
        let encoders = await Self.encoders(ffmpeg: ffmpeg)

        let tracker: @Sendable (String) -> Void = { line in
            guard let duration, duration > 0, line.hasPrefix("out_time_us="),
                  let micros = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress(min(0.99, max(0, micros / 1_000_000 / duration)))
        }

        var lastError: Error = ConversionError.toolFailed(tool: "ffmpeg", message: "")
        for extra in Self.attempts(for: format, inputIsVideo: inputIsVideo, encoders: encoders) {
            try Task.checkCancellation()
            let args = ["-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-i", input.path] + extra + [out.path]
            let result = try await ProcessRunner.run(executable: ffmpeg, arguments: args, onStdoutLine: tracker)
            if result.status == 0 {
                progress(1)
                return out
            }
            lastError = ConversionError.toolFailed(tool: "ffmpeg", message: result.stderr)
        }
        throw lastError
    }

    // MARK: Command lines

    /// Argument sets to try in order (e.g. stream copy first, re-encode as fallback).
    static func attempts(for format: OutputFormat, inputIsVideo: Bool, encoders: Set<String>) -> [[String]] {
        switch format.id {
        case "mp4":
            return [["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]]
        case "mov":
            return [["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]]
        case "mkv":
            return [["-map", "0", "-c", "copy"],
                    ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]]
        case "webm":
            return [["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]]
        case "gif":
            return [["-an", "-vf", "fps=12,scale='min(480,iw)':-2:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse", "-loop", "0"]]
        case "mp3":
            return [["-vn", "-c:a", "libmp3lame", "-q:a", "2"]]
        case "m4a":
            return [["-vn", "-c:a", "aac", "-b:a", "192k"]]
        case "wav":
            return [["-vn", "-c:a", "pcm_s16le"]]
        case "aac":
            return [["-vn", "-c:a", "aac", "-b:a", "192k", "-f", "adts"]]
        case "flac":
            return [["-vn", "-c:a", "flac"]]
        case "ogg":
            if encoders.contains("libvorbis") { return [["-vn", "-c:a", "libvorbis", "-q:a", "5"]] }
            if encoders.contains("libopus") { return [["-vn", "-c:a", "libopus", "-b:a", "160k"]] }
            return [["-vn", "-c:a", "vorbis", "-strict", "-2", "-q:a", "5"]]
        default:
            return [[]]
        }
    }

    private static func encoders(ffmpeg: URL) async -> Set<String> {
        guard let result = try? await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-encoders"]) else { return [] }
        var names = Set<String>()
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0].count == 6 { names.insert(String(parts[1])) }
        }
        return names
    }

    private func probeDuration(of input: URL) async -> Double? {
        guard let ffprobe = tools.locate("ffprobe"),
              let result = try? await ProcessRunner.run(
                executable: ffprobe,
                arguments: ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", input.path]
              ) else { return nil }
        return Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
