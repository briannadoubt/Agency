import Foundation
import Testing
@testable import Agency

@MainActor
struct WorkerLauncherTests {

    @Test func launchBuildsEndpointPayloadAndEnvironment() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agency-worker-launch-\(UUID().uuidString)",
                                                                isDirectory: true)
        let logDirectory = root.appendingPathComponent("logs", isDirectory: true)

        let request = WorkerRunRequest(runID: UUID(),
                                      flow: "test",
                                      cardRelativePath: "project/phase/card.md",
                                      projectBookmark: Data([0x01]),
                                      logDirectory: logDirectory,
                                      outputDirectory: logDirectory,
                                      allowNetwork: false,
                                      cliArgs: ["--dry-run"])

        let launcher = WorkerLauncher(fileManager: fm,
                                      workerBinaryOverride: URL(fileURLWithPath: "/usr/bin/true"))

        let endpoint = try await launcher.launch(request: request)

        let process = launcher.activeProcess(for: request.runID)
        #expect(process != nil)
        #expect(endpoint.runID == request.runID)
        #expect(endpoint.bootstrapName.contains(request.runID.uuidString))
        #expect(process?.arguments?.contains("--endpoint") == true)
        #expect(process?.environment?["AGENT_RUN_ID"] == request.runID.uuidString)
        #expect(process?.environment?["AGENT_OUTPUT_DIRECTORY"]?.hasSuffix("/tmp") == true)

        let payloadURL = logDirectory.appendingPathComponent("worker.payload.json")
        let payloadData = try Data(contentsOf: payloadURL)
        let decoded = try JSONDecoder().decode(WorkerRunRequest.self, from: payloadData)

        #expect(decoded.runID == request.runID)
        #expect(decoded.outputDirectory.lastPathComponent == "tmp")
        #expect(fm.fileExists(atPath: decoded.outputDirectory.path))

        // Simulate process exit to verify cleanup.
        process?.terminationHandler?(process!)
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(!fm.fileExists(atPath: decoded.outputDirectory.path))

        try? fm.removeItem(at: root)
    }

    @Test func cancelTerminatesProcessAndCleansOutputs() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agency-worker-cancel-\(UUID().uuidString)",
                                                                isDirectory: true)
        let logDirectory = root.appendingPathComponent("logs", isDirectory: true)

        let request = WorkerRunRequest(runID: UUID(),
                                      flow: "test",
                                      cardRelativePath: "project/phase/card.md",
                                      projectBookmark: Data([0x02]),
                                      logDirectory: logDirectory,
                                      outputDirectory: logDirectory,
                                      allowNetwork: false,
                                      cliArgs: [])

        var processRef: MockProcess?
        let launcher = WorkerLauncher(fileManager: fm,
                                      workerBinaryOverride: URL(fileURLWithPath: "/usr/bin/true"),
                                      processFactory: {
                                          let process = MockProcess()
                                          processRef = process
                                          return process
                                      })

        let endpoint = try await launcher.launch(request: request)
        #expect(endpoint.runID == request.runID)

        let job = TestJob(runID: request.runID)
        await launcher.cancel(job: job)

        #expect(processRef?.terminateCalls ?? 0 >= 1)
        #expect(processRef?.isRunning == false)
        #expect(launcher.activeProcess(for: request.runID) == nil)

        let tmp = request.outputDirectory.appendingPathComponent("tmp")
        #expect(!fm.fileExists(atPath: tmp.path))
        #expect(fm.fileExists(atPath: request.outputDirectory.path))

        try? fm.removeItem(at: root)
    }
}

private struct TestJob: JobHandle {
    let runID: UUID
}

private final class MockProcess: Process, @unchecked Sendable {
    private var runningState = false
    private(set) var terminateCalls = 0
    private var _executableURL: URL?
    private var _arguments: [String]?
    private var _environment: [String: String]?
    private var _terminationHandler: ((Process) -> Void)?

    override func run() throws {
        runningState = true
    }

    override var executableURL: URL? {
        get { _executableURL }
        set { _executableURL = newValue }
    }

    override var launchPath: String? {
        get { _executableURL?.path }
        set { _executableURL = newValue.map(URL.init(fileURLWithPath:)) }
    }

    override var arguments: [String]? {
        get { _arguments }
        set { _arguments = newValue }
    }

    override var environment: [String : String]? {
        get { _environment }
        set { _environment = newValue }
    }

    override var terminationHandler: ((Process) -> Void)? {
        get { _terminationHandler }
        set { _terminationHandler = newValue }
    }

    override var isRunning: Bool {
        runningState
    }

    override func terminate() {
        terminateCalls += 1
        let wasRunning = runningState
        runningState = false
        if wasRunning {
            _terminationHandler?(self)
        }
    }
}
