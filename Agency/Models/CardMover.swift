import Foundation

enum CardMoveError: LocalizedError, Equatable {
    case snapshotUnavailable
    case cardOutsideProject
    case destinationFolderMissing(CardStatus)
    case illegalTransition(from: CardStatus, to: CardStatus)
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .snapshotUnavailable:
            return "No project is loaded."
        case .cardOutsideProject:
            return "Card is outside the selected project."
        case .destinationFolderMissing(let status):
            return "Missing \(status.folderName) folder."
        case .illegalTransition(let from, let to):
            return "Cannot move from \(from.displayName) to \(to.displayName) without passing through each column."
        case .moveFailed(let message):
            return "Unable to move card: \(message)"
        }
    }
}

/// Moves cards between status folders, ensuring the operation either completes or restores the source.
@MainActor
final class CardMover {
    private let fileManager: FileManager
    private let dateProvider: () -> Date

    init(fileManager: FileManager = .default,
         dateProvider: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.dateProvider = dateProvider
    }

    func move(card: Card,
              to newStatus: CardStatus,
              rootURL: URL,
              logHistoryEntry: Bool = false) async throws {
        let standardizedRoot = rootURL.standardizedFileURL
        let sourceURL = card.filePath.standardizedFileURL

        guard sourceURL.path.hasPrefix(standardizedRoot.path) else {
            throw CardMoveError.cardOutsideProject
        }

        guard card.status != newStatus else { return }

        guard card.status.canTransition(to: newStatus) else {
            throw CardMoveError.illegalTransition(from: card.status, to: newStatus)
        }

        let phaseURL = sourceURL.deletingLastPathComponent().deletingLastPathComponent()
        let destinationDirectory = phaseURL.appendingPathComponent(newStatus.folderName, isDirectory: true)

        guard fileManager.directoryExists(at: destinationDirectory) else {
            throw CardMoveError.destinationFolderMissing(newStatus)
        }

        let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        let stagingURL = stagingURL(for: destinationDirectory, filename: sourceURL.lastPathComponent)

        let originalStatus = card.status

        do {
            try moveWithStaging(from: sourceURL, stagingURL: stagingURL, destinationURL: destinationURL)

            if logHistoryEntry {
                do {
                    let contents = try String(contentsOf: destinationURL, encoding: .utf8)
                    let destinationCard = try CardFileParser().parse(fileURL: destinationURL, contents: contents)
                    try appendHistoryEntry(for: destinationCard,
                                           from: originalStatus,
                                           to: newStatus)
                } catch {
                    // History logging is non-fatal; move already succeeded.
                }
            }
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

    private func stagingURL(for directory: URL, filename: String) -> URL {
        directory.appendingPathComponent(".\(filename).staging-\(UUID().uuidString)")
    }

    private func appendHistoryEntry(for card: Card,
                                    from sourceStatus: CardStatus,
                                    to destinationStatus: CardStatus) throws {
        // Skip history logging when the destination file is not writable (e.g., read-only attrs).
        guard fileManager.isWritableFile(atPath: card.filePath.path) else { return }

        let entry = Self.historyEntry(from: sourceStatus,
                                      to: destinationStatus,
                                      dateProvider: dateProvider)

        let writer = CardMarkdownWriter(parser: CardFileParser(), fileManager: fileManager)
        let snapshot = try writer.loadSnapshot(for: card)
        var draft = CardDetailFormDraft.from(card: snapshot.card, today: dateProvider())
        draft.newHistoryEntry = entry
        _ = try writer.saveFormDraft(draft, appendHistory: true, snapshot: snapshot)
    }

    private static func historyEntry(from source: CardStatus,
                                     to destination: CardStatus,
                                     dateProvider: @escaping () -> Date) -> String {
        let today = DateFormatters.dateString(from: dateProvider())
        return "\(today) - Moved from \(source.displayName) to \(destination.displayName)."
    }
}
