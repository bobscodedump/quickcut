import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// ffmpeg-free fallback: MOV ↔ MP4 (passthrough where possible), and audio → M4A.
struct AVFoundationConverter: Converter {
    let id = "avfoundation"
    var inputTypes: [UTType] { [.quickTimeMovie, .mpeg4Movie, .audio] }

    /// Audio containers AVFoundation reads reliably.
    private var readableAudio: [UTType] {
        [.mp3, .wav, .aiff, .mpeg4Audio, UTType("public.aac-audio"), UTType("com.apple.coreaudio-format"), UTType("org.xiph.flac")].compactMap { $0 }
    }

    func accepts(_ type: UTType) -> Bool {
        if type.conforms(to: .quickTimeMovie) || type.conforms(to: .mpeg4Movie) { return true }
        return readableAudio.contains { type.conforms(to: $0) }
    }

    func outputFormats(for input: UTType) -> [OutputFormat] {
        if input.conforms(to: .quickTimeMovie) { return [.mp4, .m4a] }
        if input.conforms(to: .mpeg4Movie) { return [.mov, .m4a] }
        return excludingSelf([.m4a], input: input)
    }

    func convert(
        input: URL, to format: OutputFormat, output: OutputReservation,
        options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let fileType: AVFileType
        let presets: [String]
        switch format.id {
        case "mp4": fileType = .mp4; presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        case "mov": fileType = .mov; presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        case "m4a": fileType = .m4a; presets = [AVAssetExportPresetAppleM4A]
        default: throw ConversionError.unsupported("AVFoundation can't produce \(format.displayName).")
        }

        let out = try output.reserveFile(ext: format.fileExtension)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dragwheel-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }

        var lastError: Error = ConversionError.unsupported("This file can't be converted without ffmpeg (brew install ffmpeg).")
        for preset in presets {
            try Task.checkCancellation()
            do {
                try await export(asset: asset, preset: preset, fileType: fileType, to: temp, progress: progress)
                try output.commit(temp: temp, to: out)
                progress(1)
                return out
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: temp)
            }
        }
        throw lastError
    }

    private func export(
        asset: AVURLAsset, preset: String, fileType: AVFileType, to temp: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset),
              session.supportedFileTypes.contains(fileType) else {
            throw ConversionError.unsupported("Export preset \(preset) isn't compatible with this file.")
        }
        session.outputURL = temp
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = fileType == .mp4

        let box = SessionBox(session)
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { cont.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        poller.cancel()

        switch session.status {
        case .completed: return
        case .cancelled: throw CancellationError()
        default: throw session.error ?? ConversionError.outputFailed("AVFoundation export failed.")
        }
    }
}

/// AVAssetExportSession is thread-safe for the calls used here (progress / cancel) but isn't marked Sendable.
private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
