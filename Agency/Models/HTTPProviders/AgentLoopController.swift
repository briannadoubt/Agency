import Foundation
import os.log

/// Controls the agentic loop for HTTP-based providers.
///
/// Unlike CLI providers where the agent loop is handled by the CLI tool,
/// HTTP providers require implementing the agent loop in Agency. This controller
/// manages the multi-turn conversation with tool execution.
@MainActor
final class AgentLoopController {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "AgentLoopController")

    private let provider: any AgentHTTPProvider
    private let toolBridge: ToolExecutionBridge
    private let session: URLSession

    /// Configuration for the agent loop.
    struct Configuration: Sendable {
        /// Maximum number of turns before stopping.
        var maxTurns: Int = 50
        /// Whether to stream responses.
        var streaming: Bool = true
        /// Timeout for each model request.
        var requestTimeout: TimeInterval = 120
        /// Maximum context tokens before pruning.
        var maxContextTokens: Int = 100_000
        /// Maximum retry attempts for transient errors.
        var maxRetries: Int = 3
        /// Base delay for exponential backoff (in seconds).
        var retryBaseDelay: TimeInterval = 1.0
        /// Maximum delay between retries (in seconds).
        var retryMaxDelay: TimeInterval = 60.0
        /// Minimum messages to keep when pruning (besides system message).
        var minMessagesAfterPruning: Int = 20

        static let `default` = Configuration()
    }

    /// Represents a retryable HTTP error with optional retry-after hint.
    private struct RetryableError: Error {
        let underlying: HTTPProviderError
        let retryAfter: TimeInterval?

        var isRetryable: Bool {
            switch underlying {
            case .rateLimited, .timeout:
                return true
            case .serverError(let code, _):
                // 500, 502, 503, 504 are typically transient
                return code >= 500 && code <= 504
            case .connectionFailed:
                return true
            default:
                return false
            }
        }
    }

    private var configuration: Configuration
    private var messages: [ChatMessage] = []
    private var turnCount: Int = 0
    private var totalTokensUsed: Int = 0
    private var tokenUsageHistory: [TurnTokenUsage] = []

    // Cache capability check
    private let supportsStreaming: Bool

    /// Tracks token usage for a single turn.
    struct TurnTokenUsage: Sendable {
        let turn: Int
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
    }

    init(
        provider: any AgentHTTPProvider,
        toolBridge: ToolExecutionBridge,
        session: URLSession = .shared,
        configuration: Configuration = .default
    ) {
        self.provider = provider
        self.toolBridge = toolBridge
        self.session = session
        self.configuration = configuration
        self.configuration.maxTurns = provider.maxTurns
        self.supportsStreaming = provider.capabilities.contains(.streaming)
    }

    /// Runs the agent loop with the given system prompt.
    /// - Parameters:
    ///   - systemPrompt: The system prompt to use.
    ///   - projectRoot: The project root directory for tool execution.
    ///   - emit: Callback for emitting progress events.
    func run(
        systemPrompt: String,
        projectRoot: URL,
        emit: @escaping @Sendable (WorkerLogEvent) async -> Void
    ) async throws {
        // Initialize messages with system prompt
        messages = [ChatMessage(role: .system, text: systemPrompt)]
        turnCount = 0
        totalTokensUsed = 0
        tokenUsageHistory = []

        // Add initial user message to start the conversation
        messages.append(ChatMessage(role: .user, text: "Please complete the task described in the system prompt."))

        await emit(.log("Starting agent loop (max \(configuration.maxTurns) turns)"))

        // Main agent loop
        while turnCount < configuration.maxTurns {
            try Task.checkCancellation()
            turnCount += 1

            let progress = 0.1 + (Double(turnCount) / Double(configuration.maxTurns)) * 0.8
            await emit(.progress(progress, message: "Turn \(turnCount)"))

            // Get model response with retry logic
            let response: ChatResponse
            if configuration.streaming && supportsStreaming {
                response = try await withRetry(emit: emit) {
                    try await streamModelRequest(emit: emit)
                }
            } else {
                response = try await withRetry(emit: emit) {
                    try await sendModelRequest()
                }
            }

            // Track token usage
            if let usage = response.usage {
                totalTokensUsed += usage.totalTokens
                let turnUsage = TurnTokenUsage(
                    turn: turnCount,
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens,
                    totalTokens: usage.totalTokens
                )
                tokenUsageHistory.append(turnUsage)

                // Emit token usage for visibility
                await emit(.log("[Tokens] Turn \(turnCount): +\(usage.completionTokens) completion, \(totalTokensUsed) total"))
            }

            // Add assistant message to history
            messages.append(response.message)

            // Check if we're done
            if response.finishReason == .stop {
                await emit(.log("Agent completed task"))
                break
            }

            if response.finishReason == .length {
                await emit(.log("Warning: Response truncated due to length"))
            }

            // Handle tool calls
            let toolUses = response.message.toolUses
            if !toolUses.isEmpty {
                await emit(.log("Executing \(toolUses.count) tool(s)"))

                for (id, name, arguments) in toolUses {
                    try Task.checkCancellation()

                    await emit(.log("[\(name)] executing..."))

                    let result = await toolBridge.execute(
                        toolName: name,
                        arguments: arguments,
                        projectRoot: projectRoot
                    )

                    // Add tool result to messages
                    let resultMessage = ChatMessage(
                        toolResult: id,
                        content: result.output,
                        isError: result.isError
                    )
                    messages.append(resultMessage)

                    if result.isError {
                        await emit(.log("[\(name)] error: \(result.output.prefix(200))"))
                    } else {
                        let truncated = result.output.count > 100
                            ? String(result.output.prefix(100)) + "..."
                            : result.output
                        await emit(.log("[\(name)] completed: \(truncated)"))
                    }
                }
            } else if response.finishReason != .stop {
                // No tool calls and not stopped - continue conversation
                Self.logger.warning("Model response without tool calls or stop signal")
            }

            // Check context length and prune if needed
            if totalTokensUsed > configuration.maxContextTokens {
                pruneContext()
                await emit(.log("Context pruned to manage token usage"))
            }
        }

        if turnCount >= configuration.maxTurns {
            await emit(.log("Warning: Reached maximum turns (\(configuration.maxTurns))"))
        }

        // Emit final token usage summary
        if totalTokensUsed > 0 {
            let totalPrompt = tokenUsageHistory.reduce(0) { $0 + $1.promptTokens }
            let totalCompletion = tokenUsageHistory.reduce(0) { $0 + $1.completionTokens }
            await emit(.log("[Tokens] Final: \(totalPrompt) prompt + \(totalCompletion) completion = \(totalTokensUsed) total tokens"))
        }

        await emit(.progress(0.95, message: "Completing..."))
    }

    // MARK: - Private Methods

    /// Executes an operation with exponential backoff retry for transient errors.
    private func withRetry<T>(
        emit: @escaping @Sendable (WorkerLogEvent) async -> Void,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var attempt = 0

        while attempt < configuration.maxRetries {
            do {
                return try await operation()
            } catch let error as RetryableError where error.isRetryable {
                attempt += 1
                lastError = error.underlying

                if attempt >= configuration.maxRetries {
                    Self.logger.warning("Max retries (\(self.configuration.maxRetries)) exceeded")
                    break
                }

                // Calculate delay: use Retry-After header if available, otherwise exponential backoff
                let backoffDelay = configuration.retryBaseDelay * pow(2.0, Double(attempt - 1))
                let delay = min(error.retryAfter ?? backoffDelay, configuration.retryMaxDelay)

                await emit(.log("Transient error (attempt \(attempt)/\(configuration.maxRetries)): \(error.underlying.localizedDescription). Retrying in \(Int(delay))s..."))

                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()

            } catch let error as HTTPProviderError {
                // Non-retryable HTTP error, throw immediately
                throw error
            } catch {
                // Other errors (network, cancellation, etc.)
                throw error
            }
        }

        // If we get here, we exhausted retries
        throw lastError ?? HTTPProviderError.connectionFailed("Max retries exceeded")
    }

    private func sendModelRequest() async throws -> ChatResponse {
        let tools = toolBridge.availableTools
        let request = try provider.buildRequest(
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            stream: false
        )

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPProviderError.invalidResponse("Not an HTTP response")
        }

        try checkHTTPStatus(httpResponse, data: data)
        return try provider.parseResponse(data)
    }

    private func streamModelRequest(
        emit: @escaping @Sendable (WorkerLogEvent) async -> Void
    ) async throws -> ChatResponse {
        let tools = toolBridge.availableTools
        let request = try provider.buildRequest(
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            stream: true
        )

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPProviderError.invalidResponse("Not an HTTP response")
        }

        if httpResponse.statusCode != 200 {
            // For streaming errors, we need to collect the full response
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            try checkHTTPStatus(httpResponse, data: errorData)
        }

        // Parse streaming response
        // fullTextContent: Complete text for conversation history (never reset)
        // logBuffer: Buffer for chunked UI display (reset after emitting)
        var fullTextContent = ""
        var logBuffer = ""
        var toolCalls: [ToolCallAccumulator] = []
        var finishReason: ChatResponse.FinishReason = .unknown
        var usage: ChatResponse.TokenUsage?

        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard let event = provider.parseStreamEvent(line) else { continue }

            switch event {
            case .textDelta(let delta):
                fullTextContent += delta
                logBuffer += delta
                // Emit text in chunks for real-time display (every ~80 chars at word boundary)
                if logBuffer.count > 80, let lastSpace = logBuffer.lastIndex(of: " ") {
                    let emitUpTo = logBuffer[...lastSpace]
                    await emit(.log(String(emitUpTo)))
                    logBuffer = String(logBuffer[logBuffer.index(after: lastSpace)...])
                }

            case .toolCallDelta(let index, let id, let name, let arguments):
                // Ensure we have enough accumulators
                while toolCalls.count <= index {
                    toolCalls.append(ToolCallAccumulator())
                }
                // Inline accumulation to avoid actor isolation issues
                if let id { toolCalls[index].id = id }
                if let name { toolCalls[index].name = name }
                if let args = arguments { toolCalls[index].arguments += args }

            case .done(let reason, let tokenUsage):
                finishReason = reason
                usage = tokenUsage

            case .error(let message):
                throw HTTPProviderError.streamingError(message)
            }
        }

        // Emit any remaining buffered text for UI display
        if !logBuffer.isEmpty {
            await emit(.log(logBuffer))
        }

        // Build the response message with FULL text content (not the buffer)
        var content: [MessageContent] = []

        if !fullTextContent.isEmpty {
            content.append(.text(fullTextContent))
        }

        for accumulator in toolCalls {
            if let id = accumulator.id, let name = accumulator.name {
                content.append(.toolUse(
                    id: id,
                    name: name,
                    arguments: accumulator.arguments
                ))
            }
        }

        return ChatResponse(
            message: ChatMessage(role: .assistant, content: content),
            finishReason: toolCalls.isEmpty ? finishReason : .toolUse,
            usage: usage
        )
    }

    private func checkHTTPStatus(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401:
            // Authentication errors are not retryable
            throw HTTPProviderError.authenticationFailed
        case 404:
            // Model not found is not retryable
            throw HTTPProviderError.modelNotFound(provider.endpoint.model)
        case 429:
            // Rate limited - retryable with Retry-After hint
            let retryAfterSeconds = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) }
            let error = HTTPProviderError.rateLimited(retryAfter: retryAfterSeconds.map { Int($0) })
            throw RetryableError(underlying: error, retryAfter: retryAfterSeconds)
        case 500, 502, 503, 504:
            // Server errors are typically transient and retryable
            let message = String(data: data, encoding: .utf8)
            let error = HTTPProviderError.serverError(response.statusCode, message)
            throw RetryableError(underlying: error, retryAfter: nil)
        default:
            // Other errors (400, 403, etc.) are not retryable
            let message = String(data: data, encoding: .utf8)
            throw HTTPProviderError.serverError(response.statusCode, message)
        }
    }

    private func pruneContext() {
        let originalCount = messages.count
        let minToKeep = configuration.minMessagesAfterPruning

        // Don't prune if we're already at or below minimum
        guard originalCount > minToKeep + 2 else { return }

        // Find system message (always first)
        let systemMessage = messages.first { $0.role == .system }

        // Calculate how many messages to keep (at least minMessagesAfterPruning)
        // Keep more recent context - aim for ~60% of messages to preserve continuity
        let keepCount = max(minToKeep, originalCount * 3 / 5)

        // Get recent messages, ensuring we don't break tool call/result pairs
        var recentMessages = Array(messages.suffix(keepCount))

        // Ensure first message in recent isn't a tool result (orphaned from its call)
        while let first = recentMessages.first, first.role == .tool, recentMessages.count > 2 {
            recentMessages.removeFirst()
        }

        // Build summary of pruned content for context continuity
        let prunedCount = originalCount - recentMessages.count - (systemMessage != nil ? 1 : 0)
        let summaryNote = """
            [Context note: \(prunedCount) earlier messages were summarized to manage context length. \
            The conversation has been ongoing - continue from the recent context below.]
            """

        var pruned: [ChatMessage] = []
        if let system = systemMessage {
            pruned.append(system)
        }
        pruned.append(ChatMessage(role: .user, text: summaryNote))
        pruned.append(contentsOf: recentMessages)

        messages = pruned

        // Reset token count estimate (will be recalculated on next response)
        totalTokensUsed = totalTokensUsed / 2  // Rough estimate after pruning

        Self.logger.info("Pruned context from \(originalCount) to \(pruned.count) messages (kept \(recentMessages.count) recent)")
    }
}

// MARK: - Helper Types

/// Accumulates partial tool call data from streaming responses.
private struct ToolCallAccumulator: Sendable {
    var id: String?
    var name: String?
    var arguments: String = ""

    mutating func accumulate(id: String?, name: String?, arguments: String?) {
        if let id { self.id = id }
        if let name { self.name = name }
        if let args = arguments { self.arguments += args }
    }
}
