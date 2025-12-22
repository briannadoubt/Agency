@preconcurrency import Foundation
import os.log

/// Ollama-specific provider that extends OpenAI-compatible with Ollama features.
///
/// Ollama supports both the OpenAI-compatible `/v1/chat/completions` endpoint
/// and its native `/api/chat` endpoint. This provider uses the OpenAI-compatible
/// endpoint for consistency while adding Ollama-specific features like model
/// listing and health checks.
struct OllamaProvider: AgentHTTPProvider, Sendable {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "OllamaProvider")

    /// Cache for health check results to reduce network calls.
    private actor HealthCache {
        private var cachedResult: (result: Result<ProviderHealthStatus, HTTPProviderError>, timestamp: Date)?
        private let cacheDuration: TimeInterval = 30 // Cache for 30 seconds

        func getCached() -> Result<ProviderHealthStatus, HTTPProviderError>? {
            guard let cached = cachedResult else { return nil }
            if Date().timeIntervalSince(cached.timestamp) < cacheDuration {
                return cached.result
            }
            return nil
        }

        func set(_ result: Result<ProviderHealthStatus, HTTPProviderError>) {
            cachedResult = (result, Date())
        }

        func invalidate() {
            cachedResult = nil
        }
    }

    private static let healthCache = HealthCache()

    /// Default Ollama endpoint.
    static let defaultBaseURL = URL(string: "http://localhost:11434/v1")!

    /// Default Ollama model.
    static let defaultModel = "llama3.2"

    let identifier = "ollama"
    let displayName = "Ollama"
    let supportedFlows: Set<AgentFlow> = [.implement, .review, .research, .plan]
    let capabilities: HTTPProviderCapabilities = .localModel
    let endpoint: HTTPProviderEndpoint
    let maxTurns: Int

    private let openAIBase: OpenAICompatibleProvider

    init(
        baseURL: URL = OllamaProvider.defaultBaseURL,
        model: String = OllamaProvider.defaultModel,
        maxTokens: Int = 4096,
        maxTurns: Int = 50
    ) {
        self.endpoint = HTTPProviderEndpoint(
            baseURL: baseURL,
            model: model,
            maxTokens: maxTokens,
            auth: .none, // Ollama doesn't require auth by default
            timeout: 300 // Longer timeout for local models
        )
        self.maxTurns = maxTurns

        // Delegate to OpenAI-compatible provider for core functionality
        self.openAIBase = OpenAICompatibleProvider(
            identifier: "ollama-openai",
            displayName: "Ollama (OpenAI)",
            endpoint: endpoint,
            supportedFlows: supportedFlows,
            capabilities: capabilities,
            maxTurns: maxTurns
        )
    }

    // MARK: - Request Building (Delegate to OpenAI-compatible)

    func buildRequest(
        messages: [ChatMessage],
        tools: [ToolDefinition]?,
        stream: Bool
    ) throws -> URLRequest {
        try openAIBase.buildRequest(messages: messages, tools: tools, stream: stream)
    }

    // MARK: - Response Parsing (Delegate to OpenAI-compatible)

    func parseResponse(_ data: Data) throws -> ChatResponse {
        try openAIBase.parseResponse(data)
    }

    func parseStreamEvent(_ line: String) -> StreamEvent? {
        openAIBase.parseStreamEvent(line)
    }

    // MARK: - Ollama-Specific Health Check

    func checkHealth() async -> Result<ProviderHealthStatus, HTTPProviderError> {
        // Check cache first
        if let cached = await Self.healthCache.getCached() {
            return cached
        }

        let result = await performHealthCheck()
        await Self.healthCache.set(result)
        return result
    }

    /// Invalidates the health check cache, forcing a fresh check on next call.
    func invalidateHealthCache() async {
        await Self.healthCache.invalidate()
    }

    private func performHealthCheck() async -> Result<ProviderHealthStatus, HTTPProviderError> {
        let startTime = Date()

        // Use Ollama's native /api/version endpoint for health check
        let versionURL = endpoint.baseURL
            .deletingLastPathComponent()
            .appendingPathComponent("api/version")

        var request = URLRequest(url: versionURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let latency = Date().timeIntervalSince(startTime) * 1000

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse("Not an HTTP response"))
            }

            if httpResponse.statusCode == 200 {
                var version: String?
                if let versionResponse = try? JSONDecoder().decode(OllamaVersionResponse.self, from: data) {
                    version = versionResponse.version
                }

                return .success(ProviderHealthStatus(
                    isHealthy: true,
                    version: version,
                    latencyMs: latency,
                    message: nil
                ))
            } else {
                return .failure(.serverError(httpResponse.statusCode, nil))
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                return .failure(.timeout)
            case .cannotConnectToHost:
                return .failure(.connectionFailed("Cannot connect to Ollama. Is it running?"))
            case .networkConnectionLost:
                return .failure(.connectionFailed("Network connection lost"))
            default:
                return .failure(.connectionFailed(error.localizedDescription))
            }
        } catch {
            return .failure(.connectionFailed(error.localizedDescription))
        }
    }

    // MARK: - Model Listing

    func listModels() async -> [String]? {
        // Use Ollama's native /api/tags endpoint
        let tagsURL = endpoint.baseURL
            .deletingLastPathComponent()
            .appendingPathComponent("api/tags")

        var request = URLRequest(url: tagsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let tagsResponse = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            return tagsResponse.models.map { $0.name }
        } catch {
            Self.logger.warning("Failed to list Ollama models: \(error.localizedDescription)")
            return nil
        }
    }

    /// Checks if a specific model is available.
    /// - Parameter model: The model name to check.
    /// - Returns: True if the model is available.
    func isModelAvailable(_ model: String) async -> Bool {
        guard let models = await listModels() else { return false }
        return models.contains { $0.hasPrefix(model) }
    }

    /// Pulls a model from the Ollama library.
    /// - Parameter model: The model name to pull.
    /// - Returns: True if the pull was successful.
    func pullModel(_ model: String) async -> Bool {
        let pullURL = endpoint.baseURL
            .deletingLastPathComponent()
            .appendingPathComponent("api/pull")

        var request = URLRequest(url: pullURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["name": model])
        request.timeoutInterval = 3600 // Long timeout for model downloads

        do {
            let (_, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            Self.logger.warning("Failed to pull model \(model): \(error.localizedDescription)")
            return false
        }
    }

    /// Returns model information including size and parameters.
    /// - Parameter model: The model name.
    /// - Returns: Model info if available.
    func modelInfo(_ model: String) async -> OllamaModelInfo? {
        let showURL = endpoint.baseURL
            .deletingLastPathComponent()
            .appendingPathComponent("api/show")

        var request = URLRequest(url: showURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["name": model])
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            return try JSONDecoder().decode(OllamaModelInfo.self, from: data)
        } catch {
            Self.logger.warning("Failed to get model info for \(model): \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Ollama API Types

private struct OllamaVersionResponse: Decodable {
    let version: String
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaModel]
}

private struct OllamaModel: Decodable {
    let name: String
    let modifiedAt: String?
    let size: Int64?

    enum CodingKeys: String, CodingKey {
        case name
        case modifiedAt = "modified_at"
        case size
    }
}

/// Public model info structure.
struct OllamaModelInfo: Decodable, Sendable {
    let modelfile: String?
    let parameters: String?
    let template: String?

    /// Extracts parameter count from the modelfile if available.
    var parameterCount: String? {
        guard let modelfile else { return nil }
        // Parse PARAMETER lines
        let lines = modelfile.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix("PARAMETER") {
                return String(line.dropFirst(10))
            }
        }
        return nil
    }
}

// MARK: - Provider Factory

extension OllamaProvider {
    /// Creates an Ollama provider with auto-detection.
    /// - Returns: Configured provider if Ollama is running, nil otherwise.
    static func autoDetect() async -> OllamaProvider? {
        let provider = OllamaProvider()
        let health = await provider.checkHealth()

        switch health {
        case .success(let status) where status.isHealthy:
            return provider
        default:
            return nil
        }
    }

    /// Creates providers for all available Ollama models.
    /// - Returns: Array of providers, one per model.
    static func allModels() async -> [OllamaProvider] {
        let baseProvider = OllamaProvider()

        guard let models = await baseProvider.listModels() else {
            return []
        }

        return models.map { model in
            OllamaProvider(model: model)
        }
    }
}
