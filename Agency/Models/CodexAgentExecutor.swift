import Foundation

/// Executor that drives real Codex workers through the supervisor, streaming their log file into UI events.
struct CodexAgentExecutor: AgentExecutor {
    private let client: any SupervisorClienting
    private let streamer: WorkerLogStreamer
    private let fileManager: FileManager

    init(client: any SupervisorClienting = SupervisorClient(),
         streamer: WorkerLogStreamer = WorkerLogStreamer(),
         fileManager: FileManager = .default) {
        self.client = client
        self.streamer = streamer
        self.fileManager = fileManager
    }

    func run(request: CodexRunRequest,
             logURL: URL,
             outputDirectory: URL,
             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        let tracker = FinishTracker()

        do {
            try await performRun(request: request,
                                 logURL: logURL,
                                 outputDirectory: outputDirectory,
                                 tracker: tracker,
                                 emit: emit)
        } catch is CancellationError {
            await emitCanceledIfNeeded(tracker: tracker, emit: emit)
        } catch {
            await emitFailure(error, tracker: tracker, emit: emit)
        }

        await cleanup(runID: request.runID, outputDirectory: outputDirectory)
    }

    // MARK: - Internals

    private func performRun(request: CodexRunRequest,
                            logURL: URL,
                            outputDirectory: URL,
                            tracker: FinishTracker,
                            emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async throws {
        try prepareLogDirectory(for: logURL)
        try await launchWorker(request: request)

        for try await event in streamer.stream(logURL: logURL) {
            try Task.checkCancellation()
            await emit(event)
            if case .finished = event {
                await tracker.markEmitted()
                break
            }
        }

        if await tracker.needsFinishEmission(), let finished = try lastFinishedEvent(in: logURL) {
            await tracker.markEmitted()
            await emit(finished)
        }
    }

    private func prepareLogDirectory(for logURL: URL) throws {
        let directory = logURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)
    }

    private func launchWorker(request: CodexRunRequest) async throws {
        switch await client.launch(request: request) {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    private func lastFinishedEvent(in logURL: URL) throws -> WorkerLogEvent? {
        let events = try streamer.readAllEvents(logURL: logURL)
        return events.last { event in
            if case .finished = event { return true }
            return false
        }
    }

    private func emitCanceledIfNeeded(tracker: FinishTracker,
                                      emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        guard await tracker.needsFinishEmission() else { return }
        await tracker.markEmitted()
        let canceled = WorkerRunResult(status: .canceled,
                                       exitCode: 1,
                                       duration: 0,
                                       bytesRead: 0,
                                       bytesWritten: 0,
                                       summary: "Canceled")
        await emit(.finished(canceled))
    }

    private func emitFailure(_ error: Error,
                             tracker: FinishTracker,
                             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        guard await tracker.needsFinishEmission() else { return }
        await tracker.markEmitted()
        let failed = WorkerRunResult(status: .failed,
                                      exitCode: 1,
                                      duration: 0,
                                      bytesRead: 0,
                                      bytesWritten: 0,
                                      summary: error.localizedDescription)
        await emit(.finished(failed))
    }

    private func cleanup(runID: UUID, outputDirectory: URL) async {
        await client.cancel(runID: runID)
        try? fileManager.removeItem(at: outputDirectory)
    }
}

private actor FinishTracker {
    private var emitted = false

    func markEmitted() {
        emitted = true
    }

    func needsFinishEmission() -> Bool {
        !emitted
    }
}
