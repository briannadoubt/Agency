import Foundation

enum CardMoveError: LocalizedError, Equatable {
    case snapshotUnavailable
    case cardOutsideProject
    case destinationFolderMissing(CardStatus)
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .snapshotUnavailable:
            return "No project is loaded."
        case .cardOutsideProject:
            return "Card is outside the selected project."
        case .destinationFolderMissing(let status):
            return "Missing \(status.folderName) folder."
        case .moveFailed(let message):
            return "Unable to move card: \(message)"
        }
    }
}

/// Moves cards between status folders, ensuring the operation either completes or restores the source.
actor CardMover {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func move(card: Card, to newStatus: CardStatus, rootURL: URL) async throws {
        let standardizedRoot = rootURL.standardizedFileURL
        let sourceURL = card.filePath.standardizedFileURL

        guard sourceURL.path.hasPrefix(standardizedRoot.path) else {
            throw CardMoveError.cardOutsideProject
        }

        guard card.status != newStatus else { return }

        let phaseURL = sourceURL.deletingLastPathComponent().deletingLastPathComponent()
        let destinationDirectory = phaseURL.appendingPathComponent(newStatus.folderName, isDirectory: true)

        guard directoryExists(at: destinationDirectory) else {
            throw CardMoveError.destinationFolderMissing(newStatus)
        }

        let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        let stagingURL = stagingURL(for: destinationDirectory, filename: sourceURL.lastPathComponent)

        do {
            try moveWithStaging(from: sourceURL, stagingURL: stagingURL, destinationURL: destinationURL)
        } catch {
            throw CardMoveError.moveFailed(error.localizedDescription)
        }
    }

    private func moveWithStaging(from sourceURL: URL, stagingURL: URL, destinationURL: URL) throws {
        try? fileManager.removeItem(at: stagingURL)
        try fileManager.moveItem(at: sourceURL, to: stagingURL)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            try? fileManager.moveItem(at: stagingURL, to: sourceURL)
            throw error
        }
    }

    private func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func stagingURL(for directory: URL, filename: String) -> URL {
        directory.appendingPathComponent(".\(filename).staging-\(UUID().uuidString)")
    }
}
