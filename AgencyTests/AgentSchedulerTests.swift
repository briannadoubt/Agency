import XCTest
@testable import Agency

@MainActor
final class AgentSchedulerTests: XCTestCase {
    func testRespectsGlobalAndPerFlowCaps() async throws {
        let launcher = RecordingLauncher()
        let config = AgentSchedulerConfig(maxConcurrent: 2,
                                          perFlow: [.implement: 1, .review: 1, .research: 1],
                                          softLimit: 4,
                                          hardLimit: 8)
        let scheduler = makeScheduler(config: config, launcher: launcher)

        let first = await scheduler.enqueue(cardPath: "project/phase-1-core/backlog/1.1-a.md",
                                            flow: .implement,
                                            isParallelizable: true)
        _ = await scheduler.enqueue(cardPath: "project/phase-1-core/backlog/1.2-b.md",
                                    flow: .implement,
                                    isParallelizable: true)
        _ = await scheduler.enqueue(cardPath: "project/phase-1-core/backlog/1.3-c.md",
                                     flow: .review,
                                     isParallelizable: true)

        XCTAssertEqual(launcher.launched.map(\.cardPath), [
            "project/phase-1-core/backlog/1.1-a.md",
            "project/phase-1-core/backlog/1.3-c.md"
        ])
        XCTAssertEqual(launcher.launched.map(\.flow), [.implement, .review])

        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.runningByFlow[.implement], 1)
        XCTAssertEqual(snapshot.runningByFlow[.review], 1)
        XCTAssertEqual(snapshot.queuedByFlow[.implement], 1)

        let firstID = try XCTUnwrap(runID(from: first))
        await scheduler.finish(runID: firstID, outcome: .succeeded)
        await Task.yield()

        XCTAssertEqual(launcher.launched.count, 3)
        XCTAssertEqual(launcher.launched.last?.cardPath, "project/phase-1-core/backlog/1.2-b.md")
    }

    func testCardLockPreventsOverlappingRuns() async throws {
        let launcher = RecordingLauncher()
        let scheduler = makeScheduler(config: AgentSchedulerConfig(maxConcurrent: 1,
                                                                   perFlow: [.implement: 1]),
                                      launcher: launcher)

        let first = await scheduler.enqueue(cardPath: "project/phase-5-agent/in-progress/5.3-card.md",
                                            flow: .implement,
                                            isParallelizable: true)
        let second = await scheduler.enqueue(cardPath: "project/phase-5-agent/in-progress/5.3-card.md",
                                             flow: .implement,
                                             isParallelizable: true)

        XCTAssertEqual(launcher.launched.count, 1)

        let firstID = try XCTUnwrap(runID(from: first))
        XCTAssertEqual(second, .alreadyRunning(existingRunID: firstID))
    }

    func testParallelizationSerializesWithinPhaseWhenNotParallelizable() async throws {
        let launcher = RecordingLauncher()
        let scheduler = makeScheduler(config: AgentSchedulerConfig(maxConcurrent: 2,
                                                                   perFlow: [.implement: 2]),
                                      launcher: launcher)

        let first = await scheduler.enqueue(cardPath: "project/phase-5-agent/in-progress/5.1-a.md",
                                            flow: .implement,
                                            isParallelizable: false)
        _ = await scheduler.enqueue(cardPath: "project/phase-5-agent/in-progress/5.2-b.md",
                                    flow: .implement,
                                    isParallelizable: false)

        let midSnapshot = await scheduler.snapshot()
        XCTAssertEqual(midSnapshot.runningByFlow[.implement], 1)
        XCTAssertEqual(midSnapshot.queuedByFlow[.implement], 1)

        let firstID = try XCTUnwrap(runID(from: first))
        await scheduler.finish(runID: firstID, outcome: .succeeded)
        await Task.yield()

        let afterSnapshot = await scheduler.snapshot()
        XCTAssertEqual(afterSnapshot.runningByFlow[.implement], 1)
        XCTAssertEqual(afterSnapshot.queuedByFlow[.implement], 0)

        XCTAssertEqual(launcher.launched.map(\.cardPath), [
            "project/phase-5-agent/in-progress/5.1-a.md",
            "project/phase-5-agent/in-progress/5.2-b.md"
        ])
    }

    func testParallelizableCardsCanRunTogether() async throws {
        let launcher = RecordingLauncher()
        let scheduler = makeScheduler(config: AgentSchedulerConfig(maxConcurrent: 2,
                                                                   perFlow: [.implement: 2]),
                                      launcher: launcher)

        _ = await scheduler.enqueue(cardPath: "project/phase-5-agent/in-progress/5.3-c.md",
                                     flow: .implement,
                                     isParallelizable: true)
        _ = await scheduler.enqueue(cardPath: "project/phase-5-agent/in-progress/5.4-d.md",
                                     flow: .implement,
                                     isParallelizable: true)

        let snapshot = await scheduler.snapshot()
        XCTAssertEqual(snapshot.runningByFlow[.implement], 2)
        XCTAssertEqual(snapshot.queuedByFlow[.implement], 0)
    }

    func testBackpressureSoftWarningAndHardDeferral() async throws {
        let launcher = RecordingLauncher()
        let config = AgentSchedulerConfig(maxConcurrent: 1,
                                          perFlow: [.implement: 1],
                                          softLimit: 1,
                                          hardLimit: 2)
        let scheduler = makeScheduler(config: config, launcher: launcher)

        let first = await scheduler.enqueue(cardPath: "project/phase-5-agent/in-progress/5.5-soft.md",
                                            flow: .implement,
                                            isParallelizable: true)
        _ = try XCTUnwrap(runID(from: first))

        let second = await scheduler.enqueue(cardPath: "project/phase-5-agent/in-progress/5.6-soft.md",
                                             flow: .implement,
                                             isParallelizable: true)
        if case .enqueued(_, _, let backpressure?) = second {
            XCTAssertEqual(backpressure.limit, 1)
            XCTAssertEqual(backpressure.depth, 1)
        } else {
            XCTFail("Expected soft-limit backpressure on second enqueue")
        }

        let third = await scheduler.enqueue(cardPath: "project/phase-5-agent/in-progress/5.7-hard.md",
                                            flow: .implement,
                                            isParallelizable: true)
        if case .enqueued(_, _, let backpressure?) = third {
            XCTAssertEqual(backpressure.limit, 1)
            XCTAssertEqual(backpressure.depth, 2)
        } else {
            XCTFail("Expected third request to enqueue but surface soft-limit backpressure")
        }

        let fourth = await scheduler.enqueue(cardPath: "project/phase-5-agent/in-progress/5.8-hard.md",
                                             flow: .implement,
                                             isParallelizable: true)
        XCTAssertEqual(fourth, .deferred(AgentBackpressure(limit: 2, depth: 2)))
    }

    func testRetryBackoffKeepsCardLocked() async throws {
        let launcher = RecordingLauncher { request, count in
            // Fail the first launch only.
            request.cardPath.contains("retry") && count == 1
        }

        let retryPolicy = AgentRetryPolicy(baseDelay: .milliseconds(1),
                                           multiplier: 1,
                                           jitter: 0,
                                           maxDelay: .milliseconds(1),
                                           maxAttempts: 2)
        let scheduler = makeScheduler(config: AgentSchedulerConfig(maxConcurrent: 1,
                                                                   perFlow: [.implement: 1],
                                                                   softLimit: 4,
                                                                   hardLimit: 8,
                                                                   retryPolicy: retryPolicy),
                                      launcher: launcher,
                                      sleep: { _ in },
                                      random: { _ in 0 })

        let result = await scheduler.enqueue(cardPath: "project/phase-5-agent/in-progress/5.8-retry.md",
                                             flow: .implement,
                                             isParallelizable: true)
        let runID = try XCTUnwrap(runID(from: result))

        await Task.yield()

        // First launch fails synchronously; scheduler should schedule retry and keep the lock.
        let midSnapshot = await scheduler.snapshot()
        XCTAssertEqual(midSnapshot.lockedCards, ["project/phase-5-agent/in-progress/5.8-retry.md"])

        await Task.yield()

        // Retry launches successfully (launch count increments to 2).
        XCTAssertEqual(launcher.launched.count, 2)

        await scheduler.finish(runID: runID, outcome: .succeeded)
        let finalSnapshot = await scheduler.snapshot()
        XCTAssertTrue(finalSnapshot.lockedCards.isEmpty)
    }
}

// MARK: - Test helpers

private extension AgentEnqueueResult {
    var runID: UUID? {
        if case .enqueued(let id, _, _) = self { return id }
        return nil
    }
}

private func runID(from result: AgentEnqueueResult, file: StaticString = #filePath, line: UInt = #line) -> UUID? {
    switch result {
    case .enqueued(let id, _, _):
        return id
    default:
        XCTFail("Expected enqueued runID", file: file, line: line)
        return nil
    }
}

private final class RecordingLauncher: AgentWorkerLaunching, @unchecked Sendable {
    enum StubError: Error { case failed }

    private let failureRule: @MainActor @Sendable (AgentRunRequest, Int) -> Bool
    private var launchCount = 0

    init(failureRule: @MainActor @escaping @Sendable (AgentRunRequest, Int) -> Bool = { _, _ in false }) {
        self.failureRule = failureRule
    }

    private(set) var launched: [AgentRunRequest] = []

    func launch(run: AgentRunRequest) async throws {
        launchCount += 1
        launched.append(run)
        if failureRule(run, launchCount) {
            throw StubError.failed
        }
    }
}

@MainActor
private func makeScheduler(config: AgentSchedulerConfig,
                           launcher: AgentWorkerLaunching,
                           lifecycle: AgentRunLifecycleHooks? = nil,
                           now: @Sendable @escaping () -> Date = Date.init,
                           sleep: @Sendable @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                           random: @Sendable @escaping (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> AgentScheduler {
    let resolvedLifecycle = lifecycle ?? .noop

    return AgentScheduler(config: config,
                          launcher: launcher,
                          lifecycle: resolvedLifecycle,
                          now: now,
                          sleep: sleep,
                          random: random)
}
