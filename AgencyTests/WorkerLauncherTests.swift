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

        let request = CodexRunRequest(runID: UUID(),
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
        #expect(process?.environment?["CODEX_RUN_ID"] == request.runID.uuidString)
        #expect(process?.environment?["CODEX_OUTPUT_DIRECTORY"]?.hasSuffix("/tmp") == true)

        let payloadURL = logDirectory.appendingPathComponent("worker.payload.json")
        let payloadData = try Data(contentsOf: payloadURL)
        let decoded = try JSONDecoder().decode(CodexRunRequest.self, from: payloadData)

        #expect(decoded.runID == request.runID)
        #expect(decoded.outputDirectory.lastPathComponent == "tmp")
        #expect(fm.fileExists(atPath: decoded.outputDirectory.path))

        // Simulate process exit to verify cleanup.
        process?.terminationHandler?(process!)
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(!fm.fileExists(atPath: decoded.outputDirectory.path))

        try? fm.removeItem(at: root)
    }
}
