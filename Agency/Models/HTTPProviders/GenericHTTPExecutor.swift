import Foundation
import os.log

/// Generic executor that runs any HTTP provider via the agent loop.
struct GenericHTTPExecutor: AgentExecutor {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "GenericHTTPExecutor")

    private let provider: any AgentHTTPProvider
    private let promptBuilder: PromptBuilder
    private let logging: ExecutorLogging
    private let loopController: AgentLoopController
    private let session: URLSession

    init(
        provider: any AgentHTTPProvider,
        promptBuilder: PromptBuilder? = nil,
        toolBridge: ToolExecutionBridge? = nil,
        logging: ExecutorLogging = ExecutorLogging(),
        session: URLSession = .shared
    ) {
        self.provider = provider
        self.promptBuilder = promptBuilder ?? PromptBuilder()
        self.logging = logging
        self.session = session
        self.loopController = AgentLoopController(
            provider: provider,
            toolBridge: toolBridge ?? ToolExecutionBridge(),
            session: session
        )
    }

    func run(
        request: WorkerRunRequest,
        logURL: URL,
        outputDirectory: URL,
        emit: @escaping @Sendable (WorkerLogEvent) async -> Void
    ) async {
        let start = Date()

        // Resolve project root
        let workingDirectory = request.resolvedProjectRoot
        defer {
            workingDirectory?.stopAccessingSecurityScopedResource()
        }

        do {
            try logging.prepareLogDirectory(for: logURL)
            try logging.recordReady(runID: request.runID, flow: request.flow, to: logURL)
            await emit(.log("\(provider.displayName) executor starting (\(request.flow))"))

            guard let projectRoot = workingDirectory else {
                throw GenericExecutorError.projectRootUnavailable
            }

            // Check provider health
            await emit(.progress(0.05, message: "Checking \(provider.displayName) availability..."))
            let healthResult = await provider.checkHealth()
            switch healthResult {
            case .success(let status):
                if !status.isHealthy {
                    throw HTTPProviderError.connectionFailed(status.message ?? "Provider not healthy")
                }
                if let version = status.version {
                    await emit(.log("\(provider.displayName) connected (v\(version))"))
                }
            case .failure(let error):
                throw error
            }

            // Build prompt
            let prompt = try await buildPrompt(from: request, projectRoot: projectRoot)
            await emit(.progress(0.1, message: "Starting agent loop..."))

            // Run the agent loop
            try await loopController.run(
                systemPrompt: prompt,
                projectRoot: projectRoot,
                emit: emit
            )

            let duration = Date().timeIntervalSince(start)
            let workerResult = WorkerRunResult(
                status: .succeeded,
                exitCode: 0,
                duration: duration,
                bytesRead: 0,
                bytesWritten: 0,
                summary: "\(provider.displayName) completed successfully"
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

    private func buildPrompt(from request: WorkerRunRequest, projectRoot: URL) async throws -> String {
        let builder = await MainActor.run { PromptBuilder() }
        return try await builder.build(from: request, projectRoot: projectRoot)
    }
}
