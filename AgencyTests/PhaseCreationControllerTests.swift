import XCTest
@testable import Agency

@MainActor
final class PhaseCreationControllerTests: XCTestCase {

    func testValidationFailsForEmptyLabel() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let snapshot = ProjectLoader.ProjectSnapshot(rootURL: root,
                                                     phases: [],
                                                     validationIssues: [])
        let executor = StubAgentExecutor()
        let controller = PhaseCreationController(executor: executor, fileManager: fm)

        controller.form.label = "   "
        let success = await controller.startCreation(projectSnapshot: snapshot)

        XCTAssertFalse(success)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(executor.lastRequest)
    }

    func testRunsPlanFlowAndBuildsArguments() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let snapshot = ProjectLoader.ProjectSnapshot(rootURL: root,
                                                     phases: [],
                                                     validationIssues: [])
        let executor = StubAgentExecutor()
        executor.events = [.progress(0.25, message: "starting")]
        executor.result = WorkerRunResult(status: .succeeded,
                                          exitCode: 0,
                                          duration: 0.2,
                                          bytesRead: 0,
                                          bytesWritten: 0,
                                          summary: "done")

        let controller = PhaseCreationController(executor: executor, fileManager: fm)
        controller.form.label = "Agent Planning"
        controller.form.taskHints = "Seed a plan"
        controller.form.autoCreateCards = true

        let success = await controller.startCreation(projectSnapshot: snapshot)
        XCTAssertTrue(success)

        let request = try XCTUnwrap(executor.lastRequest)
        XCTAssertTrue(request.cliArgs.contains("--seed-plan"))
        XCTAssertTrue(request.cliArgs.contains("Agent Planning"))
        XCTAssertTrue(request.cliArgs.contains("Seed a plan"))
        XCTAssertTrue(request.cliArgs.contains("--auto-create-cards"))
        XCTAssertEqual(controller.runState?.phase, .succeeded)
        XCTAssertEqual(controller.runState?.logs.contains("starting"), true)
    }
}

@MainActor
private final class StubAgentExecutor: AgentExecutor {
    var events: [WorkerLogEvent] = []
    var result = WorkerRunResult(status: .succeeded,
                                 exitCode: 0,
                                 duration: 0.1,
                                 bytesRead: 0,
                                 bytesWritten: 0,
                                 summary: "ok")
    var lastRequest: CodexRunRequest?

    func run(request: CodexRunRequest,
             logURL: URL,
             outputDirectory: URL,
             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        lastRequest = request
        for event in events {
            await emit(event)
        }
        await emit(.finished(result))
    }
}
