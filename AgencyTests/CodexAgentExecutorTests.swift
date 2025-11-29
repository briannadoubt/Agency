import XCTest
@testable import Agency

@MainActor
final class CodexAgentExecutorTests: XCTestCase {
    private var recordedEvents: [WorkerLogEvent] = []

    func testStreamsLogsProgressAndFinish() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = temp.appendingPathComponent("worker.log")
        let request = makeRequest(logDirectory: temp)

        let client = StubSupervisorClient { req in
            XCTAssertEqual(req.runID, request.runID)
            Task {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                    try self.appendLog("hello", to: logURL)
                    try self.appendProgress(0.25, message: "quarter", to: logURL)
                    let result = WorkerRunResult(status: .succeeded,
                                                 exitCode: 0,
                                                 duration: 0.4,
                                                 bytesRead: 128,
                                                 bytesWritten: 64,
                                                 summary: "done")
                    try self.appendFinished(result, to: logURL)
                } catch {
                    XCTFail("Failed to append events: \(error)")
                }
            }
            return .success(WorkerEndpoint(runID: req.runID, bootstrapName: "test.endpoint"))
        }

        let executor = CodexAgentExecutor(client: client)
        recordedEvents = []

        await executor.run(request: request, logURL: logURL, outputDirectory: temp) { event in
            await MainActor.run {
                self.recordedEvents.append(event)
            }
        }

        XCTAssertTrue(recordedEvents.contains(where: { if case .log("hello") = $0 { return true } else { return false } }))
        XCTAssertTrue(recordedEvents.contains(where: { if case .progress(let value, _) = $0 { return value >= 0.25 } else { return false } }))
        guard case .finished(let result)? = recordedEvents.last else {
            XCTFail("Missing finished event")
            return
        }

        XCTAssertEqual(result.status, .succeeded)
        let canceled = client.canceledRunIDs
        XCTAssertEqual(canceled, [request.runID])
    }

    func testCancellationPropagatesAndEmitsCanceledResult() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = temp.appendingPathComponent("worker.log")
        let request = makeRequest(logDirectory: temp)

        let client = StubSupervisorClient { _ in
            // Keep appending progress so the stream stays alive until cancellation.
            Task {
                do {
                    try self.appendLog("starting", to: logURL)
                    while true {
                        try await Task.sleep(for: .milliseconds(50))
                        try self.appendProgress(0.1, message: "tick", to: logURL)
                    }
                } catch {
                    // Stream will terminate once the executor cancels; ignore errors from removal.
                }
            }
            return .success(WorkerEndpoint(runID: request.runID, bootstrapName: "test"))
        }

        let executor = CodexAgentExecutor(client: client)
        recordedEvents = []

        let task = Task {
            await executor.run(request: request, logURL: logURL, outputDirectory: temp) { event in
                await MainActor.run {
                    self.recordedEvents.append(event)
                }
            }
        }

        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        await task.value

        try await Task.sleep(for: .milliseconds(100))

        let canceledIDs = client.canceledRunIDs
        XCTAssertTrue(canceledIDs.contains(request.runID))
        XCTAssertFalse(recordedEvents.isEmpty, "Recorded events: \(recordedEvents)")
    }

    func testCrashWithoutFinishedEventEmitsFailure() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = temp.appendingPathComponent("worker.log")
        let request = makeRequest(logDirectory: temp)

        let streamer = StubStreamer(events: [.log("partial")])
        let client = StubSupervisorClient { _ in
            .success(WorkerEndpoint(runID: request.runID, bootstrapName: "test"))
        }

        let executor = CodexAgentExecutor(client: client, streamer: streamer)
        recordedEvents = []

        await executor.run(request: request, logURL: logURL, outputDirectory: temp) { event in
            await MainActor.run { self.recordedEvents.append(event) }
        }

        guard case .finished(let result)? = recordedEvents.last else {
            XCTFail("Expected finished event after crash fallback")
            return
        }

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(client.canceledRunIDs, [request.runID])
    }

    func testMissingLogEmitsFailureInsteadOfCrashing() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = temp.appendingPathComponent("worker.log")
        let request = makeRequest(logDirectory: temp)

        let streamer = StubStreamer(events: [], streamError: WorkerLogStreamError.fileMissing)
        let client = StubSupervisorClient { _ in
            .success(WorkerEndpoint(runID: request.runID, bootstrapName: "test"))
        }

        let executor = CodexAgentExecutor(client: client, streamer: streamer)
        recordedEvents = []

        await executor.run(request: request, logURL: logURL, outputDirectory: temp) { event in
            await MainActor.run { self.recordedEvents.append(event) }
        }

        guard case .finished(let result)? = recordedEvents.last else {
            XCTFail("Expected failure result when logs are missing")
            return
        }

        XCTAssertEqual(result.status, .failed)
        XCTAssertFalse(result.summary.isEmpty)
    }

    func testCleanupRemovesOutputsAfterSuccess() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = temp.appendingPathComponent("worker.log")
        let outputDirectory = temp.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let request = makeRequest(logDirectory: temp)

        let streamer = StubStreamer(events: [
            .finished(WorkerRunResult(status: .succeeded,
                                      exitCode: 0,
                                      duration: 0.1,
                                      bytesRead: 0,
                                      bytesWritten: 0,
                                      summary: "ok"))
        ])

        let client = StubSupervisorClient { _ in
            .success(WorkerEndpoint(runID: request.runID, bootstrapName: "test"))
        }

        let executor = CodexAgentExecutor(client: client, streamer: streamer)

        await executor.run(request: request,
                           logURL: logURL,
                           outputDirectory: outputDirectory) { _ in }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
        XCTAssertEqual(client.canceledRunIDs, [request.runID])
    }

    // MARK: - Helpers

    private func makeRequest(logDirectory: URL) -> CodexRunRequest {
        CodexRunRequest(runID: UUID(),
                        flow: "implement",
                        cardRelativePath: "phase/card.md",
                        projectBookmark: Data(),
                        logDirectory: logDirectory,
                        outputDirectory: logDirectory.appendingPathComponent("tmp"),
                        allowNetwork: false,
                        cliArgs: [])
    }
}

// MARK: - Test Doubles & Log Helpers

@MainActor
final class StubSupervisorClient: SupervisorClienting {
    let launchHandler: @MainActor (CodexRunRequest) -> Result<WorkerEndpoint, Error>
    private(set) var canceledRunIDs: [UUID] = []

    init(launchHandler: @escaping @MainActor (CodexRunRequest) -> Result<WorkerEndpoint, Error>) {
        self.launchHandler = launchHandler
    }

    func launch(request: CodexRunRequest) async -> Result<WorkerEndpoint, Error> {
        launchHandler(request)
    }

    func cancel(runID: UUID) async {
        canceledRunIDs.append(runID)
    }

    func reconnect(runID: UUID) async -> WorkerEndpoint? { nil }

    func backoffDelay(after failures: Int) async -> Duration { .zero }
}

struct StubStreamer: WorkerLogStreaming {
    let events: [WorkerLogEvent]
    var streamError: Error?

    func stream(logURL: URL) -> AsyncThrowingStream<WorkerLogEvent, Error> {
        AsyncThrowingStream { continuation in
            if let streamError {
                continuation.finish(throwing: streamError)
                return
            }

            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func readAllEvents(logURL: URL) throws -> [WorkerLogEvent] {
        events
    }
}

// MARK: - Helpers

extension CodexAgentExecutorTests {
    private func appendLog(_ message: String, to url: URL) throws {
        try appendLine(Data(message.utf8), to: url)
    }

    private func appendProgress(_ percent: Double, message: String, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "event": "progress",
            "percent": percent,
            "message": message
        ])
        try appendLine(data, to: url)
    }

    private func appendFinished(_ result: WorkerRunResult, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "event": "workerFinished",
            "status": result.status.rawValue,
            "summary": result.summary,
            "durationMs": Int(result.duration * 1000),
            "exitCode": Int(result.exitCode),
            "bytesRead": result.bytesRead,
            "bytesWritten": result.bytesWritten
        ])
        try appendLine(data, to: url)
    }

    private func appendLine(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(data)
        handle.write(Data([0x0a]))
        try handle.close()
    }

}
