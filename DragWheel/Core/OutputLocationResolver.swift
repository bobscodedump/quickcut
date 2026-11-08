import Foundation

struct ResolvedOutputLocation: Equatable {
    let directory: URL
    /// Human readable note when the preferred location couldn't be used.
    let note: String?
}

enum OutputLocationResolver {
    /// Decides where the output of `source` goes.
    /// - fixed folder (if configured, existing and writable)
    /// - next to the original
    /// - ~/Downloads when the original's folder is read-only
    static func resolve(
        for source: URL,
        mode: OutputLocationMode,
        fixedFolder: URL?,
        downloads: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    ) -> ResolvedOutputLocation {
        let fm = FileManager.default
        func writableDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue && fm.isWritableFile(atPath: url.path)
        }

        var note: String?
        if mode == .fixedFolder {
            if let fixed = fixedFolder, writableDirectory(fixed) {
                return ResolvedOutputLocation(directory: fixed, note: nil)
            }
            note = "The fixed output folder isn't available."
        }

        let sibling = source.deletingLastPathComponent()
        if writableDirectory(sibling) {
            return ResolvedOutputLocation(directory: sibling, note: note.map { $0 + " Saved next to the original." })
        }
        if let downloads {
            return ResolvedOutputLocation(directory: downloads, note: "Saved to Downloads because \(sibling.lastPathComponent) is read-only.")
        }
        return ResolvedOutputLocation(directory: sibling, note: nil)
    }
}
