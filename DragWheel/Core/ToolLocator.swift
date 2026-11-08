import Foundation

/// Finds command line tools (ffmpeg, cwebp, ...). GUI apps get a minimal PATH, so Homebrew
/// locations are searched explicitly before falling back to PATH.
struct ToolLocator: Sendable {
    static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
    static let shared = ToolLocator()

    let searchDirectories: [String]
    /// Also look inside app bundles in /Applications (LibreOffice). Off for test locators.
    let searchApplications: Bool

    init(searchDirectories: [String]? = nil, includePATH: Bool = true) {
        searchApplications = includePATH
        var dirs = searchDirectories ?? Self.homebrewDirectories
        if includePATH {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            dirs += path.split(separator: ":").map(String.init)
        }
        var seen = Set<String>()
        self.searchDirectories = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func locate(_ name: String) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories {
            let candidate = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue, fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    func isAvailable(_ name: String) -> Bool { locate(name) != nil }

    /// LibreOffice's command line binary: `soffice` on PATH / Homebrew, or inside LibreOffice.app.
    func locateSoffice() -> URL? {
        if let url = locate("soffice") { return url }
        guard searchApplications else { return nil }
        let candidates = ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
                          NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
