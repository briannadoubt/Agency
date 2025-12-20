import Foundation
import os.log

/// Controls the agentic loop for HTTP-based providers.
///
/// Unlike CLI providers where the agent loop is handled by the CLI tool,
/// HTTP providers require implementing the agent loop in Agency. This controller
/// manages the multi-turn conversation with tool execution.
actor AgentLoopController {
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

        static let `default` = Configuration()
    }

    private var configuration: Configuration
    private var messages: [ChatMessage] = []
    private var turnCount: Int = 0
    private var totalTokensUsed: Int = 0

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

        // Add initial user message to start the conversation
        messages.append(ChatMessage(role: .user, text: "Please complete the task described in the system prompt."))

        await emit(.log("Starting agent loop (max \(configuration.maxTurns) turns)"))

        // Main agent loop
        while turnCount < configuration.maxTurns {
            try Task.checkCancellation()
            turnCount += 1

            let progress = 0.1 + (Double(turnCount) / Double(configuration.maxTurns)) * 0.8
            await emit(.progress(progress, message: "Turn \(turnCount)"))

            // Get model response
            let response: ChatResponse
            if configuration.streaming && provider.capabilities.contains(.streaming) {
                response = try await streamModelRequest(emit: emit)
            } else {
                response = try await sendModelRequest()
            }

            // Track token usage
            if let usage = response.usage {
                totalTokensUsed += usage.totalTokens
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

        await emit(.progress(0.95, message: "Completing..."))
    }

    // MARK: - Private Methods

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
        var textContent = ""
        var toolCalls: [ToolCallAccumulator] = []
        var finishReason: ChatResponse.FinishReason = .unknown
        var usage: ChatResponse.TokenUsage?

        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard let event = provider.parseStreamEvent(line) else { continue }

            switch event {
            case .textDelta(let delta):
                textContent += delta
                // Emit text in chunks for real-time display
                if textContent.count > 50 && textContent.hasSuffix(" ") {
                    await emit(.log(textContent))
                    textContent = ""
                }

            case .toolCallDelta(let index, let id, let name, let arguments):
                // Ensure we have enough accumulators
                while toolCalls.count <= index {
                    toolCalls.append(ToolCallAccumulator())
                }
                toolCalls[index].accumulate(id: id, name: name, arguments: arguments)

            case .done(let reason, let tokenUsage):
                finishReason = reason
                usage = tokenUsage

            case .error(let message):
                throw HTTPProviderError.streamingError(message)
            }
        }

        // Emit any remaining text
        if !textContent.isEmpty {
            await emit(.log(textContent))
        }

        // Build the response message
        var content: [MessageContent] = []

        if !textContent.isEmpty {
            content.append(.text(textContent))
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
            throw HTTPProviderError.authenticationFailed
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw HTTPProviderError.rateLimited(retryAfter: retryAfter)
        case 404:
            throw HTTPProviderError.modelNotFound(provider.endpoint.model)
        default:
            let message = String(data: data, encoding: .utf8)
            throw HTTPProviderError.serverError(response.statusCode, message)
        }
    }

    private func pruneContext() {
        // Keep system message and recent messages
        guard messages.count > 4 else { return }

        let systemMessage = messages.first { $0.role == .system }
        let recentMessages = Array(messages.suffix(10))

        var pruned: [ChatMessage] = []
        if let system = systemMessage {
            pruned.append(system)
        }
        pruned.append(ChatMessage(
            role: .user,
            text: "[Previous conversation pruned to manage context length. Continue from the recent context.]"
        ))
        pruned.append(contentsOf: recentMessages)

        messages = pruned
        Self.logger.info("Pruned context from \(messages.count) to \(pruned.count) messages")
    }
}

// MARK: - Helper Types

/// Accumulates partial tool call data from streaming responses.
private struct ToolCallAccumulator {
    var id: String?
    var name: String?
    var arguments: String = ""

    mutating func accumulate(id: String?, name: String?, arguments: String?) {
        if let id { self.id = id }
        if let name { self.name = name }
        if let args = arguments { self.arguments += args }
    }
}
