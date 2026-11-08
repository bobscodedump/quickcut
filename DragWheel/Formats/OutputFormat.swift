import Foundation
import UniformTypeIdentifiers

/// A target format shown as a wheel slice.
struct OutputFormat: Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let fileExtension: String
    let symbolName: String
    /// Lower = more common. Used to pick the "most common 7" for the wheel.
    let commonness: Int

    var utType: UTType? { UTType(filenameExtension: fileExtension) }

    // Images
    static let png = OutputFormat(id: "png", displayName: "PNG", fileExtension: "png", symbolName: "photo", commonness: 0)
    static let jpeg = OutputFormat(id: "jpeg", displayName: "JPEG", fileExtension: "jpg", symbolName: "photo.fill", commonness: 1)
    static let pdf = OutputFormat(id: "pdf", displayName: "PDF", fileExtension: "pdf", symbolName: "doc.richtext", commonness: 2)
    static let heic = OutputFormat(id: "heic", displayName: "HEIC", fileExtension: "heic", symbolName: "photo.on.rectangle", commonness: 6)
    static let gif = OutputFormat(id: "gif", displayName: "GIF", fileExtension: "gif", symbolName: "play.square.stack", commonness: 9)
    static let webp = OutputFormat(id: "webp", displayName: "WebP", fileExtension: "webp", symbolName: "globe", commonness: 12)
    static let tiff = OutputFormat(id: "tiff", displayName: "TIFF", fileExtension: "tiff", symbolName: "photo.stack", commonness: 15)
    static let bmp = OutputFormat(id: "bmp", displayName: "BMP", fileExtension: "bmp", symbolName: "square.grid.3x3", commonness: 21)
    // Documents
    static let txt = OutputFormat(id: "txt", displayName: "TXT", fileExtension: "txt", symbolName: "doc.plaintext", commonness: 5)
    static let docx = OutputFormat(id: "docx", displayName: "DOCX", fileExtension: "docx", symbolName: "doc.text.fill", commonness: 8)
    static let html = OutputFormat(id: "html", displayName: "HTML", fileExtension: "html", symbolName: "chevron.left.forwardslash.chevron.right", commonness: 13)
    static let rtf = OutputFormat(id: "rtf", displayName: "RTF", fileExtension: "rtf", symbolName: "doc.text", commonness: 14)
    static let odt = OutputFormat(id: "odt", displayName: "ODT", fileExtension: "odt", symbolName: "doc", commonness: 22)
    // Video
    static let mp4 = OutputFormat(id: "mp4", displayName: "MP4", fileExtension: "mp4", symbolName: "film", commonness: 3)
    static let mov = OutputFormat(id: "mov", displayName: "MOV", fileExtension: "mov", symbolName: "film.stack", commonness: 11)
    static let mkv = OutputFormat(id: "mkv", displayName: "MKV", fileExtension: "mkv", symbolName: "rectangle.stack", commonness: 16)
    static let webm = OutputFormat(id: "webm", displayName: "WebM", fileExtension: "webm", symbolName: "play.rectangle", commonness: 17)
    // Audio
    static let mp3 = OutputFormat(id: "mp3", displayName: "MP3", fileExtension: "mp3", symbolName: "music.note", commonness: 4)
    static let m4a = OutputFormat(id: "m4a", displayName: "M4A", fileExtension: "m4a", symbolName: "music.note.list", commonness: 7)
    static let wav = OutputFormat(id: "wav", displayName: "WAV", fileExtension: "wav", symbolName: "waveform", commonness: 10)
    static let flac = OutputFormat(id: "flac", displayName: "FLAC", fileExtension: "flac", symbolName: "waveform.path", commonness: 18)
    static let aac = OutputFormat(id: "aac", displayName: "AAC", fileExtension: "aac", symbolName: "waveform.circle", commonness: 19)
    static let ogg = OutputFormat(id: "ogg", displayName: "OGG", fileExtension: "ogg", symbolName: "speaker.wave.2", commonness: 20)

    static let all: [OutputFormat] = [
        .png, .jpeg, .pdf, .heic, .gif, .webp, .tiff, .bmp,
        .txt, .docx, .html, .rtf, .odt,
        .mp4, .mov, .mkv, .webm,
        .mp3, .m4a, .wav, .flac, .aac, .ogg,
    ]

    static func format(withID id: String) -> OutputFormat? { all.first { $0.id == id } }
}
