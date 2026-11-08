import Foundation

/// Atomically reserves unique output names ("photo.jpg", "photo 2.jpg", "photo 3.jpg"...).
/// Reservation uses O_EXCL / non-intermediate directory creation, so concurrent jobs and
/// existing files are never overwritten. Only items this object created can be rolled back.
final class OutputReservation: @unchecked Sendable {
    let directory: URL
    let baseName: String
    private let lock = NSLock()
    private var created: [URL] = []

    init(directory: URL, baseName: String) {
        self.directory = directory
        self.baseName = baseName
    }

    private func candidateName(_ n: Int, ext: String, suffix: String) -> String {
        let stem = n == 1 ? "\(baseName)\(suffix)" : "\(baseName)\(suffix) \(n)"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// Creates an empty placeholder file with a unique name and returns its URL.
    func reserveFile(ext: String, suffix: String = "") throws -> URL {
        lock.lock(); defer { lock.unlock() }
        for n in 1...100_000 {
            let url = directory.appendingPathComponent(candidateName(n, ext: ext, suffix: suffix))
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 {
                close(fd)
                created.append(url)
                return url
            }
            if errno == EEXIST { continue }
            throw ConversionError.outputFailed("Can't create \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        throw ConversionError.outputFailed("No free file name for \(baseName)")
    }

    /// Creates a uniquely named directory (used for multi-page PDF output).
    func reserveDirectory(suffix: String = "") throws -> URL {
        lock.lock(); defer { lock.unlock() }
        for n in 1...100_000 {
            let url = directory.appendingPathComponent(candidateName(n, ext: "", suffix: suffix), isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                created.append(url)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw ConversionError.outputFailed("Can't create folder \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        throw ConversionError.outputFailed("No free folder name for \(baseName)")
    }

    /// Replaces a reserved placeholder with a finished temp file.
    func commit(temp: URL, to reserved: URL) throws {
        _ = try FileManager.default.replaceItemAt(reserved, withItemAt: temp)
    }

    /// Removes everything this reservation created (called when a conversion fails or is cancelled).
    func rollback() {
        lock.lock(); defer { lock.unlock() }
        for url in created.reversed() { try? FileManager.default.removeItem(at: url) }
        created.removeAll()
    }

    var reservedItems: [URL] {
        lock.lock(); defer { lock.unlock() }
        return created
    }
}
