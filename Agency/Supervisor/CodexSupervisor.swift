import Foundation
import os.log
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Singleton that exposes the supervisor-facing API to the SwiftUI app.
/// It wraps SMAppService registration, worker launch lifecycle, cancellation, and reconnects.
@MainActor
final class CodexSupervisor {
    static let shared = CodexSupervisor()

    private let logger = Logger(subsystem: "dev.agency.app", category: "CodexSupervisor")
    private let launcher: WorkerLauncher
    private let backoffPolicy: WorkerBackoffPolicy
    private var jobs: [UUID: WorkerJob] = [:]

    init(launcher: WorkerLauncher = WorkerLauncher(),
         backoffPolicy: WorkerBackoffPolicy = WorkerBackoffPolicy()) {
        self.launcher = launcher
        self.backoffPolicy = backoffPolicy
    }

    /// Registers both the supervisor and worker SMAppService plists so that launchd can start them on demand.
    func registerIfNeeded() throws {
#if canImport(ServiceManagement)
        try launcher.registerSupervisorPlistIfNeeded()
        try launcher.registerWorkerPlistIfNeeded()
#else
        logger.warning("ServiceManagement unavailable; registration skipped")
#endif
    }

    /// Launch a single-use worker for the provided request.
    /// Returns an endpoint the app can use to attach to the worker's XPC stream.
    func launchWorker(request: CodexRunRequest) async throws -> WorkerEndpoint {
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
}

/// Internal bookkeeping for a launched worker.
struct WorkerJob: JobHandle {
    let runID: UUID
    let endpoint: WorkerEndpoint
    let process: Process?
    let requestedAt: Date
}
