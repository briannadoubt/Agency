import Foundation
import Testing
@testable import Agency

@MainActor
struct AgentFlowCoordinatorTests {
    @Test func enqueueUpdatesFrontmatterAndLocksCard() async throws {
        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 11, day: 28))!
        let (root, card, parser) = try makeSampleCard(agentStatus: "idle")
        defer { try? FileManager.default.removeItem(at: root) }

        let worker = StubWorkerClient()
        let logLocator = AgentRunLogLocator(baseDirectory: root.appendingPathComponent("container"))
        let coordinator = AgentFlowCoordinator(worker: worker,
                                               writer: CardMarkdownWriter(parser: parser),
                                               logLocator: logLocator,
                                               lockStore: AgentLockStore(directory: root.appendingPathComponent("locks")),
                                               dateProvider: { fixedDate },
                                               backoffPolicy: AgentBackoffPolicy())

        let run = try await coordinator.enqueueRun(for: card,
                                                   flow: .implement,
                                                   projectRoot: root,
                                                   bookmark: Data("bookmark".utf8))

        let savedContents = try String(contentsOf: card.filePath)

        #expect(savedContents.contains("agent_flow: implement"))
        #expect(savedContents.contains("agent_status: running"))
        #expect(run.request.cardRelativePath.contains("project/phase-5-agent-integration/in-progress"))
        #expect(await coordinator.isLocked(run.card))

        let lockFile = root.appendingPathComponent("locks")
            .appendingPathComponent("project_phase-5-agent-integration_in-progress_5.2-agent-flow-mechanics.md.json")
        #expect(FileManager.default.fileExists(atPath: lockFile.path))
    }

    @Test func implementFlowWritesHistoryAndChecklist() async throws {
        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 11, day: 28))!
        let (root, card, parser) = try makeSampleCard(agentStatus: "idle",
                                                      criteria: ["first", "second", "third"])
        defer { try? FileManager.default.removeItem(at: root) }

        let worker = StubWorkerClient()
        let logLocator = AgentRunLogLocator(baseDirectory: root.appendingPathComponent("container"))
        let coordinator = AgentFlowCoordinator(worker: worker,
                                               writer: CardMarkdownWriter(parser: parser),
                                               logLocator: logLocator,
                                               lockStore: AgentLockStore(directory: root.appendingPathComponent("locks")),
                                               dateProvider: { fixedDate },
                                               backoffPolicy: AgentBackoffPolicy())

        let run = try await coordinator.enqueueRun(for: card,
                                                   flow: .implement,
                                                   projectRoot: root,
                                                   bookmark: Data(),
                                                   allowNetwork: false,
                                                   branch: "feature/xyz")

        let paths = try logLocator.makePaths(for: run.runID, on: fixedDate)
        let resultPayload = """
        {"status":"succeeded","summary":"done","tests":{"ran":["swift test"],"passed":true},"checkedCriteria":[1]}
        """
        try resultPayload.data(using: .utf8)!.write(to: paths.result)

        let completed = try await coordinator.completeRun(for: run.card,
                                                          runID: run.runID,
                                                          outcome: .succeeded)

        let contents = try String(contentsOf: completed.filePath)
        #expect(contents.contains("agent_status: succeeded"))
        #expect(contents.contains("branch: feature/xyz"))
        #expect(contents.contains("Run \(run.runID.uuidString) queued (implement)"))
        #expect(contents.contains("Run \(run.runID.uuidString) succeeded (implement); checked 1 items; tests: pass."))
        #expect(contents.contains("- [ ] first"))
        #expect(contents.contains("- [x] second"))
        #expect(contents.contains("- [ ] third"))
    }

    @Test func reviewFlowFailureWritesHistoryWithoutChecklistChanges() async throws {
        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 11, day: 28))!
        let (root, card, parser) = try makeSampleCard(agentStatus: "idle",
                                                      criteria: ["one", "two"])
        defer { try? FileManager.default.removeItem(at: root) }

        let worker = StubWorkerClient()
        let logLocator = AgentRunLogLocator(baseDirectory: root.appendingPathComponent("container"))
        let coordinator = AgentFlowCoordinator(worker: worker,
                                               writer: CardMarkdownWriter(parser: parser),
                                               logLocator: logLocator,
                                               lockStore: AgentLockStore(directory: root.appendingPathComponent("locks")),
                                               dateProvider: { fixedDate },
                                               backoffPolicy: AgentBackoffPolicy())

        let run = try await coordinator.enqueueRun(for: card,
                                                   flow: .review,
                                                   projectRoot: root,
                                                   bookmark: Data(),
                                                   allowNetwork: false,
                                                   reviewTarget: "feature/r1")

        let paths = try logLocator.makePaths(for: run.runID, on: fixedDate)
        let resultPayload = """
        {"status":"failed","summary":"lint fail"}
        """
        try resultPayload.data(using: .utf8)!.write(to: paths.result)

        let completed = try await coordinator.completeRun(for: run.card,
                                                          runID: run.runID,
                                                          outcome: .failed)

        let contents = try String(contentsOf: completed.filePath)
        #expect(contents.contains("agent_status: failed"))
        #expect(contents.contains("Run \(run.runID.uuidString) failed (review)"))
        #expect(contents.contains("- [ ] one"))
        #expect(contents.contains("- [ ] two"))
    }

    @Test func reviewFlowSuccessCountsFindings() async throws {
        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 11, day: 28))!
        let (root, card, parser) = try makeSampleCard(agentStatus: "idle",
                                                      criteria: ["one", "two"])
        defer { try? FileManager.default.removeItem(at: root) }

        let worker = StubWorkerClient()
        let logLocator = AgentRunLogLocator(baseDirectory: root.appendingPathComponent("container"))
        let coordinator = AgentFlowCoordinator(worker: worker,
                                               writer: CardMarkdownWriter(parser: parser),
                                               logLocator: logLocator,
                                               lockStore: AgentLockStore(directory: root.appendingPathComponent("locks")),
                                               dateProvider: { fixedDate },
                                               backoffPolicy: AgentBackoffPolicy())

        let run = try await coordinator.enqueueRun(for: card,
                                                   flow: .review,
                                                   projectRoot: root,
                                                   bookmark: Data(),
                                                   allowNetwork: false,
                                                   reviewTarget: "feature/r2")

        let paths = try logLocator.makePaths(for: run.runID, on: fixedDate)
        let resultPayload = """
        {"status":"succeeded","findings":[{"severity":"error"},{"severity":"warn"},{"severity":"warn"},{"severity":"info"}],"overall":"revise"}
        """
        try resultPayload.data(using: .utf8)!.write(to: paths.result)

        let completed = try await coordinator.completeRun(for: run.card,
                                                          runID: run.runID,
                                                          outcome: .succeeded)

        let contents = try String(contentsOf: completed.filePath)
        #expect(contents.contains("agent_status: succeeded"))
        #expect(contents.contains("Run \(run.runID.uuidString) succeeded (review); findings blocking/warn/info: 1/2/1; overall=revise."))
        #expect(contents.contains("- [ ] one"))
        #expect(contents.contains("- [ ] two"))
    }

    @Test func researchFlowRecordsSourcesAndLeavesChecklistUntouched() async throws {
        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 11, day: 28))!
        let (root, card, parser) = try makeSampleCard(agentStatus: "idle",
                                                      criteria: ["alpha", "beta"])
        defer { try? FileManager.default.removeItem(at: root) }

        let worker = StubWorkerClient()
        let logLocator = AgentRunLogLocator(baseDirectory: root.appendingPathComponent("container"))
        let coordinator = AgentFlowCoordinator(worker: worker,
                                               writer: CardMarkdownWriter(parser: parser),
                                               logLocator: logLocator,
                                               lockStore: AgentLockStore(directory: root.appendingPathComponent("locks")),
                                               dateProvider: { fixedDate },
                                               backoffPolicy: AgentBackoffPolicy())

        let run = try await coordinator.enqueueRun(for: card,
                                                   flow: .research,
                                                   projectRoot: root,
                                                   bookmark: Data(),
                                                   allowNetwork: false,
                                                   researchPrompt: "design tokens")

        let paths = try logLocator.makePaths(for: run.runID, on: fixedDate)
        let resultPayload = """
        {"status":"succeeded","summary":"done","sources":[{"title":"A","url":"https://example.com"},{"title":"B","url":"https://example.org"}]}
        """
        try resultPayload.data(using: .utf8)!.write(to: paths.result)

        let completed = try await coordinator.completeRun(for: run.card,
                                                          runID: run.runID,
                                                          outcome: .succeeded)

        let contents = try String(contentsOf: completed.filePath)
        #expect(contents.contains("agent_status: succeeded"))
        #expect(contents.contains("Run \(run.runID.uuidString) succeeded (research); 2 sources captured."))
        #expect(contents.contains("- [ ] alpha"))
        #expect(contents.contains("- [ ] beta"))
    }

    @Test func implementFlowFailureKeepsChecklistAndRecordsLogs() async throws {
        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 11, day: 28))!
        let (root, card, parser) = try makeSampleCard(agentStatus: "idle",
                                                      criteria: ["alpha", "beta"])
        defer { try? FileManager.default.removeItem(at: root) }

        let worker = StubWorkerClient()
        let logLocator = AgentRunLogLocator(baseDirectory: root.appendingPathComponent("container"))
        let coordinator = AgentFlowCoordinator(worker: worker,
                                               writer: CardMarkdownWriter(parser: parser),
                                               logLocator: logLocator,
                                               lockStore: AgentLockStore(directory: root.appendingPathComponent("locks")),
                                               dateProvider: { fixedDate },
                                               backoffPolicy: AgentBackoffPolicy())

        let run = try await coordinator.enqueueRun(for: card,
                                                   flow: .implement,
                                                   projectRoot: root,
                                                   bookmark: Data(),
                                                   allowNetwork: false,
                                                   branch: "feature/fail")

        let paths = try logLocator.makePaths(for: run.runID, on: fixedDate)
        let resultPayload = """
        {"status":"failed","summary":"crashed","checkedCriteria":[0]}
        """
        try resultPayload.data(using: .utf8)!.write(to: paths.result)

        let completed = try await coordinator.completeRun(for: run.card,
                                                          runID: run.runID,
                                                          outcome: .failed)

        let contents = try String(contentsOf: completed.filePath)
        #expect(contents.contains("agent_status: failed"))
        #expect(contents.contains("Run \(run.runID.uuidString) failed (implement); see logs at"))
        #expect(contents.contains(run.runID.uuidString))
        #expect(contents.contains("- [ ] alpha"))
        #expect(contents.contains("- [ ] beta"))
    }

    @Test func researchFlowFailureWritesLogReference() async throws {
        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 11, day: 28))!
        let (root, card, parser) = try makeSampleCard(agentStatus: "idle",
                                                      criteria: ["alpha", "beta"])
        defer { try? FileManager.default.removeItem(at: root) }

        let worker = StubWorkerClient()
        let logLocator = AgentRunLogLocator(baseDirectory: root.appendingPathComponent("container"))
        let coordinator = AgentFlowCoordinator(worker: worker,
                                               writer: CardMarkdownWriter(parser: parser),
                                               logLocator: logLocator,
                                               lockStore: AgentLockStore(directory: root.appendingPathComponent("locks")),
                                               dateProvider: { fixedDate },
                                               backoffPolicy: AgentBackoffPolicy())

        let run = try await coordinator.enqueueRun(for: card,
                                                   flow: .research,
                                                   projectRoot: root,
                                                   bookmark: Data(),
                                                   allowNetwork: false,
                                                   researchPrompt: "a11y")

        let paths = try logLocator.makePaths(for: run.runID, on: fixedDate)
        let resultPayload = """
        {"status":"failed","summary":"timeout","sources":[]}
        """
        try resultPayload.data(using: .utf8)!.write(to: paths.result)

        let completed = try await coordinator.completeRun(for: run.card,
                                                          runID: run.runID,
                                                          outcome: .failed)

        let contents = try String(contentsOf: completed.filePath)
        #expect(contents.contains("agent_status: failed"))
        #expect(contents.contains("Run \(run.runID.uuidString) failed (research); see logs at"))
        #expect(contents.contains(run.runID.uuidString))
        #expect(contents.contains("- [ ] alpha"))
        #expect(contents.contains("- [ ] beta"))
    }

    @Test func preventsConcurrentRunsOnSameCard() async throws {
        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 11, day: 28))!
        let (root, card, parser) = try makeSampleCard(agentStatus: "queued")
        defer { try? FileManager.default.removeItem(at: root) }

        let worker = StubWorkerClient()
        let coordinator = AgentFlowCoordinator(worker: worker,
                                               writer: CardMarkdownWriter(parser: parser),
                                               logLocator: AgentRunLogLocator(baseDirectory: root),
                                               dateProvider: { fixedDate },
                                               backoffPolicy: AgentBackoffPolicy())

        do {
            _ = try await coordinator.enqueueRun(for: card,
                                                 flow: .review,
                                                 projectRoot: root,
                                                 bookmark: Data())
            Issue.record("Expected enqueue to fail when card is already locked.")
        } catch let error as AgentFlowError {
            switch error {
            case .alreadyLocked:
                break
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func requestIncludesRelativePathAndCliArgs() async throws {
        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 11, day: 28))!
        let (root, card, parser) = try makeSampleCard(agentStatus: "idle")
        defer { try? FileManager.default.removeItem(at: root) }

        let worker = StubWorkerClient()
        let logLocator = AgentRunLogLocator(baseDirectory: root)
        let coordinator = AgentFlowCoordinator(worker: worker,
                                               writer: CardMarkdownWriter(parser: parser),
                                               logLocator: logLocator,
                                               dateProvider: { fixedDate },
                                               backoffPolicy: AgentBackoffPolicy())

        _ = try await coordinator.enqueueRun(for: card,
                                             flow: .research,
                                             projectRoot: root,
                                             bookmark: Data("bookmark".utf8))

        let requests = await worker.recordedRequests()
        guard let request = requests.first else {
            Issue.record("Expected worker to receive a request.")
            return
        }

        #expect(request.cardRelativePath == "project/phase-5-agent-integration/in-progress/5.2-agent-flow-mechanics.md")
        #expect(request.cliArguments.contains("--flow"))
        #expect(request.cliArguments.contains("--card"))
        #expect(request.cliArguments.contains("--allow-files"))
        #expect(request.cliArguments.contains(request.allowFilesScope.path))
        #expect(request.allowNetwork == false)
    }

    @Test func completionReleasesLockAndWritesStatus() async throws {
        let fixedDate = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 11, day: 28))!
        let (root, card, parser) = try makeSampleCard(agentStatus: "idle")
        defer { try? FileManager.default.removeItem(at: root) }

        let worker = StubWorkerClient()
        let coordinator = AgentFlowCoordinator(worker: worker,
                                               writer: CardMarkdownWriter(parser: parser),
                                               logLocator: AgentRunLogLocator(baseDirectory: root),
                                               dateProvider: { fixedDate },
                                               backoffPolicy: AgentBackoffPolicy())

        let run = try await coordinator.enqueueRun(for: card,
                                                   flow: .implement,
                                                   projectRoot: root,
                                                   bookmark: Data())

        let completed = try await coordinator.completeRun(for: run.card,
                                                          runID: run.runID,
                                                          outcome: .succeeded)

        let contents = try String(contentsOf: completed.filePath)
        #expect(contents.contains("agent_status: succeeded"))
        #expect(!coordinator.isLocked(completed))
    }

    @Test func backoffPolicyCapsAndAddsJitter() {
        let policy = BackoffPolicy(baseDelay: .seconds(30),
                                   multiplier: 2,
                                   jitter: 0.1,
                                   maxDelay: .seconds(300),
                                   maxRetries: 5)
        // Use custom random function that returns 0 (no jitter)
        let noJitter: (ClosedRange<Double>) -> Double = { _ in 0 }

        #expect(policy.delay(forAttempt: 1, random: noJitter) == .seconds(30))
        #expect(policy.delay(forAttempt: 2, random: noJitter) == .seconds(60))
        #expect(policy.delay(forAttempt: 3, random: noJitter) == .seconds(120))
        #expect(policy.delay(forAttempt: 4, random: noJitter) == .seconds(240))
        #expect(policy.delay(forAttempt: 5, random: noJitter) == .seconds(300))
        #expect(policy.delay(forAttempt: 6, random: noJitter) == nil)
    }

    @Test func logLocatorBuildsPerRunPaths() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let locator = AgentRunLogLocator(baseDirectory: base)
        let runID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let date = Calendar(identifier: .iso8601).date(from: DateComponents(year: 2025, month: 11, day: 28))!

        let paths = try locator.makePaths(for: runID, on: date)

        #expect(paths.directory.path.contains("Logs/Agents/20251128/\(runID.uuidString)"))
        #expect(paths.workerLog.lastPathComponent == "worker.log")
        #expect(paths.events.lastPathComponent == "events.jsonl")
        #expect(paths.result.lastPathComponent == "result.json")
        #expect(paths.stdoutTail.lastPathComponent == "stdout-tail.txt")
        #expect(FileManager.default.fileExists(atPath: paths.directory.path))
    }

    private func makeSampleCard(agentStatus: String,
                                criteria: [String] = ["first"]) throws -> (URL, Card, CardFileParser) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = root.appendingPathComponent(ProjectConventions.projectRootName, isDirectory: true)
        let phaseURL = projectRoot.appendingPathComponent("phase-5-agent-integration", isDirectory: true)
        let inProgress = phaseURL.appendingPathComponent(CardStatus.inProgress.folderName, isDirectory: true)
        try fileManager.createDirectory(at: inProgress, withIntermediateDirectories: true)

        let cardURL = inProgress.appendingPathComponent("5.2-agent-flow-mechanics.md")
        let criteriaLines = criteria.map { "- [ ] \($0)" }.joined(separator: "\n")
        let contents = """
        ---
        owner: bri
        agent_flow: null
        agent_status: \(agentStatus)
        branch: implement/5-2-agent-flow-mechanics
        risk: normal
        review: not-requested
        ---

        # 5.2 Agent Flow Mechanics

        Summary:
        Ensure agent flow mechanics work.

        Acceptance Criteria:
        \(criteriaLines)

        Notes:
        none

        History:
        - 2025-11-22 - Seeded
        """

        try contents.write(to: cardURL, atomically: true, encoding: .utf8)
        let parser = CardFileParser()
        let card = try parser.parse(fileURL: cardURL, contents: contents)

        return (root, card, parser)
    }
}

@MainActor
final class StubWorkerClient: AgentWorkerClient {
    private var requests: [AgentWorkerRequest] = []

    func launchWorker(request: AgentWorkerRequest) async throws -> AgentWorkerEndpoint {
        requests.append(request)
        return AgentWorkerEndpoint(runID: request.runID, logDirectory: request.logDirectory)
    }

    func recordedRequests() -> [AgentWorkerRequest] {
        requests
    }
}
