import Foundation
import Observation

/// Thin, testable wrapper the UI can hold onto without knowing about the actor type directly.
@Observable
final class SupervisorClient {
    private let supervisor: CodexSupervisor

    init(supervisor: CodexSupervisor = .shared) {
        self.supervisor = supervisor
    }

    @MainActor
    func launch(request: CodexRunRequest) async -> Result<WorkerEndpoint, Error> {
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
        await supervisor.reconnect(to: runID)
    }

    func backoffDelay(after failures: Int) async -> Duration {
        await supervisor.backoffDelay(afterFailures: failures)
    }
}

