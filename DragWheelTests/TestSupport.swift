import XCTest
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import DragWheel

/// Base class: gives each test a private temp directory that is removed afterwards.
class DWTestCase: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DragWheelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in
            if let dir {
                // Restore permissions in case a test made something read-only.
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// Runs a converter the same way ConversionManager does.
    func convert(_ converter: some Converter, _ input: URL, to format: OutputFormat,
                 options: ConversionOptions = ConversionOptions()) async throws -> URL {
        let reservation = OutputReservation(directory: input.deletingLastPathComponent(), baseName: input.deletingPathExtension().lastPathComponent)
        do {
            return try await converter.convert(input: input, to: format, output: reservation, options: options, progress: { _ in })
        } catch {
            reservation.rollback()
            throw error
        }
    }

    func imageInfo(_ url: URL) -> (type: String, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return (type as String, props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }
}

enum Fixtures {
    /// A small gradient PNG (optionally with transparency).
    @discardableResult
    static func png(at url: URL, width: Int = 64, height: Int = 48, alpha: Bool = false) throws -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<width {
            ctx.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: 0.4, blue: 0.8, alpha: alpha && x < width / 2 ? 0.3 : 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// A white PNG with large black text (OCR fixture).
    @discardableResult
    static func textImage(at url: URL, text: String, width: Int = 1000, height: Int = 220) throws -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: 30, y: 70))
        NSGraphicsContext.restoreGraphicsState()
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Writes an executable shell script (used to fake external tools).
    @discardableResult
    static func script(at url: URL, _ body: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Lists the entries of a zip file.
    static func zipEntries(_ url: URL) async throws -> [String] {
        let r = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/zipinfo"), arguments: ["-1", url.path])
        XCTAssertEqual(r.status, 0, r.stderr)
        return r.stdout.split(separator: "\n").map(String.init)
    }

    /// A PDF with real, extractable text — one page per string.
    @discardableResult
    static func pdf(at url: URL, pages: [String]) throws -> URL {
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            ctx.beginPDFPage(nil)
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
                .draw(at: NSPoint(x: 20, y: 90))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// 16-bit mono PCM WAV with a sine tone.
    @discardableResult
    static func wav(at url: URL, seconds: Double = 0.5, sampleRate: Int = 8000) throws -> URL {
        let count = Int(seconds * Double(sampleRate))
        var pcm = Data()
        for i in 0..<count {
            let sample = Int16(sin(2 * .pi * 440 * Double(i) / Double(sampleRate)) * 12000)
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var header = Data("RIFF".utf8)
        header += le32(36 + pcm.count) + Data("WAVEfmt ".utf8) + le32(16) + le16(1) + le16(1)
        header += le32(sampleRate) + le32(sampleRate * 2) + le16(2) + le16(16) + Data("data".utf8) + le32(pcm.count)
        try (header + pcm).write(to: url)
        return url
    }

    /// 1 second, 64×64 H.264 video written with AVAssetWriter (no ffmpeg needed).
    @discardableResult
    static func video(at url: URL, fileType: AVFileType) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 25), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError.outputFailed("fixture video failed") }
        return url
    }

    static var ffmpegURL: URL? { ToolLocator.shared.locate("ffmpeg") }

    /// Generates an MP4 with video + audio via ffmpeg's lavfi sources (tests are skipped without ffmpeg).
    static func videoWithAudio(at url: URL) async throws {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg not installed") }
        let r = try await ProcessRunner.run(executable: ffmpeg, arguments: [
            "-nostdin", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=64x64:rate=10",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path,
        ])
        XCTAssertEqual(r.status, 0, r.stderr)
    }

    /// Container name reported by ffprobe, e.g. "matroska,webm".
    static func containerName(_ url: URL) async -> String? {
        guard let probe = ToolLocator.shared.locate("ffprobe"),
              let r = try? await ProcessRunner.run(executable: probe, arguments: ["-v", "error", "-show_entries", "format=format_name", "-of", "default=nw=1:nk=1", url.path])
        else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
