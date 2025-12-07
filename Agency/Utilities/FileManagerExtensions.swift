import Foundation

extension FileManager {
    /// Returns true if a directory exists at the given URL.
    nonisolated func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Returns true if the URL points to a directory.
    nonisolated func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Returns true if the URL points to a regular file (not a directory).
    nonisolated func isRegularFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }
}
