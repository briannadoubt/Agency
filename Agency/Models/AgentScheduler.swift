import Foundation

/// Supported agent flows for Codex runs.
enum AgentFlow: String, CaseIterable, Codable, Equatable, Sendable {
    case implement
    case review
    case research
}

/// Retry/backoff configuration for failed runs.
struct AgentRetryPolicy: Equatable, Sendable {
    let baseDelay: Duration
    let multiplier: Double
    let jitter: Double
    let maxDelay: Duration
    let maxAttempts: Int

    static let standard = AgentRetryPolicy(baseDelay: .milliseconds(30_000),
                                           multiplier: 2,
                                           jitter: 0.1,
                                           maxDelay: .milliseconds(300_000),
                                           maxAttempts: 5)

    func delay(forAttempt attempt: Int,
               random: @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> Duration {
        guard attempt > 0 else { return .zero }

        let baseSeconds = seconds(from: baseDelay)
        let scaled = baseSeconds * pow(multiplier, Double(attempt - 1))
        let jitterSpan = scaled * jitter
        let delta = random(-jitterSpan...jitterSpan)
        let clampedSeconds = min(scaled + delta, seconds(from: maxDelay))

        let milliseconds = Int((clampedSeconds * 1_000).rounded())
        return .milliseconds(milliseconds)
    }

    private func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
    }
}

/// Scheduler limits and policy values sourced from configuration.
struct AgentSchedulerConfig: Equatable, Sendable {
    var maxConcurrent: Int
    var perFlow: [AgentFlow: Int]
    var softLimit: Int
    var hardLimit: Int
    var retryPolicy: AgentRetryPolicy
    var staleLockTimeout: Duration

    init(maxConcurrent: Int = 1,
         perFlow: [AgentFlow: Int]? = nil,
         softLimit: Int? = nil,
         hardLimit: Int? = nil,
         retryPolicy: AgentRetryPolicy = .standard,
         staleLockTimeout: Duration = .milliseconds(600_000)) {
        let boundedMax = max(0, maxConcurrent)
        self.maxConcurrent = boundedMax

        let defaultPerFlow = Dictionary(uniqueKeysWithValues: AgentFlow.allCases.map { ($0, 1) })
        var merged = defaultPerFlow
        if let perFlow {
            for (flow, value) in perFlow {
                merged[flow] = max(0, value)
            }
        }
        self.perFlow = merged

        let computedSoft = max(boundedMax * 4, 8)
        let resolvedSoft = softLimit.map { max(0, $0) } ?? computedSoft
        let resolvedHard = hardLimit.map { max(resolvedSoft, $0) } ?? resolvedSoft * 2

        self.softLimit = resolvedSoft
        self.hardLimit = resolvedHard
        self.retryPolicy = retryPolicy
        self.staleLockTimeout = staleLockTimeout
    }

    func perFlowLimit(for flow: AgentFlow) -> Int {
        perFlow[flow] ?? maxConcurrent
    }
}

/// Description of a single agent run request.
struct AgentRunRequest: Equatable, Sendable {
    let runID: UUID
    let cardPath: String
    let flow: AgentFlow
    let isParallelizable: Bool
    let enqueuedAt: Date

    init(runID: UUID = UUID(),
         cardPath: String,
         flow: AgentFlow,
         isParallelizable: Bool,
         enqueuedAt: Date = Date()) {
        self.runID = runID
        self.cardPath = cardPath
        self.flow = flow
        self.isParallelizable = isParallelizable
        self.enqueuedAt = enqueuedAt
    }
}

/// Completion status reported when a run finishes.
enum AgentRunCompletion: Equatable, Sendable {
    case succeeded
    case failed(reason: String?)
    case canceled
}

/// Backpressure metadata returned to callers when the queue is saturated.
struct AgentBackpressure: Equatable, Sendable {
    let limit: Int
    let depth: Int
}

/// Result of attempting to enqueue a run.
enum AgentEnqueueResult: Equatable, Sendable {
    case enqueued(runID: UUID, position: Int, backpressure: AgentBackpressure?)
    case alreadyRunning(existingRunID: UUID)
    case deferred(AgentBackpressure)
}

/// Event stream emitted by the scheduler for observability and tests.
enum AgentSchedulerEvent: Equatable, Sendable {
    case enqueued(UUID, AgentFlow)
    case started(UUID, AgentFlow)
    case finished(UUID, AgentFlow, AgentRunCompletion)
    case backpressureSoft(depth: Int, limit: Int)
    case deferred(AgentFlow, AgentBackpressure)
    case retryScheduled(UUID, Int, Duration)
}

/// Captures a snapshot of scheduler state for debugging and tests.
struct AgentSchedulerSnapshot: Equatable, Sendable {
    let queuedByFlow: [AgentFlow: Int]
    let runningByFlow: [AgentFlow: Int]
    let lockedCards: Set<String>
    let activePhaseLocks: Set<PhaseFlow>

    var queued: Int { queuedByFlow.values.reduce(0, +) }
    var running: Int { runningByFlow.values.reduce(0, +) }
}

/// Phase + flow pairing used for serialization of non-parallelizable cards.
struct PhaseFlow: Hashable, Sendable {
    let phaseIdentifier: String
    let flow: AgentFlow
}

private struct RunLock: Sendable {
    let runID: UUID
    let flow: AgentFlow
    let lockedAt: Date
}

/// Notifies the scheduler about lifecycle transitions so the UI can update card frontmatter.
struct AgentRunLifecycleHooks: Sendable {
    var onQueue: @Sendable (AgentRunRequest) async -> Void
    var onStart: @Sendable (AgentRunRequest) async -> Void
    var onFinish: @Sendable (AgentRunRequest, AgentRunCompletion) async -> Void

    static let noop = AgentRunLifecycleHooks(onQueue: { _ in },
                                             onStart: { _ in },
                                             onFinish: { _, _ in })
}

/// Abstracts the worker launcher (CodexSupervisor.xpc) so the scheduler can be tested in isolation.
protocol AgentWorkerLaunching: Sendable {
    func launch(run: AgentRunRequest) async throws
}

/// Coordinates global and per-flow concurrency, per-card locks, and queue/backoff rules for Codex runs.
@MainActor
final class AgentScheduler {
    private struct QueueEntry: Sendable {
        let request: AgentRunRequest
        let phase: String
        let requiresPhaseLock: Bool
        let attempts: Int
    }

    private struct ActiveRun: Sendable {
        let entry: QueueEntry
        let startedAt: Date
    }

    private let lifecycle: AgentRunLifecycleHooks
    private let launcher: AgentWorkerLaunching
    private var config: AgentSchedulerConfig
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    private let random: @Sendable (ClosedRange<Double>) -> Double

    private var readyQueues: [AgentFlow: [QueueEntry]]
    private var running: [UUID: ActiveRun]
    private var runningByFlow: [AgentFlow: Int]
    private var cardLocks: [String: RunLock]
    private var phaseLocks: [PhaseFlow: UUID]
    private var failureCounts: [String: Int]
    private var backoffTasks: [String: Task<Void, Never>]

    private var eventsLog: [AgentSchedulerEvent]
    private let eventStream: AsyncStream<AgentSchedulerEvent>
    private let eventContinuation: AsyncStream<AgentSchedulerEvent>.Continuation

    init(config: AgentSchedulerConfig,
         launcher: AgentWorkerLaunching,
         lifecycle: AgentRunLifecycleHooks,
         now: @Sendable @escaping () -> Date,
         sleep: @Sendable @escaping (Duration) async -> Void,
         random: @Sendable @escaping (ClosedRange<Double>) -> Double) {
        self.config = config
        self.launcher = launcher
        self.lifecycle = lifecycle
        self.now = now
        self.sleep = sleep
        self.random = random

        self.readyQueues = [:]
        self.running = [:]
        self.runningByFlow = [:]
        self.cardLocks = [:]
        self.phaseLocks = [:]
        self.failureCounts = [:]
        self.backoffTasks = [:]
        self.eventsLog = []

        var continuation: AsyncStream<AgentSchedulerEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: Public API

    func enqueue(cardPath: String,
                 flow: AgentFlow,
                 isParallelizable: Bool) async -> AgentEnqueueResult {
        if let existing = cardLocks[cardPath] {
            return .alreadyRunning(existingRunID: existing.runID)
        }

        let depthBefore = totalQueued
        if depthBefore >= config.hardLimit {
            let backpressure = AgentBackpressure(limit: config.hardLimit, depth: depthBefore)
            record(.deferred(flow, backpressure))
            return .deferred(backpressure)
        }

        let request = AgentRunRequest(cardPath: cardPath,
                                       flow: flow,
                                       isParallelizable: isParallelizable,
                                       enqueuedAt: now())
        let phase = phaseIdentifier(from: cardPath)
        let entry = QueueEntry(request: request,
                               phase: phase,
                               requiresPhaseLock: !isParallelizable,
                               attempts: 0)

        readyQueues[flow, default: []].append(entry)
        cardLocks[cardPath] = RunLock(runID: request.runID, flow: flow, lockedAt: now())
        failureCounts[cardPath] = 0

        let depthAfter = totalQueued
        var notice: AgentBackpressure? = nil
        if depthAfter >= config.softLimit {
            notice = AgentBackpressure(limit: config.softLimit, depth: depthAfter)
            record(.backpressureSoft(depth: depthAfter, limit: config.softLimit))
        }

        record(.enqueued(request.runID, flow))
        await lifecycle.onQueue(request)
        await drainQueues()

        return .enqueued(runID: request.runID, position: depthAfter, backpressure: notice)
    }

    func finish(runID: UUID, outcome: AgentRunCompletion) async {
        guard let active = running.removeValue(forKey: runID) else { return }

        let flow = active.entry.request.flow
        runningByFlow[flow] = max(0, runningByFlow[flow, default: 0] - 1)
        phaseLocks[PhaseFlow(phaseIdentifier: active.entry.phase, flow: active.entry.request.flow)] = nil

        switch outcome {
        case .succeeded, .canceled:
            cardLocks[active.entry.request.cardPath] = nil
            backoffTasks[active.entry.request.cardPath]?.cancel()
            backoffTasks[active.entry.request.cardPath] = nil
            failureCounts[active.entry.request.cardPath] = 0
        case .failed(let reason):
            await handleFailure(for: active.entry, reason: reason)
        }

        record(.finished(runID, active.entry.request.flow, outcome))
        await lifecycle.onFinish(active.entry.request, outcome)
        await drainQueues()
    }

    func snapshot() -> AgentSchedulerSnapshot {
        AgentSchedulerSnapshot(queuedByFlow: readyQueues.mapValues { $0.count },
                               runningByFlow: runningByFlow,
                               lockedCards: Set(cardLocks.keys),
                               activePhaseLocks: Set(phaseLocks.keys))
    }

    func events() -> AsyncStream<AgentSchedulerEvent> { eventStream }

    func recordedEvents() -> [AgentSchedulerEvent] { eventsLog }

    func updateConfiguration(_ config: AgentSchedulerConfig) async {
        self.config = config
        await drainQueues()
    }

    /// Clears stale locks that survived a crash/relaunch cycle.
    func clearStaleLocks(currentDate: Date) {
        let cutoff = currentDate.addingTimeInterval(-seconds(from: config.staleLockTimeout))
        cardLocks = cardLocks.filter { _, lock in
            if let active = running[lock.runID] {
                return active.startedAt > cutoff
            }
            return lock.lockedAt > cutoff
        }
    }

    // MARK: Private helpers

    private func drainQueues() async {
        guard totalRunning < config.maxConcurrent else { return }

        while totalRunning < config.maxConcurrent {
            guard let (flow, index, entry) = nextDispatchableEntry() else { break }

            readyQueues[flow]?.remove(at: index)

            let phaseLock = PhaseFlow(phaseIdentifier: entry.phase, flow: entry.request.flow)
            if entry.requiresPhaseLock {
                phaseLocks[phaseLock] = entry.request.runID
            }

            await lifecycle.onStart(entry.request)

            do {
                try await launcher.launch(run: entry.request)
                running[entry.request.runID] = ActiveRun(entry: entry, startedAt: now())
                runningByFlow[flow, default: 0] += 1
                record(.started(entry.request.runID, flow))
            } catch {
                // Launch failed synchronously; treat as a failure attempt.
                await handleFailure(for: entry, reason: error.localizedDescription)
                phaseLocks[phaseLock] = nil
                record(.finished(entry.request.runID, flow, .failed(reason: error.localizedDescription)))
            }
        }
    }

    private func nextDispatchableEntry() -> (AgentFlow, Int, QueueEntry)? {
        var candidate: (AgentFlow, Int, QueueEntry)?

        for (flow, queue) in readyQueues {
            guard runningByFlow[flow, default: 0] < config.perFlowLimit(for: flow) else { continue }

            for (index, entry) in queue.enumerated() {
                if entry.requiresPhaseLock,
                   let owner = phaseLocks[PhaseFlow(phaseIdentifier: entry.phase, flow: flow)],
                   owner != entry.request.runID {
                    continue
                }

                if let existing = candidate {
                    if entry.request.enqueuedAt < existing.2.request.enqueuedAt {
                        candidate = (flow, index, entry)
                    }
                } else {
                    candidate = (flow, index, entry)
                }
                break
            }
        }

        return candidate
    }

    private func handleFailure(for entry: QueueEntry, reason: String?) async {
        let attempts = entry.attempts + 1
        failureCounts[entry.request.cardPath] = attempts

        guard attempts < config.retryPolicy.maxAttempts else {
            cardLocks[entry.request.cardPath] = nil
            backoffTasks[entry.request.cardPath]?.cancel()
            backoffTasks[entry.request.cardPath] = nil
            return
        }

        let delay = config.retryPolicy.delay(forAttempt: attempts, random: random)
        backoffTasks[entry.request.cardPath]?.cancel()
        backoffTasks[entry.request.cardPath] = Task { [weak self] in
            guard let self else { return }
            await self.sleep(delay)
            await self.retry(entry: entry, attempts: attempts)
        }

        record(.retryScheduled(entry.request.runID, attempts, delay))
    }

    private func retry(entry: QueueEntry, attempts: Int) async {
        guard cardLocks[entry.request.cardPath]?.runID == entry.request.runID else { return }

        let retryEntry = QueueEntry(request: entry.request,
                                    phase: entry.phase,
                                    requiresPhaseLock: entry.requiresPhaseLock,
                                    attempts: attempts)
        readyQueues[entry.request.flow, default: []].append(retryEntry)
        await drainQueues()
    }

    private var totalQueued: Int {
        readyQueues.values.reduce(0) { $0 + $1.count }
    }

    private var totalRunning: Int { running.count }

    private func phaseIdentifier(from cardPath: String) -> String {
        let components = cardPath.split(separator: "/")
        if let phaseComponent = components.first(where: { $0.hasPrefix("phase-") }) {
            return String(phaseComponent)
        }
        return cardPath
    }

    private func record(_ event: AgentSchedulerEvent) {
        eventsLog.append(event)
        eventContinuation.yield(event)
    }

    private func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        let seconds = TimeInterval(components.seconds)
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000.0
        return seconds + attoseconds
    }
}
