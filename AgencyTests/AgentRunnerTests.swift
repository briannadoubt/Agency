import XCTest
@testable import Agency

final class AgentRunnerTests: XCTestCase {

    @MainActor
    func testRunCompletesAndUpdatesFrontmatter() async throws {
        let (card, tempRoot) = try makeCard()
        let runner = AgentRunner()

        let result = await runner.startRun(card: card, flow: .implement)
        guard case .success = result else {
            XCTFail("Run failed to start: \(String(describing: result))")
            return
        }

        let finished = await waitFor(runner.state(for: card)?.phase == .succeeded)
        XCTAssertTrue(finished, "Run did not finish in time")

        let contents = try String(contentsOf: card.filePath, encoding: .utf8)
        XCTAssertTrue(contents.contains("agent_status: succeeded"))

        try FileManager.default.removeItem(at: tempRoot)
    }

    @MainActor
    func testCancelSetsCanceledStatus() async throws {
        let (card, tempRoot) = try makeCard()
        let runner = AgentRunner()

        let result = await runner.startRun(card: card, flow: .implement)
        guard case .success(let state) = result else {
            XCTFail("Run failed to start")
            return
        }

        runner.cancel(runID: state.id)
        try await Task.sleep(for: .milliseconds(500))

        let phase = runner.state(for: card)?.phase
        XCTAssertTrue(phase == .canceled || phase == nil)

        try FileManager.default.removeItem(at: tempRoot)
    }

    @MainActor
    func testStreamingEmitsProgressAndLogs() async throws {
        let (card, tempRoot) = try makeCard()
        let runner = AgentRunner()

        let result = await runner.startRun(card: card, flow: .implement)
        guard case .success = result else {
            XCTFail("Run failed to start")
            return
        }

        let finished = await waitFor(runner.state(for: card)?.phase == .succeeded)
        XCTAssertTrue(finished, "Run did not stream to completion")

        let state = runner.state(for: card)
        XCTAssertNotNil(state?.result)
        XCTAssertEqual(state?.result?.status, .succeeded)
        XCTAssertGreaterThan(state?.logs.count ?? 0, 3)
        XCTAssertEqual(state?.progress ?? 0, 1.0, accuracy: 0.01)

        try FileManager.default.removeItem(at: tempRoot)
    }

    @MainActor
    func testCancelCleansUpPipelines() async throws {
        let (card, tempRoot) = try makeCard()
        let runner = AgentRunner()

        let result = await runner.startRun(card: card, flow: .implement)
        guard case .success(let state) = result else {
            XCTFail("Run failed to start")
            return
        }

        runner.cancel(runID: state.id)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(runner.activeRunIDs.isEmpty)

        try FileManager.default.removeItem(at: tempRoot)
    }

    @MainActor
    func testNonZeroExitMarksFailureAndRetainsCard() async throws {
        let (card, tempRoot) = try makeCard()
        let runner = AgentRunner(executors: [.simulated: FailingExecutor(exitCode: 2,
                                                                          summary: "non-zero exit")])

        let start = await runner.startRun(card: card, flow: .implement)
        guard case .success(let state) = start else {
            XCTFail("Run failed to start")
            try FileManager.default.removeItem(at: tempRoot)
            return
        }

        let finished = await waitFor(runner.state(for: card)?.phase == .failed)
        XCTAssertTrue(finished, "Run did not surface failure")

        let contents = try String(contentsOf: card.filePath, encoding: .utf8)
        XCTAssertTrue(contents.contains("agent_status: failed"))
        XCTAssertTrue(contents.contains(state.id.uuidString))
        XCTAssertTrue(contents.contains("exit 2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: card.filePath.path))

        try FileManager.default.removeItem(at: tempRoot)
    }

    @MainActor
    func testPlanFlowCreatesPhaseAndRefreshesLoader() async throws {
        let (card, tempRoot) = try makeCard()
        let runner = AgentRunner(executors: [.cli: CLIPhaseExecutor()])
        let start = await runner.startRun(card: card, flow: .plan, backend: .cli)
        guard case .success(let state) = start else {
            XCTFail("Plan run failed to start")
            try FileManager.default.removeItem(at: tempRoot)
            return
        }

        let finished = await waitFor(runner.state(for: card)?.phase == .succeeded, timeout: 8)
        XCTAssertTrue(finished, "Plan run did not finish")

        let projectURL = tempRoot.appendingPathComponent("project", isDirectory: true)
        let phases = try FileManager.default.contentsOfDirectory(at: projectURL,
                                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix("phase-") }
        XCTAssertEqual(phases.count, 2, "Expected new phase to be created")

        let newPhaseURL = phases.first { $0.lastPathComponent.starts(with: "phase-1-") } ?? phases.last!
        let planURL = newPhaseURL
            .appendingPathComponent(CardStatus.backlog.folderName, isDirectory: true)
            .appendingPathComponent("1.0-phase-plan.md")
        let planContents = try String(contentsOf: planURL, encoding: .utf8)
        XCTAssertTrue(planContents.contains(state.id.uuidString))
        XCTAssertTrue(planContents.lowercased().contains("plan"), "History should include flow name")

        try FileManager.default.removeItem(at: tempRoot)
    }

    @MainActor
    func testPlanFlowStreamsLogsAndProgress() async throws {
        let (card, tempRoot) = try makeCard()
        let executor = StubPlanExecutor(events: [
            .progress(0.2, message: "starting"),
            .log("halfway"),
            .progress(0.5, message: "processing"),
            .finished(WorkerRunResult(status: .succeeded,
                                      exitCode: 0,
                                      duration: 0.2,
                                      bytesRead: 0,
                                      bytesWritten: 0,
                                      summary: "done"))
        ])
        let runner = AgentRunner(executors: [.cli: executor])

        let start = await runner.startRun(card: card, flow: .plan, backend: .cli)
        guard case .success = start else {
            XCTFail("Run failed to start")
            return
        }

        let finished = await waitFor(runner.state(for: card)?.phase == .succeeded)
        XCTAssertTrue(finished)
        let state = runner.state(for: card)
        XCTAssertEqual(state?.progress ?? 0, 1.0, accuracy: 0.001)
        XCTAssertTrue(state?.logs.contains("halfway") ?? false)
        XCTAssertEqual(state?.result?.status, .succeeded)

        try FileManager.default.removeItem(at: tempRoot)
    }

    @MainActor
    func testManualOverrideOnDiskAllowsRerunWithStaleCard() async throws {
        let (card, tempRoot) = try makeCard(agentStatus: "failed")
        let runner = AgentRunner()

        let locked = await runner.startRun(card: card, flow: .implement)
        guard case .failure(let error) = locked else {
            XCTFail("Expected run to be blocked when agent_status is non-idle")
            try FileManager.default.removeItem(at: tempRoot)
            return
        }
        XCTAssertEqual(error, .cardLocked("failed"))

        // Manual override on disk resets the status to idle, but the in-memory Card remains stale.
        let idleContents = try String(contentsOf: card.filePath, encoding: .utf8)
            .replacingOccurrences(of: "agent_status: failed", with: "agent_status: idle")
        try idleContents.write(to: card.filePath, atomically: true, encoding: .utf8)

        let rerun = await runner.startRun(card: card, flow: .implement)
        guard case .success = rerun else {
            XCTFail("Run should start after manual override to idle")
            try FileManager.default.removeItem(at: tempRoot)
            return
        }

        let finished = await waitFor(runner.state(for: card)?.phase == .succeeded)
        XCTAssertTrue(finished, "Manual override should allow rerun to complete")

        try FileManager.default.removeItem(at: tempRoot)
    }

    @MainActor
    func testResetAgentStateClearsFlowAndSetsIdle() async throws {
        let (card, tempRoot) = try makeCard(agentStatus: "failed", agentFlow: "implement")
        let runner = AgentRunner()

        let result = await runner.resetAgentState(for: card)
        guard case .success = result else {
            XCTFail("Reset failed: \(String(describing: result))")
            try FileManager.default.removeItem(at: tempRoot)
            return
        }

        let contents = try String(contentsOf: card.filePath, encoding: .utf8)
        XCTAssertFalse(contents.contains("agent_flow:"), "Reset should clear agent_flow")
        XCTAssertTrue(contents.contains("agent_status: idle"), "Reset should set agent_status to idle")
        XCTAssertTrue(contents.contains("Agent state reset to idle"), "History should log the manual reset")

        try FileManager.default.removeItem(at: tempRoot)
    }

    @MainActor
    private func makeCard(agentStatus: String = "idle", agentFlow: String = "null") throws -> (Card, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let phase = root.appendingPathComponent("project/phase-0-test")
        let backlog = phase.appendingPathComponent(CardStatus.backlog.folderName)
        try FileManager.default.createDirectory(at: backlog, withIntermediateDirectories: true)

        let cardURL = backlog.appendingPathComponent("0.0-demo.md")
        let contents = """
        ---
        owner: tester
        agent_flow: \(agentFlow)
        agent_status: \(agentStatus)
        branch: null
        risk: normal
        review: not-requested
        ---

        # 0.0-demo

        Summary:
        Demo card

        Acceptance Criteria:
        - [ ] Do something

        History:
        - 2025-11-22 - Created
        """
        try contents.write(to: cardURL, atomically: true, encoding: .utf8)

        let parser = CardFileParser()
        let card = try parser.parse(fileURL: cardURL, contents: contents)
        return (card, root)
    }

    private func waitFor(_ condition: @autoclosure @escaping () -> Bool,
                         timeout: TimeInterval = 5,
                         pollIntervalMs: UInt64 = 100) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
        }
        return condition()
    }
}

private final class StubPlanExecutor: AgentExecutor {
    let events: [WorkerLogEvent]

    init(events: [WorkerLogEvent]) {
        self.events = events
    }

    func run(request: CodexRunRequest,
             logURL: URL,
             outputDirectory: URL,
             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        for event in events {
            await emit(event)
        }
    }
}

private struct FailingExecutor: AgentExecutor {
    let exitCode: Int32
    let summary: String

    func run(request: CodexRunRequest,
             logURL: URL,
             outputDirectory: URL,
             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        let result = WorkerRunResult(status: .failed,
                                     exitCode: exitCode,
                                     duration: 0.1,
                                     bytesRead: 0,
                                     bytesWritten: 0,
                                     summary: summary)
        await emit(.finished(result))
    }
}
