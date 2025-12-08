import Foundation
import os.log

/// Stores and restores security-scoped bookmarks for CLI executables.
/// This allows sandboxed apps to access user-selected executables.
actor CLIBookmarkStore {
    static let shared = CLIBookmarkStore()

    private let logger = Logger(subsystem: "dev.agency.app", category: "CLIBookmarkStore")
    private let userDefaults: UserDefaults
    private let bookmarkKey = "claudeCodeCLIBookmark"
    private let cliPathKey = "claudeCodeCLIPath"

    private var cachedFolderURL: URL?
    private var cachedCLIPath: String?
    private var isAccessing = false

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Saves pre-created bookmark data for the folder containing the CLI.
    /// Use this when the bookmark data was created while the security-scoped resource was accessible.
    func saveBookmarkData(_ data: Data, cliPath: String, folderURL: URL) throws {
        logger.info("Saving folder bookmark for CLI: \(cliPath) (\(data.count) bytes)")
        userDefaults.set(data, forKey: bookmarkKey)
        userDefaults.set(cliPath, forKey: cliPathKey)
        cachedFolderURL = folderURL
        cachedCLIPath = cliPath
        logger.info("Bookmark data saved successfully")
    }

    /// Restores the CLI URL from the saved bookmark.
    /// Returns nil if no bookmark exists or if it's stale.
    func restoreBookmark() -> URL? {
        // Return cached CLI path if we have one and are already accessing
        if let cliPath = cachedCLIPath, isAccessing {
            return URL(fileURLWithPath: cliPath)
        }

        guard let bookmarkData = userDefaults.data(forKey: bookmarkKey),
              let cliPath = userDefaults.string(forKey: cliPathKey) else {
            logger.info("No bookmark data found")
            return nil
        }

        do {
            var isStale = false
            let folderURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                logger.warning("Bookmark is stale, needs re-selection")
            }

            cachedFolderURL = folderURL
            cachedCLIPath = cliPath
            logger.info("Restored bookmark for folder: \(folderURL.path), CLI: \(cliPath)")
            return URL(fileURLWithPath: cliPath)

        } catch {
            logger.error("Failed to restore bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns just the CLI path without starting access.
    func getCLIPath() -> String? {
        if let cached = cachedCLIPath {
            return cached
        }
        return userDefaults.string(forKey: cliPathKey)
    }

    /// Starts accessing the security-scoped resource.
    /// Call this before executing the CLI.
    func startAccessing() -> URL? {
        // First restore the bookmark to get folder and CLI path
        guard let cliURL = restoreBookmark(),
              let folderURL = cachedFolderURL else {
            return nil
        }

        if !isAccessing {
            // Start accessing the folder (which grants access to files within)
            let success = folderURL.startAccessingSecurityScopedResource()
            logger.info("Started accessing security-scoped folder: \(success) - \(folderURL.path)")
            isAccessing = success
        }

        return isAccessing ? cliURL : nil
    }

    /// Stops accessing the security-scoped resource.
    /// Call this after executing the CLI.
    func stopAccessing() {
        if isAccessing, let folderURL = cachedFolderURL {
            folderURL.stopAccessingSecurityScopedResource()
            isAccessing = false
            logger.info("Stopped accessing security-scoped resource")
        }
    }

    /// Clears the saved bookmark.
    func clearBookmark() {
        stopAccessing()
        userDefaults.removeObject(forKey: bookmarkKey)
        userDefaults.removeObject(forKey: cliPathKey)
        cachedFolderURL = nil
        cachedCLIPath = nil
        logger.info("Cleared bookmark")
    }

    /// Whether a bookmark exists.
    var hasBookmark: Bool {
        userDefaults.data(forKey: bookmarkKey) != nil && userDefaults.string(forKey: cliPathKey) != nil
    }
}
