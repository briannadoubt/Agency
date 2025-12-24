@preconcurrency import Foundation
import os.log

/// Base provider for OpenAI-compatible APIs.
///
/// This provider works with any server that implements the OpenAI chat completions API,
/// including Ollama, llama.cpp, vLLM, LM Studio, LocalAI, and text-generation-webui.
struct OpenAICompatibleProvider: AgentHTTPProvider, Sendable {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "OpenAICompatibleProvider")

    let identifier: String
    let displayName: String
    let supportedFlows: Set<AgentFlow>
    let capabilities: HTTPProviderCapabilities
    let endpoint: HTTPProviderEndpoint
    let maxTurns: Int

    init(
        identifier: String,
        displayName: String,
        endpoint: HTTPProviderEndpoint,
        supportedFlows: Set<AgentFlow> = [.implement, .review, .research, .plan],
        capabilities: HTTPProviderCapabilities = .openAICompatible,
        maxTurns: Int = 50
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.endpoint = endpoint
        self.supportedFlows = supportedFlows
        self.capabilities = capabilities
        self.maxTurns = maxTurns
    }

    // MARK: - Request Building

    func buildRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition]?,
        stream: Bool
    ) throws -> URLRequest {
        let url = endpoint.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = endpoint.timeout

        // Headers
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add idempotency key to prevent duplicate charges on network retries
        // This is a unique identifier for this specific request
        let requestId = UUID().uuidString
        request.setValue(requestId, forHTTPHeaderField: "X-Request-ID")
        request.setValue(requestId, forHTTPHeaderField: "Idempotency-Key")

        try applyAuthentication(to: &request)

        // Body
        let body = ChatCompletionRequest(
            model: endpoint.model,
            messages: messages.map { $0.toOpenAI() },
            maxTokens: endpoint.maxTokens,
            stream: stream,
            tools: tools?.map { $0.toOpenAI() }
        )

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func applyAuthentication(to request: inout URLRequest) throws {
        switch endpoint.auth {
        case .none:
            break
        case .bearer(let keychain):
            let key = try HTTPKeyManager.retrieve(for: keychain)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .header(let name, let keychain):
            let key = try HTTPKeyManager.retrieve(for: keychain)
            request.setValue(key, forHTTPHeaderField: name)
        case .query(let name, let keychain):
            let key = try HTTPKeyManager.retrieve(for: keychain)
            guard var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else {
                throw HTTPProviderError.invalidURL(request.url?.absoluteString ?? "unknown")
            }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: name, value: key))
            components.queryItems = items
            request.url = components.url
        }
    }

    // MARK: - Response Parsing

    func parseResponse(_ data: Data) throws -> ChatResponse {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        guard let choice = response.choices.first else {
            throw HTTPProviderError.invalidResponse("No choices in response")
        }

        return ChatResponse(
            message: choice.message.toChatMessage(),
            finishReason: parseFinishReason(choice.finishReason),
            usage: response.usage.map { usage in
                ChatResponse.TokenUsage(
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens,
                    totalTokens: usage.totalTokens
                )
            }
        )
    }

    func parseStreamEvent(_ line: String) -> StreamEvent? {
        // Skip empty lines and comments
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return nil }

        // Handle SSE format
        guard trimmed.hasPrefix("data: ") else { return nil }
        let jsonString = String(trimmed.dropFirst(6))

        // Check for stream end
        if jsonString == "[DONE]" {
            return .done(finishReason: .stop, usage: nil)
        }

        // Parse JSON
        guard let data = jsonString.data(using: .utf8) else { return nil }

        do {
            let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
            guard let choice = chunk.choices.first else { return nil }

            // Check for finish reason
            if let finishReason = choice.finishReason {
                return .done(
                    finishReason: parseFinishReason(finishReason),
                    usage: chunk.usage.map { usage in
                        ChatResponse.TokenUsage(
                            promptTokens: usage.promptTokens,
                            completionTokens: usage.completionTokens,
                            totalTokens: usage.totalTokens
                        )
                    }
                )
            }

            // Parse delta
            if let delta = choice.delta {
                // Text content
                if let content = delta.content, !content.isEmpty {
                    return .textDelta(content)
                }

                // Tool calls
                if let toolCalls = delta.toolCalls, let toolCall = toolCalls.first {
                    return .toolCallDelta(
                        index: toolCall.index ?? 0,
                        id: toolCall.id,
                        name: toolCall.function?.name,
                        arguments: toolCall.function?.arguments
                    )
                }
            }

            return nil
        } catch {
            Self.logger.warning("Failed to parse stream chunk: \(error.localizedDescription)")
            return nil
        }
    }

    private func parseFinishReason(_ reason: String?) -> ChatResponse.FinishReason {
        switch reason {
        case "stop": return .stop
        case "tool_calls", "function_call": return .toolUse
        case "length": return .length
        case "content_filter": return .contentFilter
        default: return .unknown
        }
    }

    // MARK: - Health Check

    func checkHealth() async -> Result<ProviderHealthStatus, HTTPProviderError> {
        let startTime = Date()

        // Try to list models as a health check
        let url = endpoint.baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            try applyAuthentication(to: &request)
        } catch {
            return .failure(.keychainError(error.localizedDescription))
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let latency = Date().timeIntervalSince(startTime) * 1000

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse("Not an HTTP response"))
            }

            if httpResponse.statusCode == 200 {
                // Try to parse models response for version info
                var version: String?
                if let modelsResponse = try? JSONDecoder().decode(ModelsResponse.self, from: data) {
                    version = modelsResponse.data.first?.id
                }

                return .success(ProviderHealthStatus(
                    isHealthy: true,
                    version: version,
                    latencyMs: latency,
                    message: nil
                ))
            } else if httpResponse.statusCode == 401 {
                return .failure(.authenticationFailed)
            } else {
                return .failure(.serverError(httpResponse.statusCode, nil))
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return .failure(.timeout)
            case .cannotConnectToHost, .networkConnectionLost:
                return .failure(.connectionFailed(error.localizedDescription))
            default:
                return .failure(.connectionFailed(error.localizedDescription))
            }
        } catch {
            return .failure(.connectionFailed(error.localizedDescription))
        }
    }

    func listModels() async -> [String]? {
        let url = endpoint.baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            try applyAuthentication(to: &request)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let modelsResponse = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return modelsResponse.data.map { $0.id }
        } catch {
            Self.logger.warning("Failed to list models: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - OpenAI API Types

private struct ChatCompletionRequest: Encodable, Sendable {
    let model: String
    let messages: [OpenAIMessage]
    let maxTokens: Int?
    let stream: Bool
    let tools: [OpenAITool]?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools
        case maxTokens = "max_tokens"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(tools, forKey: .tools)
    }
}

private struct OpenAIMessage: Codable {
    let role: String
    var content: MessageContentValue?
    var toolCalls: [OpenAIToolCall]?
    var toolCallId: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
}

private enum MessageContentValue: Codable {
    case string(String)
    case parts([ContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let parts = try? container.decode([ContentPart].self) {
            self = .parts(parts)
        } else {
            throw DecodingError.typeMismatch(
                MessageContentValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or array")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

private struct ContentPart: Codable {
    let type: String
    var text: String?
    var imageUrl: ImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageUrl = "image_url"
    }

    struct ImageURL: Codable {
        let url: String
    }
}

private struct OpenAIToolCall: Codable {
    let id: String?
    let type: String?
    let function: OpenAIFunction?
    let index: Int?
}

private struct OpenAIFunction: Codable {
    let name: String?
    let arguments: String?
}

private struct OpenAITool: Encodable {
    let type: String = "function"
    let function: FunctionDefinition

    struct FunctionDefinition: Encodable {
        let name: String
        let description: String
        let parameters: ParametersSchema
    }

    struct ParametersSchema: Encodable {
        let type: String
        let properties: [String: PropertySchema]
        let required: [String]
    }

    struct PropertySchema: Encodable {
        let type: String
        let description: String?
        let `enum`: [String]?
    }
}

private struct ChatCompletionResponse: Decodable {
    let id: String?
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Decodable {
        let message: OpenAIMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

private struct ChatCompletionChunk: Decodable {
    let id: String?
    let choices: [Choice]
    let usage: ChatCompletionResponse.Usage?

    struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let role: String?
        let content: String?
        let toolCalls: [OpenAIToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
        }
    }
}

private struct ModelsResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}

// MARK: - Conversion Extensions

private extension ChatMessage {
    func toOpenAI() -> OpenAIMessage {
        var message = OpenAIMessage(role: role.rawValue)

        // Convert content
        var textParts: [String] = []
        var toolCalls: [OpenAIToolCall] = []
        var toolResultId: String?
        var toolResultContent: String?

        for item in content {
            switch item {
            case .text(let text):
                textParts.append(text)
            case .toolUse(let id, let name, let arguments):
                toolCalls.append(OpenAIToolCall(
                    id: id,
                    type: "function",
                    function: OpenAIFunction(name: name, arguments: arguments),
                    index: toolCalls.count
                ))
            case .toolResult(let id, let resultContent, _):
                toolResultId = id
                toolResultContent = resultContent
            case .image:
                // Skip images for now
                break
            }
        }

        if role == .tool {
            message.toolCallId = toolResultId
            message.content = .string(toolResultContent ?? "")
        } else if !textParts.isEmpty {
            message.content = .string(textParts.joined(separator: "\n"))
        }

        if !toolCalls.isEmpty {
            message.toolCalls = toolCalls
        }

        return message
    }
}

private extension OpenAIMessage {
    func toChatMessage() -> ChatMessage {
        var contentItems: [MessageContent] = []

        // Parse text content
        if let content {
            switch content {
            case .string(let text):
                if !text.isEmpty {
                    contentItems.append(.text(text))
                }
            case .parts(let parts):
                for part in parts {
                    if let text = part.text {
                        contentItems.append(.text(text))
                    }
                }
            }
        }

        // Parse tool calls
        if let toolCalls {
            for toolCall in toolCalls {
                if let id = toolCall.id,
                   let name = toolCall.function?.name {
                    contentItems.append(.toolUse(
                        id: id,
                        name: name,
                        arguments: toolCall.function?.arguments ?? "{}"
                    ))
                }
            }
        }

        return ChatMessage(
            role: ChatRole(rawValue: role) ?? .assistant,
            content: contentItems
        )
    }
}

private extension ToolDefinition {
    func toOpenAI() -> OpenAITool {
        OpenAITool(
            function: OpenAITool.FunctionDefinition(
                name: name,
                description: description,
                parameters: OpenAITool.ParametersSchema(
                    type: parameters.type,
                    properties: parameters.properties.mapValues { prop in
                        OpenAITool.PropertySchema(
                            type: prop.type,
                            description: prop.description,
                            enum: prop.enumValues
                        )
                    },
                    required: parameters.required
                )
            )
        )
    }
}
