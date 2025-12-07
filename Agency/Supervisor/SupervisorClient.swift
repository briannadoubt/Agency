import Foundation
import Observation

/// Protocol abstraction so executors and tests can swap in stub clients.
protocol SupervisorClienting {
    @MainActor
    func launch(request: WorkerRunRequest) async -> Result<WorkerEndpoint, Error>
    func cancel(runID: UUID) async
    func reconnect(runID: UUID) async -> WorkerEndpoint?
    func backoffDelay(after failures: Int) async -> Duration
}

/// Thin, testable wrapper the UI can hold onto without knowing about the actor type directly.
@Observable
final class SupervisorClient: SupervisorClienting {
    private let supervisor: AgentSupervisor

    init(supervisor: AgentSupervisor = .shared) {
        self.supervisor = supervisor
    }

    @MainActor
    func launch(request: WorkerRunRequest) async -> Result<WorkerEndpoint, Error> {
        do {
            let endpoint = try await supervisor.launchWorker(request: request)
            return .success(endpoint)
        } catch {
            return .failure(error)
        }
    }

    func cancel(runID: UUID) async {
        await supervisor.cancelWorker(id: runID)
    }

    func reconnect(runID: UUID) async -> WorkerEndpoint? {
        supervisor.reconnect(to: runID)
    }

    func backoffDelay(after failures: Int) async -> Duration {
        supervisor.backoffDelay(afterFailures: failures)
    }
}
