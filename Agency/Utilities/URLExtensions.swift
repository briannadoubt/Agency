import Foundation

extension URL {
    /// Returns the relative path of this URL from the given root URL.
    /// If the URL is not under the root, returns the full path.
    func relativePath(from root: URL) -> String {
        let rootPath = root.path
        let selfPath = path

        if selfPath.hasPrefix(rootPath + "/") {
            return String(selfPath.dropFirst(rootPath.count + 1))
        }
        return selfPath
    }
}
