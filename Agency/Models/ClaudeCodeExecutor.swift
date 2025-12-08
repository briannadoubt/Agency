import Foundation
import os.log

/// Executor that runs Claude Code CLI directly for card implementation tasks.
struct ClaudeCodeExecutor: AgentExecutor {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "ClaudeCodeExecutor")
    private let locator: ClaudeCodeLocator
    private let fileManager: FileManager
    private let streamParser: ClaudeStreamParser
    private let logging: ExecutorLogging
    private let usePromptBuilder: Bool

    init(locator: ClaudeCodeLocator = ClaudeCodeLocator(),
         fileManager: FileManager = .default,
         streamParser: ClaudeStreamParser = ClaudeStreamParser(),
         logging: ExecutorLogging = ExecutorLogging(),
         usePromptBuilder: Bool = true) {
        self.locator = locator
        self.fileManager = fileManager
        self.streamParser = streamParser
        self.logging = logging
        self.usePromptBuilder = usePromptBuilder
    }

    func run(request: WorkerRunRequest,
             logURL: URL,
             outputDirectory: URL,
             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        let start = Date()

        // Resolve project root once and track for cleanup
        let workingDirectory = request.resolvedProjectRoot
        var cliIsBookmark = false
        defer {
            workingDirectory?.stopAccessingSecurityScopedResource()
            // Stop accessing CLI bookmark if we used one
            if cliIsBookmark {
                Task {
                    await CLIBookmarkStore.shared.stopAccessing()
                }
            }
        }

        do {
            try logging.prepareLogDirectory(for: logURL)
            try logging.recordReady(runID: request.runID, flow: request.flow, to: logURL)
            await emit(.log("Claude Code executor starting (\(request.flow))"))

            // Validate prerequisites
            let cliResolution = try await resolveCLIPath()
            cliIsBookmark = cliResolution.isBookmark
            let environment = try resolveEnvironment()
            let prompt: String
            if usePromptBuilder, let projectRoot = workingDirectory {
                prompt = try await buildPromptWithBuilder(from: request, projectRoot: projectRoot)
            } else {
                prompt = buildPromptLegacy(from: request)
            }

            await emit(.progress(0.1, message: "Launching Claude Code CLI..."))

            // Run the CLI
            let result = try await runClaude(
                cliPath: cliResolution.path,
                prompt: prompt,
                workingDirectory: workingDirectory,
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

            try logging.recordFinished(result: workerResult, to: logURL)
            await emit(.finished(workerResult))

        } catch is CancellationError {
            let duration = Date().timeIntervalSince(start)
            let result = WorkerRunResult(status: .canceled,
                                         exitCode: 1,
                                         duration: duration,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: "Canceled")
            do {
                try logging.recordFinished(result: result, to: logURL)
            } catch {
                Self.logger.warning("Failed to record cancellation to log file: \(error.localizedDescription)")
            }
            await emit(.finished(result))
        } catch {
            let duration = Date().timeIntervalSince(start)
            let result = WorkerRunResult(status: .failed,
                                         exitCode: 1,
                                         duration: duration,
                                         bytesRead: 0,
                                         bytesWritten: 0,
                                         summary: error.localizedDescription)
            do {
                try logging.recordFinished(result: result, to: logURL)
            } catch let loggingError {
                Self.logger.warning("Failed to record failure to log file: \(loggingError.localizedDescription)")
            }
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

    private struct CLIResolution {
        let path: String
        let isBookmark: Bool
    }

    private func resolveCLIPath() async throws -> CLIResolution {
        let override = await MainActor.run {
            ClaudeCodeSettings.shared.cliPathOverride
        }

        let result = await locator.locate(userOverridePath: override.isEmpty ? nil : override)

        switch result {
        case .success(let info):
            return CLIResolution(path: info.path, isBookmark: info.source == .bookmark)
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

    private func buildPromptWithBuilder(from request: WorkerRunRequest, projectRoot: URL) async throws -> String {
        let promptBuilder = await MainActor.run { PromptBuilder() }
        return try await promptBuilder.build(from: request, projectRoot: projectRoot)
    }

    private func buildPromptLegacy(from request: WorkerRunRequest) -> String {
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
            "--output-format", "stream-json",
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

        // Stream stdout as log events, parsing JSON lines
        let streamTask = Task { [streamParser] in
            let handle = stdoutPipe.fileHandleForReading
            var lineBuffer = Data()
            var messageCount = 0

            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }

                // Process data byte by byte to find complete lines
                for byte in data {
                    if byte == 0x0A { // newline
                        if let line = String(data: lineBuffer, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !line.isEmpty {
                            // Parse as JSON and emit structured event
                            if let message = streamParser.parse(line: line) {
                                messageCount += 1
                                if let logEvent = streamParser.toLogEvent(message) {
                                    await emit(logEvent)
                                }
                                // Emit progress updates based on message count
                                let progress = min(0.1 + Double(messageCount) * 0.05, 0.9)
                                await emit(.progress(progress, message: nil))
                            }
                            do {
                                try logging.recordLog(message: String(line.prefix(500)), to: logURL)
                            } catch {
                                // Log recording failure is non-fatal; continue processing stream
                            }
                        }
                        lineBuffer.removeAll(keepingCapacity: true)
                    } else {
                        lineBuffer.append(byte)
                    }
                }
            }

            // Process any remaining data in buffer
            if !lineBuffer.isEmpty,
               let line = String(data: lineBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                if let message = streamParser.parse(line: line),
                   let logEvent = streamParser.toLogEvent(message) {
                    await emit(logEvent)
                }
            }
        }

        do {
            try process.run()
        } catch {
            streamTask.cancel()
            throw error
        }

        // Wait for process with cancellation support
        await withTaskCancellationHandler {
            process.waitUntilExit()
        } onCancel: {
            process.terminate()
        }

        // Wait for stream task to complete processing
        await streamTask.value

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let stdout = "" // Already streamed

        return CLIResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}
