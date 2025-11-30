import Foundation

/// Executor that runs Claude Code CLI directly for card implementation tasks.
struct ClaudeCodeExecutor: AgentExecutor {
    private let locator: ClaudeCodeLocator
    private let fileManager: FileManager

    init(locator: ClaudeCodeLocator = ClaudeCodeLocator(),
         fileManager: FileManager = .default) {
        self.locator = locator
        self.fileManager = fileManager
    }

    func run(request: CodexRunRequest,
             logURL: URL,
             outputDirectory: URL,
             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        let start = Date()

        do {
            try prepareLogDirectory(for: logURL)
            try record(event: "workerReady",
                       extra: ["runID": request.runID.uuidString,
                               "flow": request.flow],
                       logURL: logURL)
            await emit(.log("Claude Code executor starting (\(request.flow))"))

            // Validate prerequisites
            let cliPath = try await resolveCLIPath()
            let environment = try resolveEnvironment()
            let prompt = buildPrompt(from: request)

            await emit(.progress(0.1, message: "Launching Claude Code CLI..."))

            // Run the CLI
            let result = try await runClaude(
                cliPath: cliPath,
                prompt: prompt,
                workingDirectory: request.resolvedProjectRoot,
                environment: environment,
                logURL: logURL,
                emit: emit
            )

            let duration = Date().timeIntervalSince(start)
            let workerResult = WorkerRunResult(
                status: result.exitCode == 0 ? .succeeded : .failed,
                exitCode: result.exitCode,
                duration: duration,
                bytesRead: 0,
                bytesWritten: 0,
                summary: result.exitCode == 0 ? "Claude Code completed successfully" : "Claude Code failed"
            )

            try record(event: "workerFinished",
                       extra: ["status": workerResult.status.rawValue,
                               "summary": workerResult.summary,
                               "durationMs": String(Int(duration * 1000)),
                               "exitCode": String(result.exitCode)],
                       logURL: logURL)
            await emit(.finished(workerResult))

        } catch is CancellationError {
            let duration = Date().timeIntervalSince(start)
            let result = WorkerRunResult(status: .canceled,
                                         exitCode: 1,
                                         duration: duration,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: "Canceled")
            try? record(event: "workerFinished",
                        extra: ["status": "canceled", "summary": "Canceled"],
                        logURL: logURL)
            await emit(.finished(result))
        } catch {
            let duration = Date().timeIntervalSince(start)
            let result = WorkerRunResult(status: .failed,
                                         exitCode: 1,
                                         duration: duration,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: error.localizedDescription)
            try? record(event: "workerFinished",
                        extra: ["status": "failed", "summary": error.localizedDescription],
                        logURL: logURL)
            await emit(.finished(result))
        }
    }

    // MARK: - Errors

    enum ExecutorError: LocalizedError {
        case cliNotFound
        case apiKeyNotFound
        case projectRootUnavailable

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "Claude Code CLI not found. Configure it in Settings."
            case .apiKeyNotFound:
                return "Anthropic API key not configured. Add it in Settings."
            case .projectRootUnavailable:
                return "Could not resolve project root directory."
            }
        }
    }

    // MARK: - Private

    private func prepareLogDirectory(for logURL: URL) throws {
        let directory = logURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func resolveCLIPath() async throws -> String {
        let settings = await MainActor.run { ClaudeCodeSettings.shared }
        let override = await MainActor.run { settings.cliPathOverride }

        let result = await locator.locate(userOverridePath: override.isEmpty ? nil : override)

        switch result {
        case .success(let info):
            return info.path
        case .failure:
            throw ExecutorError.cliNotFound
        }
    }

    private func resolveEnvironment() throws -> [String: String] {
        guard let env = ClaudeKeyManager.environmentWithKey() else {
            throw ExecutorError.apiKeyNotFound
        }
        return env
    }

    private func buildPrompt(from request: CodexRunRequest) -> String {
        // Build a prompt that instructs Claude to work on the card
        var prompt = """
        You are working on a task card at: \(request.cardRelativePath)

        Please implement the requirements specified in this card. Follow these steps:
        1. Read the card file to understand the acceptance criteria
        2. Implement the required changes
        3. Run any relevant tests
        4. Update the card to mark completed items

        Work through the acceptance criteria systematically.
        """

        // Add any CLI args as additional context
        if !request.cliArgs.isEmpty {
            prompt += "\n\nAdditional context from CLI args: \(request.cliArgs.joined(separator: " "))"
        }

        return prompt
    }

    private struct CLIResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runClaude(cliPath: String,
                           prompt: String,
                           workingDirectory: URL?,
                           environment: [String: String],
                           logURL: URL,
                           emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async throws -> CLIResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "-p", prompt,
            "--output-format", "text",
            "--allowedTools", "Bash,Read,Write,Edit,Glob,Grep",
            "--max-turns", "50"
        ]
        process.environment = environment

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Stream stdout as log events
        let streamTask = Task {
            let handle = stdoutPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let line = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !line.isEmpty {
                    await emit(.log(line))
                    try? record(event: "log", extra: ["message": String(line.prefix(500))], logURL: logURL)
                }
            }
        }

        try process.run()

        // Wait for process with cancellation support
        await withTaskCancellationHandler {
            process.waitUntilExit()
        } onCancel: {
            process.terminate()
        }

        streamTask.cancel()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let stdout = "" // Already streamed

        return CLIResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    private func record(event: String, extra: [String: String], logURL: URL) throws {
        let entry = ["timestamp": ISO8601DateFormatter().string(from: .now),
                     "event": event]
            .merging(extra) { $1 }
        let data = try JSONSerialization.data(withJSONObject: entry)
        try appendLine(data, to: logURL)
    }

    private func appendLine(_ data: Data, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handle.write(data)
        handle.write(Data([0x0a]))
        try handle.close()
    }
}
