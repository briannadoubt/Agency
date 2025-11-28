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
    private func makeCard() throws -> (Card, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let phase = root.appendingPathComponent("project/phase-0-test")
        let backlog = phase.appendingPathComponent(CardStatus.backlog.folderName)
        try FileManager.default.createDirectory(at: backlog, withIntermediateDirectories: true)

        let cardURL = backlog.appendingPathComponent("0.0-demo.md")
        let contents = """
        ---
        owner: tester
        agent_flow: null
        agent_status: idle
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
