import Foundation
import os.log

/// Generic executor that runs any CLI provider.
struct GenericCLIExecutor: AgentExecutor {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "GenericCLIExecutor")

    private let provider: any AgentCLIProvider
    private let promptBuilder: PromptBuilder
    private let logging: ExecutorLogging
    private let fileManager: FileManager

    init(provider: any AgentCLIProvider,
         promptBuilder: PromptBuilder? = nil,
         logging: ExecutorLogging = ExecutorLogging(),
         fileManager: FileManager = .default) {
        self.provider = provider
        self.promptBuilder = promptBuilder ?? PromptBuilder()
        self.logging = logging
        self.fileManager = fileManager
    }

    func run(request: WorkerRunRequest,
             logURL: URL,
             outputDirectory: URL,
             emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async {
        let start = Date()

        // Resolve project root once and track for cleanup
        let workingDirectory = request.resolvedProjectRoot
        defer {
            workingDirectory?.stopAccessingSecurityScopedResource()
        }

        do {
            try logging.prepareLogDirectory(for: logURL)
            try logging.recordReady(runID: request.runID, flow: request.flow, to: logURL)
            await emit(.log("\(provider.displayName) executor starting (\(request.flow))"))

            // Locate CLI
            guard let projectRoot = workingDirectory else {
                throw GenericExecutorError.projectRootUnavailable
            }

            let cliLocation = try await locateCLI()
            let environment = try provider.buildEnvironment()
            let prompt = try await buildPrompt(from: request, projectRoot: projectRoot)
            let arguments = provider.buildArguments(for: request, prompt: prompt)

            await emit(.progress(0.1, message: "Launching \(provider.displayName)..."))

            // Run the CLI
            let result = try await runCLI(
                cliPath: cliLocation.path,
                arguments: arguments,
                workingDirectory: projectRoot,
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
                summary: result.exitCode == 0 ? "\(provider.displayName) completed successfully" : "\(provider.displayName) failed"
            )

            try logging.recordFinished(result: workerResult, to: logURL)
            await emit(.finished(workerResult))

        } catch is CancellationError {
            let duration = Date().timeIntervalSince(start)
            let result = WorkerRunResult(
                status: .canceled,
                exitCode: 1,
                duration: duration,
                bytesRead: 0,
                bytesWritten: 0,
                summary: "Canceled"
            )
            do {
                try logging.recordFinished(result: result, to: logURL)
            } catch {
                Self.logger.warning("Failed to record cancellation: \(error.localizedDescription)")
            }
            await emit(.finished(result))

        } catch {
            let duration = Date().timeIntervalSince(start)
            let result = WorkerRunResult(
                status: .failed,
                exitCode: 1,
                duration: duration,
                bytesRead: 0,
                bytesWritten: 0,
                summary: error.localizedDescription
            )
            do {
                try logging.recordFinished(result: result, to: logURL)
            } catch let loggingError {
                Self.logger.warning("Failed to record failure: \(loggingError.localizedDescription)")
            }
            await emit(.finished(result))
        }
    }

    // MARK: - Private

    private func locateCLI() async throws -> CLILocation {
        let result = await provider.locator.locate(userOverride: nil)
        switch result {
        case .success(let location):
            return location
        case .failure:
            throw ProviderError.cliNotFound(provider: provider.displayName)
        }
    }

    private func buildPrompt(from request: WorkerRunRequest, projectRoot: URL) async throws -> String {
        let builder = await MainActor.run { PromptBuilder() }
        return try await builder.build(from: request, projectRoot: projectRoot)
    }

    private struct CLIResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runCLI(cliPath: String,
                        arguments: [String],
                        workingDirectory: URL,
                        environment: [String: String],
                        logURL: URL,
                        emit: @escaping @Sendable (WorkerLogEvent) async -> Void) async throws -> CLIResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let streamParser = provider.streamParser

        // Stream stdout as log events
        let streamTask = Task { [logging] in
            let handle = stdoutPipe.fileHandleForReading
            var lineBuffer = Data()
            var messageCount = 0

            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }

                for byte in data {
                    if byte == 0x0A { // newline
                        if let line = String(data: lineBuffer, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !line.isEmpty {
                            if let message = streamParser.parse(line: line) {
                                messageCount += 1
                                if let logEvent = streamParser.toLogEvent(message) {
                                    await emit(logEvent)
                                }
                                let progress = streamParser.estimateProgress(messageCount: messageCount)
                                await emit(.progress(progress, message: nil))
                            }
                            do {
                                try logging.recordLog(message: String(line.prefix(500)), to: logURL)
                            } catch {
                                // Non-fatal
                            }
                        }
                        lineBuffer.removeAll(keepingCapacity: true)
                    } else {
                        lineBuffer.append(byte)
                    }
                }
            }

            // Process remaining buffer
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

        await withTaskCancellationHandler {
            process.waitUntilExit()
        } onCancel: {
            process.terminate()
        }

        await streamTask.value

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return CLIResult(stdout: "", stderr: stderr, exitCode: process.terminationStatus)
    }
}

// MARK: - Errors

enum GenericExecutorError: LocalizedError {
    case projectRootUnavailable

    var errorDescription: String? {
        switch self {
        case .projectRootUnavailable:
            return "Could not resolve project root directory."
        }
    }
}
