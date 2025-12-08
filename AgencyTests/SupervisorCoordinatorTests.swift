import Foundation
import Testing
@testable import Agency

@MainActor
struct SupervisorCoordinatorTests {

    @Test func statusStartsAsStopped() {
        let coordinator = makeCoordinator()
        #expect(coordinator.status == .stopped)
    }

    @Test func startTransitionsToRunning() async {
        let coordinator = makeCoordinator()
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        await coordinator.start(projectRoot: projectRoot)

        #expect(coordinator.status == .running)
        #expect(coordinator.projectRoot == projectRoot)

        await coordinator.stop()
    }

    @Test func stopTransitionsToStopped() async {
        let coordinator = makeCoordinator()
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        await coordinator.start(projectRoot: projectRoot)
        await coordinator.stop()

        #expect(coordinator.status == .stopped)
        #expect(coordinator.projectRoot == nil)
    }

    @Test func pauseAndResumeWorkCorrectly() async {
        let coordinator = makeCoordinator()
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        await coordinator.start(projectRoot: projectRoot)

        coordinator.pause()
        #expect(coordinator.status == .paused)

        await coordinator.resume()
        #expect(coordinator.status == .running)

        await coordinator.stop()
    }

    @Test func pauseOnlyWorksWhenRunning() async {
        let coordinator = makeCoordinator()

        coordinator.pause()
        #expect(coordinator.status == .stopped)
    }

    @Test func resumeOnlyWorksWhenPaused() async {
        let coordinator = makeCoordinator()
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        await coordinator.start(projectRoot: projectRoot)
        await coordinator.resume()

        #expect(coordinator.status == .running)

        await coordinator.stop()
    }

    @Test func doubleStartIsIgnored() async {
        let coordinator = makeCoordinator()
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        await coordinator.start(projectRoot: projectRoot)
        await coordinator.start(projectRoot: projectRoot)

        #expect(coordinator.status == .running)

        await coordinator.stop()
    }

    @Test func statusSnapshotReturnsCorrectValues() async {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let coordinator = makeCoordinator(dateProvider: { fixedDate })
        let projectRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        await coordinator.start(projectRoot: projectRoot)

        let snapshot = coordinator.getStatusSnapshot()

        #expect(snapshot.status == .running)
        #expect(snapshot.projectRoot == projectRoot)
        #expect(snapshot.lastUpdated == fixedDate)
        #expect(snapshot.activeRunCount >= 0)
        #expect(snapshot.queuedCardCount >= 0)

        await coordinator.stop()
    }

    @Test func enqueueThrowsWhenNotStarted() async throws {
        let coordinator = makeCoordinator()
        let (card, cleanup) = try makeSampleCard()
        defer { cleanup() }

        do {
            try await coordinator.enqueueCard(card)
            Issue.record("Expected error when enqueueing before start")
        } catch let error as SupervisorCoordinatorError {
            if case .notStarted = error {
                // Expected
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func supervisorStatusIsActiveWhenRunning() {
        #expect(SupervisorStatus.running.isActive == true)
        #expect(SupervisorStatus.stopped.isActive == false)
        #expect(SupervisorStatus.paused.isActive == false)
        #expect(SupervisorStatus.starting.isActive == false)
    }

    // MARK: - Helpers

    private func makeCoordinator(
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) -> SupervisorCoordinator {
        let scheduler = AgentScheduler(
            config: AgentSchedulerConfig(maxConcurrent: 2),
            launcher: StubAgentWorkerLauncher(),
            lifecycle: .noop,
            now: dateProvider,
            sleep: { _ in },
            random: { $0.lowerBound }
        )

        let flowCoordinator = AgentFlowCoordinator(
            worker: StubAgentWorkerClient(),
            writer: CardMarkdownWriter(),
            logLocator: AgentRunLogLocator(baseDirectory: FileManager.default.temporaryDirectory),
            backoffPolicy: AgentBackoffPolicy()
        )

        return SupervisorCoordinator(
            scheduler: scheduler,
            flowCoordinator: flowCoordinator,
            dateProvider: dateProvider
        )
    }

    private func makeSampleCard() throws -> (Card, () -> Void) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let phaseURL = projectRoot.appendingPathComponent("phase-1-test", isDirectory: true)
        let backlog = phaseURL.appendingPathComponent("backlog", isDirectory: true)
        try fileManager.createDirectory(at: backlog, withIntermediateDirectories: true)

        let cardURL = backlog.appendingPathComponent("1.1-test-card.md")
        let contents = """
        ---
        owner: test
        agent_flow: null
        agent_status: idle
        ---

        # 1.1 Test Card

        Summary:
        Test card for testing.

        Acceptance Criteria:
        - [ ] Test passes

        Notes:
        none

        History:
        - 2025-12-07 - Created
        """

        try contents.write(to: cardURL, atomically: true, encoding: .utf8)
        let parser = CardFileParser()
        let card = try parser.parse(fileURL: cardURL, contents: contents)

        return (card, { try? fileManager.removeItem(at: root) })
    }
}

// MARK: - Test Stubs

@MainActor
private final class StubAgentWorkerLauncher: AgentWorkerLaunching {
    func launch(run: SchedulerRunRequest) async throws {
        // No-op for testing
    }
}

@MainActor
private final class StubAgentWorkerClient: AgentWorkerClient {
    func launchWorker(request: AgentWorkerRequest) async throws -> AgentWorkerEndpoint {
        AgentWorkerEndpoint(runID: request.runID, logDirectory: request.logDirectory)
    }
}
