import Foundation
import os.log

/// Represents an active agent run being tracked by the supervisor.
struct ActiveRunSnapshot: Codable, Equatable, Sendable {
    let runID: UUID
    let cardPath: String
    let flow: String
    let pipeline: String?
    let startedAt: Date
    let workerPID: Int32?

    nonisolated init(runID: UUID, cardPath: String, flow: String, pipeline: String?, startedAt: Date, workerPID: Int32?) {
        self.runID = runID
        self.cardPath = cardPath
        self.flow = flow
        self.pipeline = pipeline
        self.startedAt = startedAt
        self.workerPID = workerPID
    }
}

/// Represents a card queued for agent processing.
struct QueuedCardSnapshot: Codable, Equatable, Sendable {
    let cardPath: String
    let flow: String
    let pipeline: String?
    let enqueuedAt: Date
    let attempts: Int

    nonisolated init(cardPath: String, flow: String, pipeline: String?, enqueuedAt: Date, attempts: Int) {
        self.cardPath = cardPath
        self.flow = flow
        self.pipeline = pipeline
        self.enqueuedAt = enqueuedAt
        self.attempts = attempts
    }
}

/// Complete supervisor state that persists across app restarts.
struct SupervisorState: Codable, Equatable, Sendable {
    var activeRuns: [UUID: ActiveRunSnapshot]
    var queuedCards: [QueuedCardSnapshot]
    var failureCounts: [String: Int]
    var lastUpdated: Date

    nonisolated init(activeRuns: [UUID: ActiveRunSnapshot] = [:],
                     queuedCards: [QueuedCardSnapshot] = [],
                     failureCounts: [String: Int] = [:],
                     lastUpdated: Date = Date()) {
        self.activeRuns = activeRuns
        self.queuedCards = queuedCards
        self.failureCounts = failureCounts
        self.lastUpdated = lastUpdated
    }

    nonisolated static var empty: SupervisorState { SupervisorState() }
}

/// Persists supervisor state to disk so runs can survive app restarts.
@MainActor
final class SupervisorStateStore {
    private let stateURL: URL
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "dev.agency.app", category: "SupervisorStateStore")

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let baseDirectory = directory ?? Self.defaultDirectory
        self.stateURL = baseDirectory.appendingPathComponent("supervisor-state.json")
        self.fileManager = fileManager
    }

    private static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Agency", isDirectory: true)
    }

    // MARK: - Public API

    /// Saves the supervisor state to disk.
    func save(_ state: SupervisorState) throws {
        var stateToSave = state
        stateToSave.lastUpdated = Date()

        let directory = stateURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(stateToSave)
        try data.write(to: stateURL, options: .atomic)

        logger.debug("Saved supervisor state with \(state.activeRuns.count) active runs, \(state.queuedCards.count) queued cards")
    }

    /// Loads the supervisor state from disk, returning empty state if none exists.
    func load() throws -> SupervisorState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            logger.debug("No existing supervisor state found; returning empty state")
            return .empty
        }

        let data = try Data(contentsOf: stateURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(SupervisorState.self, from: data)
        logger.debug("Loaded supervisor state from \(state.lastUpdated)")
        return state
    }

    /// Clears all persisted state.
    func clear() {
        try? fileManager.removeItem(at: stateURL)
        logger.info("Cleared supervisor state")
    }

    // MARK: - Convenience Mutations

    /// Adds an active run to the state.
    func addActiveRun(_ run: ActiveRunSnapshot) throws {
        var state = try load()
        state.activeRuns[run.runID] = run
        try save(state)
    }

    /// Removes an active run from the state.
    func removeActiveRun(_ runID: UUID) throws {
        var state = try load()
        state.activeRuns.removeValue(forKey: runID)
        try save(state)
    }

    /// Adds a card to the queue.
    func enqueueCard(_ card: QueuedCardSnapshot) throws {
        var state = try load()
        // Remove any existing entry for this card path to avoid duplicates
        state.queuedCards.removeAll { $0.cardPath == card.cardPath }
        state.queuedCards.append(card)
        try save(state)
    }

    /// Removes a card from the queue.
    func dequeueCard(cardPath: String) throws {
        var state = try load()
        state.queuedCards.removeAll { $0.cardPath == cardPath }
        try save(state)
    }

    /// Updates the failure count for a card path.
    func updateFailureCount(for cardPath: String, count: Int) throws {
        var state = try load()
        if count > 0 {
            state.failureCounts[cardPath] = count
        } else {
            state.failureCounts.removeValue(forKey: cardPath)
        }
        try save(state)
    }

    /// Clears stale runs that are older than the specified timeout.
    func clearStaleRuns(timeout: TimeInterval, currentDate: Date = Date()) throws -> [UUID] {
        var state = try load()
        let cutoff = currentDate.addingTimeInterval(-timeout)

        var clearedIDs: [UUID] = []
        for (runID, run) in state.activeRuns {
            if run.startedAt < cutoff {
                clearedIDs.append(runID)
            }
        }

        for runID in clearedIDs {
            state.activeRuns.removeValue(forKey: runID)
        }

        if !clearedIDs.isEmpty {
            try save(state)
            logger.info("Cleared \(clearedIDs.count) stale runs older than \(timeout)s")
        }

        return clearedIDs
    }
}
