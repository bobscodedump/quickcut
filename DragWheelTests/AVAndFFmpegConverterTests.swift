import XCTest
import AVFoundation
import UniformTypeIdentifiers
@testable import DragWheel

final class AVFoundationConverterTests: DWTestCase {
    let converter = AVFoundationConverter()

    private func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    func testMOVToMP4() async throws {
        let mov = try await Fixtures.video(at: url("clip.mov"), fileType: .mov)
        let out = try await convert(converter, mov, to: .mp4)
        XCTAssertEqual(out.lastPathComponent, "clip.mp4")
        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let d = try await duration(out)
        XCTAssertEqual(d, 1.0, accuracy: 0.3)
        XCTAssertEqual(try Data(contentsOf: out).subdata(in: 4..<8), Data("ftyp".utf8))
    }

    func testMP4ToMOV() async throws {
        let mp4 = try await Fixtures.video(at: url("clip.mp4"), fileType: .mp4)
        let out = try await convert(converter, mp4, to: .mov)
        XCTAssertEqual(out.lastPathComponent, "clip.mov")
        let d = try await duration(out)
        XCTAssertEqual(d, 1.0, accuracy: 0.3)
    }

    func testWAVToM4A() async throws {
        let wav = try Fixtures.wav(at: url("tone.wav"), seconds: 1)
        let out = try await convert(converter, wav, to: .m4a)
        XCTAssertEqual(out.lastPathComponent, "tone.m4a")
        let d = try await duration(out)
        XCTAssertEqual(d, 1.0, accuracy: 0.2)
        let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
    }

    func testVideoToM4AExtractsAudioOrFailsCleanly() async throws {
        // Fixture video has no audio track: the export must fail without leaving junk behind.
        let mov = try await Fixtures.video(at: url("silent.mov"), fileType: .mov)
        do {
            _ = try await convert(converter, mov, to: .m4a)
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url("silent.m4a").path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: mov.path))
    }

    func testOutputFormats() {
        XCTAssertEqual(converter.outputFormats(for: .quickTimeMovie).map(\.id), ["mp4", "m4a"])
        XCTAssertEqual(converter.outputFormats(for: .mpeg4Movie).map(\.id), ["mov", "m4a"])
        XCTAssertEqual(converter.outputFormats(for: .mp3).map(\.id), ["m4a"])
        XCTAssertEqual(converter.outputFormats(for: UTType(filenameExtension: "m4a")!).map(\.id), [])
        XCTAssertFalse(converter.accepts(UTType(filenameExtension: "ogg")!), "AVFoundation can't read Ogg")
        XCTAssertFalse(converter.accepts(UTType(filenameExtension: "mkv")!))
    }

    func testCorruptMovieFails() async throws {
        let bad = url("bad.mov")
        try Data(repeating: 7, count: 100).write(to: bad)
        do { _ = try await convert(converter, bad, to: .mp4); XCTFail("expected failure") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("bad.mp4").path))
    }
}

final class FFmpegConverterTests: DWTestCase {
    let converter = FFmpegConverter()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(Fixtures.ffmpegURL == nil, "ffmpeg not installed")
    }

    func testVideoConversions() async throws {
        let src = url("movie.mp4")
        try await Fixtures.videoWithAudio(at: src)
        let cases: [(OutputFormat, String)] = [(.mov, "mov"), (.mkv, "matroska"), (.webm, "matroska"), (.gif, "gif")]
        for (format, container) in cases {
            let out = try await convert(converter, src, to: format)
            XCTAssertEqual(out.lastPathComponent, "movie.\(format.fileExtension)")
            if let name = await Fixtures.containerName(out) {
                XCTAssertTrue(name.contains(container), "\(format.id): container was \(name)")
            }
            XCTAssertGreaterThan(try out.resourceValues(forKeys: [.fileSizeKey]).fileSize!, 100, format.id)
        }
    }

    func testMKVToMP4() async throws {
        let mp4 = url("src.mp4")
        try await Fixtures.videoWithAudio(at: mp4)
        let mkv = try await convert(converter, mp4, to: .mkv)
        let back = try await convert(converter, mkv, to: .mp4)
        XCTAssertEqual(back.lastPathComponent, "src 2.mp4")
        let name = await Fixtures.containerName(back)
        XCTAssertTrue(name?.contains("mp4") ?? true)
    }

    func testExtractAudioFromVideo() async throws {
        let src = url("talk.mp4")
        try await Fixtures.videoWithAudio(at: src)
        for (format, hint) in [(OutputFormat.mp3, "mp3"), (.m4a, "mp4"), (.wav, "wav")] {
            let out = try await convert(converter, src, to: format)
            if let name = await Fixtures.containerName(out) { XCTAssertTrue(name.contains(hint), "\(format.id): \(name)") }
            let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
            XCTAssertTrue(tracks.isEmpty, "\(format.id) should be audio only")
        }
    }

    func testAudioConversions() async throws {
        let wav = try Fixtures.wav(at: url("tone.wav"), seconds: 1)
        let cases: [(OutputFormat, String)] = [(.mp3, "mp3"), (.m4a, "mp4"), (.aac, "aac"), (.flac, "flac"), (.ogg, "ogg")]
        for (format, container) in cases {
            let out = try await convert(converter, wav, to: format)
            XCTAssertEqual(out.lastPathComponent, "tone.\(format.fileExtension)")
            if let name = await Fixtures.containerName(out) { XCTAssertTrue(name.contains(container), "\(format.id): \(name)") }
        }
        // And back to WAV from FLAC.
        let flac = url("tone.flac")
        let wavAgain = try await convert(converter, flac, to: .wav)
        XCTAssertEqual(wavAgain.lastPathComponent, "tone 2.wav")
    }

    func testProgressReachesOne() async throws {
        let wav = try Fixtures.wav(at: url("p.wav"), seconds: 2)
        final class Box: @unchecked Sendable { var values: [Double] = [] }
        let box = Box()
        let reservation = OutputReservation(directory: dir, baseName: "p")
        _ = try await converter.convert(input: wav, to: .mp3, output: reservation, options: .init()) { box.values.append($0) }
        XCTAssertEqual(box.values.last, 1)
        XCTAssertTrue(box.values.allSatisfy { (0...1).contains($0) })
    }

    func testFailureCleansUpAndReportsStderr() async throws {
        let bad = url("bad.mp3")
        try Data("this is not audio".utf8).write(to: bad)
        do { _ = try await convert(converter, bad, to: .wav); XCTFail("expected failure") }
        catch let error as ConversionError {
            XCTAssertTrue(error.localizedDescription.contains("ffmpeg failed"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("bad.wav").path), "placeholder must be removed")
    }

    func testMissingFFmpegGivesInstallHint() async throws {
        let none = FFmpegConverter(tools: ToolLocator(searchDirectories: [], includePATH: false))
        XCTAssertEqual(none.availability(of: .mp3), .unavailable(reason: "Install ffmpeg: brew install ffmpeg"))
        let wav = try Fixtures.wav(at: url("m.wav"))
        do { _ = try await convert(none, wav, to: .mp3); XCTFail("expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("brew install ffmpeg")) }
    }

    func testCancellationTerminatesProcess() async throws {
        let src = url("long.mp4")
        try await Fixtures.videoWithAudio(at: src)
        let reservation = OutputReservation(directory: dir, baseName: "long")
        let task = Task { try await converter.convert(input: src, to: .webm, output: reservation, options: .init()) { _ in } }
        task.cancel()
        do { _ = try await task.value } catch { /* cancelled or failed — both fine */ }
        reservation.rollback()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("long.webm").path))
    }
}
