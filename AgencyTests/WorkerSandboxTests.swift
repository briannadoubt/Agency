import Foundation
import Testing
@testable import Agency

@MainActor
struct WorkerSandboxTests {

    @Test func sandboxResolvesBookmarkWithSecurityScopeOptions() throws {
        var capturedOptions: URL.BookmarkResolutionOptions?
        let resolver = BookmarkResolver { _, options in
            capturedOptions = options
            return BookmarkResolution(url: URL(fileURLWithPath: "/tmp/project"), isStale: false)
        }

        let sandbox = WorkerSandbox(projectBookmark: Data([0x01]),
                                    outputDirectory: URL(fileURLWithPath: "/tmp/out"),
                                    bookmarkResolver: resolver,
                                    accessFactory: { SecurityScopedAccess(url: $0, didStart: true) })

        _ = try sandbox.openProjectScope()

        #expect(capturedOptions?.contains(.withSecurityScope) == true)
        #expect(capturedOptions?.contains(.withoutUI) == true)
    }

    @Test func runDirectoriesCreateScopedOutputAndCleanup() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agency-run-dirs-\(UUID().uuidString)",
                                                                isDirectory: true)
        let logDirectory = root.appendingPathComponent("logs", isDirectory: true)
        let request = CodexRunRequest(runID: UUID(),
                                      flow: "test",
                                      cardRelativePath: "card.md",
                                      projectBookmark: Data([0x00]),
                                      logDirectory: logDirectory,
                                      outputDirectory: logDirectory,
                                      allowNetwork: false,
                                      cliArgs: [])

        let directories = try RunDirectories.prepare(for: request, fileManager: fm)

        #expect(fm.fileExists(atPath: directories.logDirectory.path))
        #expect(fm.fileExists(atPath: directories.outputDirectory.path))

        directories.cleanupOutputs(using: fm)
        #expect(!fm.fileExists(atPath: directories.outputDirectory.path))

        try? fm.removeItem(at: directories.logDirectory)
        try? fm.removeItem(at: root)
    }

    @Test func runtimeLogsBookmarkFailure() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agency-worker-runtime-\(UUID().uuidString)",
                                                                isDirectory: true)
        let logDirectory = root.appendingPathComponent("logs", isDirectory: true)
        let outputDirectory = root.appendingPathComponent("tmp", isDirectory: true)
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let request = CodexRunRequest(runID: UUID(),
                                      flow: "test",
                                      cardRelativePath: "project/phase/card.md",
                                      projectBookmark: Data(), // invalid bookmark to force failure
                                      logDirectory: logDirectory,
                                      outputDirectory: outputDirectory,
                                      allowNetwork: false,
                                      cliArgs: [])

        let runtime = CodexWorkerRuntime(payload: request,
                                         endpointName: "test",
                                         logDirectory: logDirectory,
                                         outputDirectory: outputDirectory,
                                         allowNetwork: false)

        await runtime.run()

        let logURL = logDirectory.appendingPathComponent("worker.log")
        let logContents = try String(contentsOf: logURL)

        #expect(logContents.contains("\"status\":\"failed\""))
        #expect(logContents.lowercased().contains("bookmark"))

        try? fm.removeItem(at: root)
    }
}
