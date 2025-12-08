import Foundation
import os.log
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Singleton that exposes the supervisor-facing API to the SwiftUI app.
/// It wraps SMAppService registration, worker launch lifecycle, cancellation, and reconnects.
/// Also provides access to the SupervisorCoordinator for background agent orchestration.
@MainActor
final class AgentSupervisor {
    static let shared = AgentSupervisor()

    private let logger = Logger(subsystem: "dev.agency.app", category: "AgentSupervisor")
    private let launcher: any WorkerLaunching
    private let backoffPolicy: WorkerBackoffPolicy
    private let capabilityChecklist: CapabilityChecklist
    private var jobs: [UUID: WorkerJob] = [:]

    /// The background supervisor coordinator for automatic card processing.
    private(set) lazy var coordinator: SupervisorCoordinator = {
        // Create worker launcher adapter
        let workerLauncher = SchedulerWorkerLauncherAdapter(supervisor: self)

        // Create scheduler with minimal configuration
        let scheduler = AgentScheduler(
            config: AgentSchedulerConfig(maxConcurrent: 2),
            launcher: workerLauncher,
            lifecycle: .noop,
            now: { Date() },
            sleep: { try? await Task.sleep(for: $0) },
            random: { Double.random(in: $0) }
        )

        // Create flow coordinator
        let flowCoordinator = AgentFlowCoordinator(
            worker: WorkerClientAdapter(supervisor: self),
            writer: CardMarkdownWriter(),
            logLocator: AgentRunLogLocator(baseDirectory: FileManager.default.temporaryDirectory),
            backoffPolicy: backoffPolicy
        )

        return SupervisorCoordinator(
            scheduler: scheduler,
            flowCoordinator: flowCoordinator
        )
    }()

    /// Whether the background coordinator is currently running.
    var isCoordinatorRunning: Bool {
        coordinator.status.isActive
    }

    init(launcher: any WorkerLaunching = WorkerLauncher(),
         backoffPolicy: WorkerBackoffPolicy = WorkerBackoffPolicy(),
         capabilityChecklist: CapabilityChecklist = CapabilityChecklist()) {
        self.launcher = launcher
        self.backoffPolicy = backoffPolicy
        self.capabilityChecklist = capabilityChecklist
    }

    // MARK: - Coordinator Control

    /// Starts the background supervisor coordinator for a project.
    func startCoordinator(projectRoot: URL) async {
        await coordinator.start(projectRoot: projectRoot)
        logger.info("Started supervisor coordinator for \(projectRoot.path)")
    }

    /// Stops the background supervisor coordinator.
    func stopCoordinator() async {
        await coordinator.stop()
        logger.info("Stopped supervisor coordinator")
    }

    /// Pauses the background supervisor coordinator.
    func pauseCoordinator() {
        coordinator.pause()
        logger.info("Paused supervisor coordinator")
    }

    /// Resumes the background supervisor coordinator.
    func resumeCoordinator() async {
        await coordinator.resume()
        logger.info("Resumed supervisor coordinator")
    }

    /// Registers both the supervisor and worker SMAppService plists so that launchd can start them on demand.
    func registerIfNeeded() throws {
        try ensureCapabilities()
#if canImport(ServiceManagement)
        try launcher.registerSupervisorPlistIfNeeded()
        try launcher.registerWorkerPlistIfNeeded()
#else
        logger.warning("ServiceManagement unavailable; registration skipped")
#endif
    }

    /// Launch a single-use worker for the provided request.
    /// Returns an endpoint the app can use to attach to the worker's XPC stream.
    func launchWorker(request: WorkerRunRequest) async throws -> WorkerEndpoint {
        try registerIfNeeded()
        let endpoint = try await launcher.launch(request: request)
        let process = launcher.activeProcess(for: request.runID)
        jobs[request.runID] = WorkerJob(runID: request.runID,
                                        endpoint: endpoint,
                                        process: process,
                                        requestedAt: .now)
        logger.debug("launched worker for runID=\(request.runID)")
        return endpoint
    }

    /// Stops a running worker if present and removes bookkeeping.
    func cancelWorker(id: UUID) async {
        guard let job = jobs[id] else { return }
        await launcher.cancel(job: job)
        jobs[id] = nil
        logger.info("canceled worker runID=\(id)")
    }

    /// Returns a cached endpoint if the app reconnects after a relaunch.
    func reconnect(to id: UUID) -> WorkerEndpoint? {
        jobs[id]?.endpoint
    }

    /// Exposes the configured retry/backoff policy so the scheduler can mirror it.
    func backoffDelay(afterFailures failures: Int) -> Duration {
        backoffPolicy.delay(forFailureCount: failures)
    }

    // MARK: - Helpers

    private func ensureCapabilities() throws {
        let missing = capabilityChecklist.missingCapabilities().map(\.rawValue)
        guard missing.isEmpty else {
            throw AgentSupervisorError.capabilitiesMissing(missing)
        }
    }
}

/// Internal bookkeeping for a launched worker.
struct WorkerJob: JobHandle {
    let runID: UUID
    let endpoint: WorkerEndpoint
    let process: Process?
    let requestedAt: Date
}

// MARK: - Worker Client Adapter

/// Adapts AgentSupervisor to the AgentWorkerClient protocol for use by AgentFlowCoordinator.
struct WorkerClientAdapter: AgentWorkerClient {
    private let supervisor: AgentSupervisor

    init(supervisor: AgentSupervisor) {
        self.supervisor = supervisor
    }

    func launchWorker(request: AgentWorkerRequest) async throws -> AgentWorkerEndpoint {
        // Convert AgentWorkerRequest to WorkerRunRequest
        let workerRequest = WorkerRunRequest(
            runID: request.runID,
            flow: request.flow.rawValue,
            cardRelativePath: request.cardRelativePath,
            projectBookmark: request.projectBookmark,
            logDirectory: request.logDirectory,
            outputDirectory: request.logDirectory,
            allowNetwork: request.allowNetwork,
            cliArgs: request.cliArguments,
            backend: .claudeCode
        )

        let endpoint = try await supervisor.launchWorker(request: workerRequest)
        return AgentWorkerEndpoint(runID: endpoint.runID, logDirectory: request.logDirectory)
    }

    func cancelWorker(runID: UUID) async {
        await supervisor.cancelWorker(id: runID)
    }
}

// MARK: - Scheduler Worker Launcher Adapter

/// Adapts AgentSupervisor to the AgentWorkerLaunching protocol for use by AgentScheduler.
struct SchedulerWorkerLauncherAdapter: AgentWorkerLaunching, Sendable {
    private let supervisor: AgentSupervisor

    init(supervisor: AgentSupervisor) {
        self.supervisor = supervisor
    }

    func launch(run: SchedulerRunRequest) async throws {
        // The scheduler handles the actual launch through lifecycle hooks
        // This adapter just signals readiness
    }
}
