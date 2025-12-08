import Foundation
import os.log

/// Status of the supervisor coordinator.
enum SupervisorStatus: Equatable, Sendable {
    case stopped
    case starting
    case running
    case paused

    var isActive: Bool {
        self == .running
    }
}

/// Summary of current supervisor state for UI display.
struct SupervisorStatusSnapshot: Equatable, Sendable {
    let status: SupervisorStatus
    let activeRunCount: Int
    let queuedCardCount: Int
    let projectRoot: URL?
    let lastUpdated: Date
}

/// Coordinates agent runs across the project, managing backlog watching,
/// flow pipelines, and scheduling.
@MainActor @Observable
final class SupervisorCoordinator {
    private let logger = Logger(subsystem: "dev.agency.app", category: "SupervisorCoordinator")

    // Dependencies
    private let scheduler: AgentScheduler
    private let stateStore: SupervisorStateStore
    private let pipelineOrchestrator: FlowPipelineOrchestrator
    private let backlogWatcher: BacklogWatcher
    private let flowCoordinator: AgentFlowCoordinator
    private let dateProvider: @Sendable () -> Date

    // State
    private(set) var status: SupervisorStatus = .stopped
    private(set) var projectRoot: URL?
    private var watchTask: Task<Void, Never>?
    private var backgroundActivityScheduler: NSBackgroundActivityScheduler?
    private var activeRuns: [UUID: ActiveRunSnapshot] = [:]
    private var pendingRetries: [String: Task<Void, Never>] = [:]

    init(scheduler: AgentScheduler,
         stateStore: SupervisorStateStore = SupervisorStateStore(),
         pipelineOrchestrator: FlowPipelineOrchestrator = FlowPipelineOrchestrator(),
         backlogWatcher: BacklogWatcher = BacklogWatcher(),
         flowCoordinator: AgentFlowCoordinator,
         dateProvider: @escaping @Sendable () -> Date = Date.init) {
        self.scheduler = scheduler
        self.stateStore = stateStore
        self.pipelineOrchestrator = pipelineOrchestrator
        self.backlogWatcher = backlogWatcher
        self.flowCoordinator = flowCoordinator
        self.dateProvider = dateProvider
    }

    // MARK: - Public API

    /// Starts the supervisor coordinator for the given project.
    func start(projectRoot: URL) async {
        guard status == .stopped else {
            logger.warning("Supervisor already running or starting")
            return
        }

        status = .starting
        self.projectRoot = projectRoot
        logger.info("Starting supervisor for \(projectRoot.path)")

        // Restore state from disk
        restoreState()

        // Start background activity scheduler for persistent operation
        setupBackgroundActivity()

        // Start watching backlog directories
        watchTask = Task { [weak self] in
            guard let self else { return }
            let events = self.backlogWatcher.start(projectRoot: projectRoot)
            for await event in events {
                await self.handleBacklogEvent(event)
            }
        }

        status = .running
        logger.info("Supervisor started")
    }

    /// Stops the supervisor coordinator.
    func stop() async {
        guard status != .stopped else { return }

        logger.info("Stopping supervisor")
        status = .stopped

        // Cancel pending retries
        for task in pendingRetries.values {
            task.cancel()
        }
        pendingRetries.removeAll()

        // Stop watching
        watchTask?.cancel()
        watchTask = nil
        backlogWatcher.stop()

        // Stop background activity
        backgroundActivityScheduler?.invalidate()
        backgroundActivityScheduler = nil

        // Persist current state
        persistState()

        projectRoot = nil
        logger.info("Supervisor stopped")
    }

    /// Pauses the supervisor (stops processing new cards but keeps state).
    func pause() {
        guard status == .running else { return }
        status = .paused
        logger.info("Supervisor paused")
    }

    /// Resumes the supervisor from paused state.
    func resume() async {
        guard status == .paused else { return }
        status = .running
        logger.info("Supervisor resumed")

        // Trigger a rescan to pick up any cards added while paused
        backlogWatcher.rescan()
    }

    /// Manually enqueues a card for processing with a specific pipeline.
    func enqueueCard(_ card: Card, flow: AgentFlow? = nil, pipeline: FlowPipeline? = nil) async throws {
        guard let projectRoot else {
            throw SupervisorCoordinatorError.notStarted
        }

        let selectedPipeline = pipeline ?? FlowPipelineOrchestrator.suggestPipeline(for: card)
        let startingFlow = flow ?? pipelineOrchestrator.startPipeline(
            cardPath: card.filePath.path,
            pipeline: selectedPipeline
        )

        let result = await scheduler.enqueue(
            cardPath: card.filePath.path,
            flow: startingFlow,
            isParallelizable: card.frontmatter.parallelizable ?? false
        )

        switch result {
        case .enqueued(let runID, _, _):
            logger.info("Enqueued card \(card.code) for \(startingFlow.rawValue) flow (runID: \(runID))")

        case .alreadyRunning(let existingRunID):
            logger.warning("Card \(card.code) already running (runID: \(existingRunID))")
            throw SupervisorCoordinatorError.cardAlreadyRunning(existingRunID)

        case .deferred(let backpressure):
            logger.warning("Card \(card.code) deferred due to backpressure (depth: \(backpressure.depth)/\(backpressure.limit))")
            throw SupervisorCoordinatorError.backpressure(depth: backpressure.depth, limit: backpressure.limit)
        }
    }

    /// Cancels an active run.
    func cancelRun(_ runID: UUID) async {
        await scheduler.finish(runID: runID, outcome: .canceled)
        activeRuns.removeValue(forKey: runID)
        logger.info("Canceled run \(runID)")
    }

    /// Returns the current status snapshot.
    func getStatusSnapshot() -> SupervisorStatusSnapshot {
        let schedulerSnapshot = scheduler.snapshot()
        return SupervisorStatusSnapshot(
            status: status,
            activeRunCount: schedulerSnapshot.running,
            queuedCardCount: schedulerSnapshot.queued,
            projectRoot: projectRoot,
            lastUpdated: dateProvider()
        )
    }

    // MARK: - Event Handling

    private func handleBacklogEvent(_ event: BacklogEvent) async {
        guard status == .running else { return }

        switch event {
        case .cardAdded(let card):
            await handleNewCard(card)

        case .cardModified(let card):
            await handleModifiedCard(card)

        case .cardRemoved(let path):
            logger.debug("Card removed: \(path)")
            // Cancel any pending retries for this card
            pendingRetries[path]?.cancel()
            pendingRetries.removeValue(forKey: path)
        }
    }

    private func handleNewCard(_ card: Card) async {
        guard BacklogWatcher.isEligibleForProcessing(card) else {
            logger.debug("Card \(card.code) not eligible for automatic processing")
            return
        }

        do {
            try await enqueueCard(card)
        } catch {
            logger.warning("Failed to enqueue new card \(card.code): \(error.localizedDescription)")
        }
    }

    private func handleModifiedCard(_ card: Card) async {
        // Check if card became eligible for processing
        guard BacklogWatcher.isEligibleForProcessing(card) else {
            return
        }

        // Check if already processing
        if flowCoordinator.isLocked(card) {
            return
        }

        do {
            try await enqueueCard(card)
        } catch {
            logger.debug("Modified card \(card.code) not enqueued: \(error.localizedDescription)")
        }
    }

    // MARK: - Flow Completion Handling

    /// Called when a flow completes to determine next steps.
    func onFlowCompleted(
        card: Card,
        runID: UUID,
        result: WorkerRunResult
    ) async {
        activeRuns.removeValue(forKey: runID)

        guard let execution = pipelineOrchestrator.execution(for: card.filePath.path),
              let currentFlow = execution.currentFlow else {
            logger.debug("No active pipeline for completed run \(runID)")
            return
        }

        let action = pipelineOrchestrator.onFlowCompleted(
            cardPath: card.filePath.path,
            runID: runID,
            flow: currentFlow,
            result: result
        )

        switch action {
        case .continueToNextFlow(let nextFlow):
            do {
                try await enqueueCard(card, flow: nextFlow)
            } catch {
                logger.error("Failed to enqueue next flow \(nextFlow.rawValue): \(error.localizedDescription)")
            }

        case .pipelineComplete:
            logger.info("Pipeline complete for \(card.code)")
            // Card will be moved to done by the flow coordinator

        case .retryWithBackoff(let delay):
            scheduleRetry(for: card, flow: currentFlow, after: delay)

        case .abort(let reason):
            logger.warning("Pipeline aborted for \(card.code): \(reason)")
        }

        persistState()
    }

    private func scheduleRetry(for card: Card, flow: AgentFlow, after delay: Duration) {
        let cardPath = card.filePath.path

        pendingRetries[cardPath]?.cancel()
        pendingRetries[cardPath] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                try await self?.enqueueCard(card, flow: flow)
            } catch {
                self?.logger.warning("Retry failed for \(card.code): \(error.localizedDescription)")
            }
            await MainActor.run {
                self?.pendingRetries.removeValue(forKey: cardPath)
            }
        }
    }

    // MARK: - State Persistence

    private func restoreState() {
        do {
            let state = try stateStore.load()

            // Clear stale runs (older than 10 minutes)
            let clearedIDs = try stateStore.clearStaleRuns(
                timeout: 600,
                currentDate: dateProvider()
            )

            if !clearedIDs.isEmpty {
                logger.info("Cleared \(clearedIDs.count) stale runs on startup")
            }

            // Restore active runs that are still valid
            for (runID, run) in state.activeRuns where !clearedIDs.contains(runID) {
                activeRuns[runID] = run
            }

            // Re-enqueue queued cards
            // (They will be filtered by the backlog watcher if no longer eligible)
            logger.debug("Restored \(state.queuedCards.count) queued cards from previous session")

        } catch {
            logger.warning("Failed to restore state: \(error.localizedDescription)")
        }
    }

    private func persistState() {
        do {
            let state = SupervisorState(
                activeRuns: activeRuns,
                queuedCards: [], // Queue is managed by scheduler
                failureCounts: [:],
                lastUpdated: dateProvider()
            )
            try stateStore.save(state)
        } catch {
            logger.warning("Failed to persist state: \(error.localizedDescription)")
        }
    }

    // MARK: - Background Activity

    private func setupBackgroundActivity() {
        let activity = NSBackgroundActivityScheduler(identifier: "dev.agency.supervisor")
        activity.repeats = true
        activity.interval = 60 // Check every minute
        activity.qualityOfService = .utility

        activity.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self, self.status == .running else {
                    completion(.finished)
                    return
                }

                // Perform periodic maintenance
                self.backlogWatcher.rescan()
                self.persistState()

                completion(.finished)
            }
        }

        backgroundActivityScheduler = activity
        logger.debug("Background activity scheduler configured")
    }
}

// MARK: - Errors

enum SupervisorCoordinatorError: LocalizedError, Equatable {
    case notStarted
    case cardAlreadyRunning(UUID)
    case backpressure(depth: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .notStarted:
            return "Supervisor coordinator has not been started."
        case .cardAlreadyRunning(let runID):
            return "Card is already being processed (runID: \(runID))."
        case .backpressure(let depth, let limit):
            return "Queue is full (\(depth)/\(limit)). Try again later."
        }
    }
}
