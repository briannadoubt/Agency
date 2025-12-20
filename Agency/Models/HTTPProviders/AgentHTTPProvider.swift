import Foundation

/// Capabilities that an HTTP provider may support.
struct HTTPProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int

    /// Provider streams responses in real-time via SSE.
    static let streaming = HTTPProviderCapabilities(rawValue: 1 << 0)

    /// Provider supports tool/function calling.
    static let toolUse = HTTPProviderCapabilities(rawValue: 1 << 1)

    /// Provider supports vision/image inputs.
    static let vision = HTTPProviderCapabilities(rawValue: 1 << 2)

    /// Provider tracks API costs.
    static let costTracking = HTTPProviderCapabilities(rawValue: 1 << 3)

    /// Provider supports JSON mode output.
    static let jsonMode = HTTPProviderCapabilities(rawValue: 1 << 4)

    /// Provider supports system messages.
    static let systemMessages = HTTPProviderCapabilities(rawValue: 1 << 5)

    /// Provider is a local server (no API key required).
    static let local = HTTPProviderCapabilities(rawValue: 1 << 6)

    /// Common capability sets
    static let openAICompatible: HTTPProviderCapabilities = [.streaming, .toolUse, .systemMessages]
    static let localModel: HTTPProviderCapabilities = [.streaming, .toolUse, .systemMessages, .local]
}

/// Authentication method for HTTP providers.
enum HTTPProviderAuth: Sendable, Equatable, Codable {
    /// No authentication required (local servers).
    case none
    /// Bearer token in Authorization header.
    case bearer(keychain: String)
    /// API key in a custom header.
    case header(name: String, keychain: String)
    /// API key as query parameter.
    case query(name: String, keychain: String)
}

/// Configuration for an HTTP provider endpoint.
struct HTTPProviderEndpoint: Sendable, Equatable, Codable {
    /// Base URL for the API (e.g., "http://localhost:11434/v1").
    let baseURL: URL

    /// Model identifier (e.g., "llama3.2", "gpt-4").
    var model: String

    /// Maximum tokens to generate.
    var maxTokens: Int

    /// Authentication method.
    var auth: HTTPProviderAuth

    /// Request timeout in seconds.
    var timeout: TimeInterval

    init(
        baseURL: URL,
        model: String,
        maxTokens: Int = 4096,
        auth: HTTPProviderAuth = .none,
        timeout: TimeInterval = 120
    ) {
        self.baseURL = baseURL
        self.model = model
        self.maxTokens = maxTokens
        self.auth = auth
        self.timeout = timeout
    }
}

/// Protocol for HTTP-based model providers.
///
/// HTTP providers connect to model APIs (local or cloud) via HTTP requests,
/// unlike CLI providers which execute external command-line tools.
protocol AgentHTTPProvider: Sendable {
    /// Unique identifier for this provider (e.g., "ollama", "openai").
    var identifier: String { get }

    /// Human-readable display name (e.g., "Ollama", "OpenAI").
    var displayName: String { get }

    /// Agent flows this provider supports.
    var supportedFlows: Set<AgentFlow> { get }

    /// Capabilities this provider offers.
    var capabilities: HTTPProviderCapabilities { get }

    /// Endpoint configuration.
    var endpoint: HTTPProviderEndpoint { get }

    /// Builds the HTTP request for a chat completion.
    /// - Parameters:
    ///   - messages: The conversation messages.
    ///   - tools: Tool definitions to include.
    ///   - stream: Whether to request streaming response.
    /// - Returns: Configured URLRequest.
    func buildRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition]?,
        stream: Bool
    ) throws -> URLRequest

    /// Parses a complete (non-streaming) response.
    /// - Parameter data: Response data from the API.
    /// - Returns: Parsed chat response.
    func parseResponse(_ data: Data) throws -> ChatResponse

    /// Parses a single SSE event from a streaming response.
    /// - Parameter line: A single line from the SSE stream.
    /// - Returns: Parsed stream event, or nil if line should be skipped.
    func parseStreamEvent(_ line: String) -> StreamEvent?

    /// Checks if the endpoint is available.
    /// - Returns: Result indicating availability with optional version info.
    func checkHealth() async -> Result<ProviderHealthStatus, HTTPProviderError>

    /// Lists available models at this endpoint (if supported).
    /// - Returns: Array of model identifiers, or nil if not supported.
    func listModels() async -> [String]?

    /// Maximum number of tool use turns before stopping.
    var maxTurns: Int { get }
}

// MARK: - Default Implementations

extension AgentHTTPProvider {
    var maxTurns: Int { 50 }

    func listModels() async -> [String]? { nil }
}

// MARK: - Chat Message Types

/// Role in a chat conversation.
enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

/// Content types within a message.
enum MessageContent: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, arguments: String)
    case toolResult(id: String, content: String, isError: Bool)
    case image(data: Data, mimeType: String)
}

/// A message in a chat conversation.
struct ChatMessage: Sendable, Equatable {
    let role: ChatRole
    let content: [MessageContent]

    init(role: ChatRole, content: [MessageContent]) {
        self.role = role
        self.content = content
    }

    /// Convenience initializer for text-only messages.
    init(role: ChatRole, text: String) {
        self.role = role
        self.content = [.text(text)]
    }

    /// Convenience initializer for tool result messages.
    init(toolResult id: String, content: String, isError: Bool = false) {
        self.role = .tool
        self.content = [.toolResult(id: id, content: content, isError: isError)]
    }

    /// Extracts text content from the message.
    var textContent: String {
        content.compactMap { item in
            if case .text(let text) = item { return text }
            return nil
        }.joined(separator: "\n")
    }

    /// Extracts tool use items from the message.
    var toolUses: [(id: String, name: String, arguments: String)] {
        content.compactMap { item in
            if case .toolUse(let id, let name, let args) = item {
                return (id, name, args)
            }
            return nil
        }
    }
}

// MARK: - Tool Definitions

/// Definition of a tool that the model can call.
struct ToolDefinition: Sendable, Equatable {
    let name: String
    let description: String
    let parameters: ToolParameters

    struct ToolParameters: Sendable, Equatable {
        let type: String
        let properties: [String: PropertySchema]
        let required: [String]

        init(type: String = "object", properties: [String: PropertySchema], required: [String] = []) {
            self.type = type
            self.properties = properties
            self.required = required
        }
    }

    struct PropertySchema: Sendable, Equatable {
        let type: String
        let description: String?
        let enumValues: [String]?

        init(type: String, description: String? = nil, enumValues: [String]? = nil) {
            self.type = type
            self.description = description
            self.enumValues = enumValues
        }
    }
}

// MARK: - Response Types

/// Parsed response from a chat completion.
struct ChatResponse: Sendable, Equatable {
    let message: ChatMessage
    let finishReason: FinishReason
    let usage: TokenUsage?

    enum FinishReason: String, Sendable, Equatable {
        case stop
        case toolUse = "tool_calls"
        case length
        case contentFilter = "content_filter"
        case unknown
    }

    struct TokenUsage: Sendable, Equatable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
    }
}

/// Event from a streaming response.
enum StreamEvent: Sendable, Equatable {
    /// Text content delta.
    case textDelta(String)
    /// Tool call delta (may be partial).
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String?)
    /// Stream finished.
    case done(finishReason: ChatResponse.FinishReason, usage: ChatResponse.TokenUsage?)
    /// Error in stream.
    case error(String)
}

// MARK: - Health Status

/// Health check result for a provider.
struct ProviderHealthStatus: Sendable, Equatable {
    let isHealthy: Bool
    let version: String?
    let latencyMs: Double?
    let message: String?
}

// MARK: - Provider Errors

/// Errors specific to HTTP providers.
enum HTTPProviderError: LocalizedError, Equatable {
    case invalidURL(String)
    case connectionFailed(String)
    case authenticationFailed
    case rateLimited(retryAfter: Int?)
    case modelNotFound(String)
    case invalidResponse(String)
    case streamingError(String)
    case timeout
    case serverError(Int, String?)
    case unsupportedFeature(String)
    case keychainError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .authenticationFailed:
            return "Authentication failed. Check your API key."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry after \(seconds) seconds."
            }
            return "Rate limited. Please try again later."
        case .modelNotFound(let model):
            return "Model not found: \(model)"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        case .streamingError(let message):
            return "Streaming error: \(message)"
        case .timeout:
            return "Request timed out."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message ?? "Unknown error")"
        case .unsupportedFeature(let feature):
            return "Unsupported feature: \(feature)"
        case .keychainError(let message):
            return "Keychain error: \(message)"
        }
    }
}
