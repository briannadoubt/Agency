import Foundation
import os.log

/// Events emitted by the backlog watcher when cards change.
enum BacklogEvent: Equatable, Sendable {
    case cardAdded(Card)
    case cardModified(Card)
    case cardRemoved(String)
}

/// Watches project backlog directories for new or modified cards using FSEvents.
@MainActor
final class BacklogWatcher {
    private let logger = Logger(subsystem: "dev.agency.app", category: "BacklogWatcher")
    private let debounceInterval: TimeInterval
    private let cardParser: CardFileParser

    private var projectRoot: URL?
    private var fileSystemObject: DispatchSourceFileSystemObject?
    private var continuation: AsyncStream<BacklogEvent>.Continuation?
    private var knownCards: [String: Date] = [:] // cardPath -> lastModified
    private var debounceTask: Task<Void, Never>?
    private var isRunning = false

    init(debounceInterval: TimeInterval = 0.15,
         cardParser: CardFileParser = CardFileParser()) {
        self.debounceInterval = debounceInterval
        self.cardParser = cardParser
    }

    // MARK: - Public API

    /// Starts watching the project backlog directories and returns a stream of events.
    func start(projectRoot: URL) -> AsyncStream<BacklogEvent> {
        self.projectRoot = projectRoot
        self.isRunning = true

        // Perform initial scan
        let initialCards = scanBacklogDirectories(projectRoot: projectRoot)
        for card in initialCards {
            knownCards[card.filePath.path] = modificationDate(for: card.filePath)
        }

        logger.info("Started watching \(projectRoot.path) with \(initialCards.count) existing backlog cards")

        return AsyncStream { [weak self] continuation in
            self?.continuation = continuation

            // Set up file system watching using DispatchSource
            self?.setupFileWatcher(for: projectRoot)

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stopInternal()
                }
            }
        }
    }

    /// Stops watching and cleans up resources.
    func stop() {
        stopInternal()
    }

    private func stopInternal() {
        isRunning = false
        fileSystemObject?.cancel()
        fileSystemObject = nil
        debounceTask?.cancel()
        debounceTask = nil
        continuation?.finish()
        continuation = nil
        projectRoot = nil
        knownCards.removeAll()
        logger.debug("Stopped backlog watcher")
    }

    /// Manually triggers a scan and emits events for any changes.
    func rescan() {
        guard let projectRoot, isRunning else { return }
        processChanges(projectRoot: projectRoot)
    }

    // MARK: - Private Helpers

    private func setupFileWatcher(for projectRoot: URL) {
        let projectPath = projectRoot.appendingPathComponent("project").path
        let fd = open(projectPath, O_EVTONLY)

        guard fd >= 0 else {
            logger.warning("Failed to open project directory for watching: \(projectPath)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleFileSystemEvent()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileSystemObject = source
    }

    private func handleFileSystemEvent() {
        guard isRunning else { return }

        // Debounce rapid file system events
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int((self?.debounceInterval ?? 0.15) * 1000)))
            guard !Task.isCancelled else { return }
            guard let self, let projectRoot = self.projectRoot, self.isRunning else { return }
            self.processChanges(projectRoot: projectRoot)
        }
    }

    private func processChanges(projectRoot: URL) {
        let currentCards = scanBacklogDirectories(projectRoot: projectRoot)
        var currentPaths = Set<String>()

        for card in currentCards {
            let path = card.filePath.path
            currentPaths.insert(path)

            let currentModDate = modificationDate(for: card.filePath)

            if let previousModDate = knownCards[path] {
                // Check if modified
                if let currentModDate, currentModDate > previousModDate {
                    knownCards[path] = currentModDate
                    continuation?.yield(.cardModified(card))
                    logger.debug("Card modified: \(path)")
                }
            } else {
                // New card
                knownCards[path] = currentModDate
                continuation?.yield(.cardAdded(card))
                logger.debug("Card added: \(path)")
            }
        }

        // Check for removed cards
        for path in knownCards.keys {
            if !currentPaths.contains(path) {
                knownCards.removeValue(forKey: path)
                continuation?.yield(.cardRemoved(path))
                logger.debug("Card removed: \(path)")
            }
        }
    }

    private func scanBacklogDirectories(projectRoot: URL) -> [Card] {
        let projectDir = projectRoot.appendingPathComponent("project")
        var cards: [Card] = []

        guard let phaseDirectories = try? FileManager.default.contentsOfDirectory(
            at: projectDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return cards
        }

        for phaseDir in phaseDirectories {
            guard phaseDir.lastPathComponent.hasPrefix("phase-") else { continue }

            let backlogDir = phaseDir.appendingPathComponent("backlog")
            guard FileManager.default.fileExists(atPath: backlogDir.path) else { continue }

            guard let cardFiles = try? FileManager.default.contentsOfDirectory(
                at: backlogDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for cardFile in cardFiles {
                guard cardFile.pathExtension == "md" else { continue }

                do {
                    let content = try String(contentsOf: cardFile, encoding: .utf8)
                    let card = try cardParser.parse(fileURL: cardFile, contents: content)
                    cards.append(card)
                } catch {
                    logger.warning("Failed to parse card at \(cardFile.path): \(error.localizedDescription)")
                }
            }
        }

        return cards
    }

    private func modificationDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

// MARK: - Card Filtering

extension BacklogWatcher {
    /// Filters cards that are eligible for automatic agent processing.
    /// Cards must have agent_flow set and agent_status of idle or nil.
    static func isEligibleForProcessing(_ card: Card) -> Bool {
        guard let agentFlow = card.frontmatter.agentFlow,
              !agentFlow.isEmpty else {
            return false
        }

        let status = card.frontmatter.agentStatus?.lowercased() ?? ""
        return status.isEmpty || status == "idle"
    }
}
