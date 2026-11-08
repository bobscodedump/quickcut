import Foundation
import UniformTypeIdentifiers

enum FileTypeResolver {
    /// An existing file, folder or package on disk.
    static func isConvertibleItem(_ url: URL) -> Bool {
        url.isFileURL && FileManager.default.fileExists(atPath: url.path)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Best-effort type: Launch Services first, then magic-byte sniffing (for files without extension), then extension.
    static func contentType(of original: URL) -> UTType? {
        let url = original.resolvingSymlinksInPath()
        let reported = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if let reported, !reported.isDynamic, reported != .data, reported != .item { return reported }
        if let sniffed = sniff(url) { return sniffed }
        if !url.pathExtension.isEmpty, let byExt = UTType(filenameExtension: url.pathExtension), !byExt.isDynamic { return byExt }
        return reported
    }

    static func sniff(_ url: URL) -> UTType? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 4 else { return nil }
        let b = [UInt8](head)
        func has(_ s: String, at offset: Int = 0) -> Bool {
            let bytes = Array(s.utf8)
            return b.count >= offset + bytes.count && Array(b[offset..<offset + bytes.count]) == bytes
        }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if has("GIF8") { return .gif }
        if has("%PDF") { return .pdf }
        if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return .tiff }
        if has("RIFF"), b.count >= 12 {
            if has("WEBP", at: 8) { return .webP }
            if has("WAVE", at: 8) { return .wav }
        }
        if has("ftyp", at: 4) {
            let brand = String(decoding: b[8..<min(12, b.count)], as: UTF8.self)
            switch brand {
            case "heic", "heix", "mif1", "msf1", "hevc": return .heic
            case "qt  ": return .quickTimeMovie
            case "M4A ": return UTType(filenameExtension: "m4a")
            default: return .mpeg4Movie
            }
        }
        if has("ID3") { return .mp3 }
        if has("fLaC") { return UTType(filenameExtension: "flac") }
        if has("OggS") { return UTType(filenameExtension: "ogg") }
        if has("BM"), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 54 { return .bmp }
        return nil
    }
}
