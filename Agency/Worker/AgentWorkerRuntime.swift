import Foundation
import os.log

/// Lightweight runtime used by the worker helper executable. This file deliberately avoids a `@main`
/// entry so the code can live in the primary target until the helper target is wired up in Xcode.
struct AgentWorkerRuntime {

    // MARK: - Process Execution Helpers

    /// Waits for a process to exit without blocking the calling thread.
    @concurrent
    private static func waitForProcessAsync(_ process: Process) async {
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
    }

    /// Reads all data from a file handle asynchronously.
    @concurrent
    private static func readDataAsync(from handle: FileHandle) async -> Data {
        handle.readDataToEndOfFile()
    }
    let payload: WorkerRunRequest
    let endpointName: String
    let logDirectory: URL
    let outputDirectory: URL
    let allowNetwork: Bool
    private let accessValidator: FileAccessValidator
    private let dateFormatter = ISO8601DateFormatter()

    private let logger = Logger(subsystem: "dev.agency.worker", category: "runtime")

    init(payload: WorkerRunRequest,
         endpointName: String,
         logDirectory: URL,
         outputDirectory: URL,
         allowNetwork: Bool,
         accessValidator: FileAccessValidator? = nil) {
        self.payload = payload
        self.endpointName = endpointName
        self.logDirectory = logDirectory
        self.outputDirectory = outputDirectory
        self.allowNetwork = allowNetwork
        let validator = accessValidator ?? FileAccessValidator(allowedRoots: [logDirectory, outputDirectory])
        self.accessValidator = validator
    }

    func run() async {
        let start = Date()
        do {
            let sandbox = WorkerSandbox(projectBookmark: payload.projectBookmark,
                                        outputDirectory: outputDirectory)
            let project = try sandbox.openProjectScope()
            defer { project.access.stopAccessing() }

            try sandbox.ensureOutputDirectoryExists()

            try record(event: "workerReady",
                       extra: ["runID": payload.runID.uuidString,
                               "project": project.url.path,
                               "output": outputDirectory.path,
                               "backend": payload.backend.rawValue,
                               "bookmarkStale": "\(project.bookmarkWasStale)"])

            // Dispatch based on backend type
            switch payload.backend {
            case .xpc:
                try await runXPCBackend(project: project, start: start)
            case .claudeCode:
                try await runClaudeCode(project: project, start: start)
            }
        } catch is CancellationError {
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            do {
                try record(event: "workerFinished",
                           extra: ["status": WorkerRunResult.Status.canceled.rawValue,
                                   "card": payload.cardRelativePath,
                                   "summary": "Canceled",
                                   "durationMs": String(durationMs),
                                   "exitCode": "1",
                                   "bytesRead": "0",
                                   "bytesWritten": "0"])
            } catch {
                logger.error("Unable to record cancellation: \(error.localizedDescription)")
            }
        } catch {
            logger.error("Worker runtime failed: \(error.localizedDescription)")
            let durationMs = Int(Date().timeIntervalSince(start) * 1000)
            do {
                try record(event: "workerFinished",
                           extra: ["status": WorkerRunResult.Status.failed.rawValue,
                                   "card": payload.cardRelativePath,
                                   "summary": error.localizedDescription,
                                   "durationMs": String(durationMs),
                                   "exitCode": "1",
                                   "bytesRead": "0",
                                   "bytesWritten": "0"])
            } catch {
                logger.error("Unable to record failure event: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Backend Implementations

    private func runXPCBackend(project: WorkerSandbox.ScopedProject, start: Date) async throws {
        // XPC backend runs Claude Code CLI inside the sandboxed worker process
        // This provides isolation while using the same underlying CLI
        try await runClaudeCode(project: project, start: start)
    }

    private func runClaudeCode(project: WorkerSandbox.ScopedProject, start: Date) async throws {
        // Run Claude Code CLI in the worker process
        let cliPath = try locateClaudeCLI()
        let prompt = buildPrompt()

        try record(event: "progress",
                   extra: ["percent": "0.1",
                           "message": "Launching Claude Code CLI..."])

        let result = try await runCLI(
            executablePath: cliPath,
            arguments: ["-p", prompt, "--output-format", "stream-json", "--max-turns", "50"],
            workingDirectory: project.url
        )

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let status: WorkerRunResult.Status = result.exitCode == 0 ? .succeeded : .failed
        try record(event: "workerFinished",
                   extra: ["status": status.rawValue,
                           "card": payload.cardRelativePath,
                           "summary": result.exitCode == 0 ? "Completed via Claude Code" : "Claude Code failed",
                           "durationMs": String(durationMs),
                           "exitCode": String(result.exitCode),
                           "bytesRead": "0",
                           "bytesWritten": "0"])
    }

    private func locateClaudeCLI() throws -> String {
        // Check common locations for claude CLI
        let paths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.npm/bin/claude"
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        throw WorkerRuntimeError.cliNotFound("claude")
    }

    private func buildPrompt() -> String {
        """
        You are working on a task card at: \(payload.cardRelativePath)

        Please implement the requirements specified in this card. Follow these steps:
        1. Read the card file to understand the acceptance criteria
        2. Implement the required changes
        3. Run any relevant tests
        4. Update the card to mark completed items

        Work through the acceptance criteria systematically.
        """
    }

    private struct CLIResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runCLI(executablePath: String,
                        arguments: [String],
                        workingDirectory: URL) async throws -> CLIResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Stream stdout to log file
        let logDir = logDirectory
        let validator = accessValidator
        let formatter = dateFormatter
        let streamTask = Task {
            let handle = stdoutPipe.fileHandleForReading
            var lineBuffer = Data()

            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }

                for byte in data {
                    if byte == 0x0A {
                        if let line = String(data: lineBuffer, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !line.isEmpty {
                            try? Self.recordLog(event: "log",
                                                extra: ["message": String(line.prefix(500))],
                                                logDirectory: logDir,
                                                dateFormatter: formatter,
                                                accessValidator: validator)
                        }
                        lineBuffer.removeAll(keepingCapacity: true)
                    } else {
                        lineBuffer.append(byte)
                    }
                }
            }
        }

        try process.run()

        // Wait for process with cancellation support - non-blocking
        await withTaskCancellationHandler {
            await Self.waitForProcessAsync(process)
        } onCancel: {
            process.terminate()
        }

        await streamTask.value

        // Read stderr asynchronously
        let stderrData = await Self.readDataAsync(from: stderrPipe.fileHandleForReading)
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return CLIResult(exitCode: process.terminationStatus, stdout: "", stderr: stderr)
    }

    // MARK: - Logging

    private func record(event: String, extra: [String: String]) throws {
        try Self.recordLog(event: event,
                           extra: extra,
                           logDirectory: logDirectory,
                           dateFormatter: dateFormatter,
                           accessValidator: accessValidator)
    }

    private static func recordLog(event: String,
                                   extra: [String: String],
                                   logDirectory: URL,
                                   dateFormatter: ISO8601DateFormatter,
                                   accessValidator: FileAccessValidator) throws {
        let logURL = logDirectory.appendingPathComponent("worker.log")
        let entry = ["timestamp": dateFormatter.string(from: .now),
                     "event": event]
            .merging(extra) { $1 }
        let line = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        try accessValidator.validateWrite(logURL)
        try appendLine(line, to: logURL)
    }

    private static func appendLine(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(data)
        handle.write(Data([0x0a]))
    }
}

// MARK: - Errors

enum WorkerRuntimeError: LocalizedError {
    case cliNotFound(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let name):
            return "\(name) CLI not found in PATH or common locations"
        }
    }
}

// MARK: - Bootstrap Helpers

enum AgentWorkerBootstrap {
    static func runtimeFromEnvironment(arguments: [String]) -> AgentWorkerRuntime? {
        let env = ProcessInfo.processInfo.environment
        guard
            let runIDString = env["AGENT_RUN_ID"],
            let runID = UUID(uuidString: runIDString),
            let endpointName = env["AGENT_ENDPOINT_NAME"],
            let logPath = env["AGENT_LOG_DIRECTORY"]
        else { return nil }

        let payload: WorkerRunRequest
        if let payloadPathIndex = arguments.firstIndex(of: "--payload"),
           arguments.indices.contains(payloadPathIndex + 1) {
            let url = URL(fileURLWithPath: arguments[payloadPathIndex + 1])
            payload = (try? decodePayload(at: url)) ?? placeholderPayload(runID: runID)
        } else {
            payload = placeholderPayload(runID: runID)
        }

        let bookmarkOverride = env["AGENT_PROJECT_BOOKMARK_BASE64"].flatMap { Data(base64Encoded: $0) }
        let outputDirectory = env["AGENT_OUTPUT_DIRECTORY"].map { URL(fileURLWithPath: $0) } ?? payload.outputDirectory
        let resolvedPayload = WorkerRunRequest(runID: payload.runID,
                                              flow: payload.flow,
                                              cardRelativePath: payload.cardRelativePath,
                                              projectBookmark: bookmarkOverride ?? payload.projectBookmark,
                                              logDirectory: payload.logDirectory,
                                              outputDirectory: outputDirectory,
                                              allowNetwork: payload.allowNetwork,
                                              cliArgs: payload.cliArgs,
                                              backend: payload.backend)

        let allowNetwork = env["AGENT_ALLOW_NETWORK"] == "1"
        return AgentWorkerRuntime(payload: resolvedPayload,
                                  endpointName: endpointName,
                                  logDirectory: URL(fileURLWithPath: logPath),
                                  outputDirectory: outputDirectory,
                                  allowNetwork: allowNetwork)
    }

    private static func decodePayload(at url: URL) throws -> WorkerRunRequest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WorkerRunRequest.self, from: data)
    }

    private static func placeholderPayload(runID: UUID) -> WorkerRunRequest {
        WorkerRunRequest(runID: runID,
                        flow: "unknown",
                        cardRelativePath: "",
                        projectBookmark: Data(),
                        logDirectory: FileManager.default.temporaryDirectory,
                        outputDirectory: FileManager.default.temporaryDirectory,
                        allowNetwork: false,
                        cliArgs: [],
                        backend: .xpc)
    }
}

// MARK: - Sandbox Helpers

struct BookmarkResolution {
    let url: URL
    let isStale: Bool
}

struct BookmarkResolver {
    typealias Resolver = (_ bookmark: Data, _ options: URL.BookmarkResolutionOptions) throws -> BookmarkResolution
    let resolve: Resolver

    static let live = BookmarkResolver { bookmark, options in
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark,
                          options: options,
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        return BookmarkResolution(url: url, isStale: isStale)
    }
}

enum WorkerSandboxError: LocalizedError {
    case missingBookmark
    case bookmarkResolutionFailed(String)
    case securityScopeUnavailable
    case writeOutsideScope(String)

    var errorDescription: String? {
        switch self {
        case .missingBookmark:
            return "Project bookmark missing; worker cannot access files."
        case .bookmarkResolutionFailed(let reason):
            return "Unable to resolve project bookmark: \(reason)"
        case .securityScopeUnavailable:
            return "Security scope could not be activated for the project bookmark."
        case .writeOutsideScope(let path):
            return "Attempted to write outside scoped directories: \(path)"
        }
    }
}

struct WorkerSandbox {
    let projectBookmark: Data
    let outputDirectory: URL
    private let fileManager: FileManager
    private let bookmarkResolver: BookmarkResolver
    private let accessFactory: @Sendable (URL) -> SecurityScopedAccess

    init(projectBookmark: Data,
         outputDirectory: URL,
         fileManager: FileManager = .default,
         bookmarkResolver: BookmarkResolver = .live,
         accessFactory: @escaping @Sendable (URL) -> SecurityScopedAccess = { url in SecurityScopedAccess(url: url) }) {
        self.projectBookmark = projectBookmark
        self.outputDirectory = outputDirectory
        self.fileManager = fileManager
        self.bookmarkResolver = bookmarkResolver
        self.accessFactory = accessFactory
    }

    func openProjectScope() throws -> ScopedProject {
        guard !projectBookmark.isEmpty else { throw WorkerSandboxError.missingBookmark }
        let resolution: BookmarkResolution
        do {
            resolution = try bookmarkResolver.resolve(projectBookmark,
                                                      [.withSecurityScope, .withoutUI, .withoutMounting])
        } catch {
            throw WorkerSandboxError.bookmarkResolutionFailed(error.localizedDescription)
        }

        let access = accessFactory(resolution.url.standardizedFileURL)
        guard access.isActive else { throw WorkerSandboxError.securityScopeUnavailable }

        return ScopedProject(url: resolution.url.standardizedFileURL,
                             access: access,
                             bookmarkWasStale: resolution.isStale)
    }

    func ensureOutputDirectoryExists() throws {
        try fileManager.createDirectory(at: outputDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: nil)
    }

    struct ScopedProject {
        let url: URL
        let access: SecurityScopedAccess
        let bookmarkWasStale: Bool
    }
}

/// Validates that workers only write inside the scoped log/output directories.
struct FileAccessValidator {
    let allowedRoots: [URL]

    func validateWrite(_ url: URL) throws {
        let normalized = url.standardizedFileURL
        let allowed = allowedRoots.contains { root in
            let rootComponents = root.standardizedFileURL.pathComponents
            let pathComponents = normalized.pathComponents
            return pathComponents.starts(with: rootComponents)
        }

        guard allowed else {
            throw WorkerSandboxError.writeOutsideScope(normalized.path)
        }
    }
}
