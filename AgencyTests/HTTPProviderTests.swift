import Testing
@testable import Agency
import Foundation

// MARK: - HTTP Provider Protocol Tests

@Suite("HTTP Provider Protocol")
@MainActor
struct HTTPProviderProtocolTests {

    @Test("HTTPProviderCapabilities supports expected values")
    func testCapabilities() {
        let streaming = HTTPProviderCapabilities.streaming
        let toolUse = HTTPProviderCapabilities.toolUse
        let combined: HTTPProviderCapabilities = [.streaming, .toolUse]

        #expect(streaming.rawValue == 1)
        #expect(toolUse.rawValue == 2)
        #expect(combined.contains(.streaming))
        #expect(combined.contains(.toolUse))
        #expect(!combined.contains(.vision))
    }

    @Test("OpenAI compatible capabilities include expected features")
    func testOpenAICompatibleCapabilities() {
        let caps = HTTPProviderCapabilities.openAICompatible

        #expect(caps.contains(.streaming))
        #expect(caps.contains(.toolUse))
        #expect(caps.contains(.systemMessages))
        #expect(!caps.contains(.local))
    }

    @Test("Local model capabilities include local flag")
    func testLocalModelCapabilities() {
        let caps = HTTPProviderCapabilities.localModel

        #expect(caps.contains(.streaming))
        #expect(caps.contains(.toolUse))
        #expect(caps.contains(.local))
    }
}

// MARK: - HTTP Provider Endpoint Tests

@Suite("HTTP Provider Endpoint")
@MainActor
struct HTTPProviderEndpointTests {

    @Test("Endpoint initializes with defaults")
    func testEndpointDefaults() {
        let url = URL(string: "http://localhost:8080/v1")!
        let endpoint = HTTPProviderEndpoint(baseURL: url, model: "test-model")

        #expect(endpoint.baseURL == url)
        #expect(endpoint.model == "test-model")
        #expect(endpoint.maxTokens == 4096)
        #expect(endpoint.auth == .none)
        #expect(endpoint.timeout == 120)
    }

    @Test("Endpoint supports bearer auth")
    func testBearerAuth() {
        let url = URL(string: "http://localhost:8080/v1")!
        let endpoint = HTTPProviderEndpoint(
            baseURL: url,
            model: "test-model",
            auth: .bearer(keychain: "test-key")
        )

        if case .bearer(let keychain) = endpoint.auth {
            #expect(keychain == "test-key")
        } else {
            Issue.record("Expected bearer auth")
        }
    }
}

// MARK: - Chat Message Tests

@Suite("Chat Message")
@MainActor
struct ChatMessageTests {

    @Test("Creates text message")
    func testTextMessage() {
        let message = ChatMessage(role: .user, text: "Hello")

        #expect(message.role == .user)
        #expect(message.textContent == "Hello")
        #expect(message.toolUses.isEmpty)
    }

    @Test("Creates tool use message")
    func testToolUseMessage() {
        let content: [MessageContent] = [
            .toolUse(id: "call-1", name: "Read", arguments: "{\"file_path\": \"/test.txt\"}")
        ]
        let message = ChatMessage(role: .assistant, content: content)

        #expect(message.role == .assistant)
        #expect(message.toolUses.count == 1)
        #expect(message.toolUses[0].name == "Read")
    }

    @Test("Creates tool result message")
    func testToolResultMessage() {
        let message = ChatMessage(toolResult: "call-1", content: "File contents here")

        #expect(message.role == .tool)
        #expect(message.content.count == 1)
        if case .toolResult(let id, let content, let isError) = message.content[0] {
            #expect(id == "call-1")
            #expect(content == "File contents here")
            #expect(!isError)
        } else {
            Issue.record("Expected tool result content")
        }
    }
}

// MARK: - Tool Definition Tests

@Suite("Tool Definition")
@MainActor
struct ToolDefinitionTests {

    @Test("Creates tool with parameters")
    func testToolDefinition() {
        let tool = ToolDefinition(
            name: "Read",
            description: "Read a file",
            parameters: ToolDefinition.ToolParameters(
                properties: [
                    "file_path": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "The path to read"
                    )
                ],
                required: ["file_path"]
            )
        )

        #expect(tool.name == "Read")
        #expect(tool.description == "Read a file")
        #expect(tool.parameters.properties.count == 1)
        #expect(tool.parameters.required == ["file_path"])
    }
}

// MARK: - HTTP Provider Error Tests

@Suite("HTTP Provider Error")
@MainActor
struct HTTPProviderErrorTests {

    @Test("Error descriptions are localized")
    func testErrorDescriptions() {
        let errors: [HTTPProviderError] = [
            .invalidURL("test"),
            .connectionFailed("test"),
            .authenticationFailed,
            .rateLimited(retryAfter: 60),
            .rateLimited(retryAfter: nil),
            .modelNotFound("test-model"),
            .timeout,
            .serverError(500, "Internal error")
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }
}

// MARK: - Provider Registry HTTP Extension Tests

@Suite("Provider Registry HTTP Support")
@MainActor
struct ProviderRegistryHTTPTests {

    @MainActor
    @Test("Registry can register HTTP providers")
    func testRegisterHTTPProvider() async {
        let registry = ProviderRegistry.shared

        // Create a mock provider
        let endpoint = HTTPProviderEndpoint(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            model: "test-model"
        )
        let provider = OpenAICompatibleProvider(
            identifier: "test-http",
            displayName: "Test HTTP",
            endpoint: endpoint
        )

        registry.register(provider)

        let retrieved = registry.httpProvider(for: "test-http")
        #expect(retrieved != nil)
        #expect(retrieved?.identifier == "test-http")

        // Cleanup
        registry.unregister(identifier: "test-http")
    }

    @MainActor
    @Test("Registry returns HTTP providers for flow")
    func testHTTPProvidersForFlow() async {
        let registry = ProviderRegistry.shared

        let endpoint = HTTPProviderEndpoint(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            model: "test-model"
        )
        let provider = OpenAICompatibleProvider(
            identifier: "test-flow",
            displayName: "Test Flow",
            endpoint: endpoint,
            supportedFlows: [.implement, .review]
        )

        registry.register(provider)

        let implementProviders = registry.httpProviders(supporting: .implement)
        #expect(implementProviders.contains(where: { $0.identifier == "test-flow" }))

        let planProviders = registry.httpProviders(supporting: .plan)
        #expect(!planProviders.contains(where: { $0.identifier == "test-flow" }))

        // Cleanup
        registry.unregister(identifier: "test-flow")
    }

    @MainActor
    @Test("Provider summaries include HTTP providers")
    func testProviderSummaries() async {
        let registry = ProviderRegistry.shared

        let endpoint = HTTPProviderEndpoint(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            model: "test-model"
        )
        let provider = OpenAICompatibleProvider(
            identifier: "test-summary",
            displayName: "Test Summary",
            endpoint: endpoint
        )

        registry.register(provider)

        let summaries = registry.providerSummaries
        let httpSummary = summaries.first(where: { $0.id == "test-summary" })

        #expect(httpSummary != nil)
        #expect(httpSummary?.type == .http)
        #expect(httpSummary?.endpoint == "http://localhost:11434/v1")

        // Cleanup
        registry.unregister(identifier: "test-summary")
    }
}

// MARK: - OpenAI Compatible Provider Tests

@Suite("OpenAI Compatible Provider")
@MainActor
struct OpenAICompatibleProviderTests {

    @Test("Provider has correct identifier and display name")
    func testProviderIdentity() {
        let endpoint = HTTPProviderEndpoint(
            baseURL: URL(string: "http://localhost:8080/v1")!,
            model: "llama3"
        )
        let provider = OpenAICompatibleProvider(
            identifier: "test-provider",
            displayName: "Test Provider",
            endpoint: endpoint
        )

        #expect(provider.identifier == "test-provider")
        #expect(provider.displayName == "Test Provider")
        #expect(provider.capabilities == .openAICompatible)
    }

    @Test("Provider builds request with correct structure")
    func testBuildRequest() throws {
        let endpoint = HTTPProviderEndpoint(
            baseURL: URL(string: "http://localhost:8080/v1")!,
            model: "llama3"
        )
        let provider = OpenAICompatibleProvider(
            identifier: "test",
            displayName: "Test",
            endpoint: endpoint
        )

        let messages = [
            ChatMessage(role: .system, text: "You are helpful"),
            ChatMessage(role: .user, text: "Hello")
        ]

        let request = try provider.buildRequest(messages: messages, tools: nil, stream: true)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path.hasSuffix("chat/completions") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("Provider parses SSE stream events")
    func testParseStreamEvent() {
        let endpoint = HTTPProviderEndpoint(
            baseURL: URL(string: "http://localhost:8080/v1")!,
            model: "llama3"
        )
        let provider = OpenAICompatibleProvider(
            identifier: "test",
            displayName: "Test",
            endpoint: endpoint
        )

        // Test text delta
        let textLine = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}"
        let textEvent = provider.parseStreamEvent(textLine)
        if case .textDelta(let text) = textEvent {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected text delta event")
        }

        // Test done event
        let doneLine = "data: [DONE]"
        let doneEvent = provider.parseStreamEvent(doneLine)
        if case .done(let reason, _) = doneEvent {
            #expect(reason == .stop)
        } else {
            Issue.record("Expected done event")
        }

        // Test empty line (should be nil)
        let emptyEvent = provider.parseStreamEvent("")
        #expect(emptyEvent == nil)

        // Test comment line (should be nil)
        let commentEvent = provider.parseStreamEvent(": keep-alive")
        #expect(commentEvent == nil)
    }
}

// MARK: - Ollama Provider Tests

@Suite("Ollama Provider")
@MainActor
struct OllamaProviderTests {

    @Test("Provider has correct defaults")
    func testDefaults() {
        let provider = OllamaProvider()

        #expect(provider.identifier == "ollama")
        #expect(provider.displayName == "Ollama")
        #expect(provider.endpoint.baseURL == OllamaProvider.defaultBaseURL)
        #expect(provider.endpoint.model == OllamaProvider.defaultModel)
        #expect(provider.capabilities.contains(.local))
    }

    @Test("Provider supports all flows")
    func testSupportedFlows() {
        let provider = OllamaProvider()

        #expect(provider.supportedFlows.contains(.implement))
        #expect(provider.supportedFlows.contains(.review))
        #expect(provider.supportedFlows.contains(.research))
        #expect(provider.supportedFlows.contains(.plan))
    }

    @Test("Provider can be created with custom settings")
    func testCustomSettings() {
        let customURL = URL(string: "http://192.168.1.100:11434/v1")!
        let provider = OllamaProvider(
            baseURL: customURL,
            model: "codellama",
            maxTokens: 8192
        )

        #expect(provider.endpoint.baseURL == customURL)
        #expect(provider.endpoint.model == "codellama")
        #expect(provider.endpoint.maxTokens == 8192)
    }
}

// MARK: - Tool Execution Bridge Tests

@Suite("Tool Execution Bridge")
@MainActor
struct ToolExecutionBridgeTests {

    @Test("Bridge provides tool definitions")
    func testAvailableTools() async {
        let bridge = ToolExecutionBridge()
        let tools = await bridge.availableTools

        #expect(tools.count > 0)

        let toolNames = tools.map { $0.name }
        #expect(toolNames.contains("Read"))
        #expect(toolNames.contains("Write"))
        #expect(toolNames.contains("Edit"))
        #expect(toolNames.contains("Bash"))
        #expect(toolNames.contains("Glob"))
        #expect(toolNames.contains("Grep"))
    }

    @Test("Bridge returns error for unknown tool")
    func testUnknownTool() async {
        let bridge = ToolExecutionBridge()
        let result = await bridge.execute(
            toolName: "UnknownTool",
            arguments: "{}",
            projectRoot: URL(fileURLWithPath: "/tmp")
        )

        #expect(result.isError)
        #expect(result.output.contains("Unknown tool"))
    }

    @Test("Bridge returns error for invalid JSON arguments")
    func testInvalidArguments() async {
        let bridge = ToolExecutionBridge()
        let result = await bridge.execute(
            toolName: "Read",
            arguments: "not valid json",
            projectRoot: URL(fileURLWithPath: "/tmp")
        )

        #expect(result.isError)
        #expect(result.output.contains("Invalid JSON"))
    }

    @Test("Bridge returns error for missing required parameter")
    func testMissingParameter() async {
        let bridge = ToolExecutionBridge()
        let result = await bridge.execute(
            toolName: "Read",
            arguments: "{}",
            projectRoot: URL(fileURLWithPath: "/tmp")
        )

        #expect(result.isError)
        #expect(result.output.contains("Missing required parameter"))
    }

    @Test("Bridge respects allowed tools configuration")
    func testAllowedTools() async {
        let config = ToolExecutionBridge.Configuration(
            allowedTools: ["Read", "Glob"]
        )
        let bridge = ToolExecutionBridge(configuration: config)

        // Read should work (allowed)
        let readResult = await bridge.execute(
            toolName: "Read",
            arguments: "{}",
            projectRoot: URL(fileURLWithPath: "/tmp")
        )
        // Will fail for missing param, not for being disallowed
        #expect(readResult.output.contains("Missing required parameter"))

        // Bash should be disallowed
        let bashResult = await bridge.execute(
            toolName: "Bash",
            arguments: "{\"command\": \"echo hello\"}",
            projectRoot: URL(fileURLWithPath: "/tmp")
        )
        #expect(bashResult.isError)
        #expect(bashResult.output.contains("not allowed"))
    }
}

// MARK: - HTTP Key Manager Tests

@Suite("HTTP Key Manager")
@MainActor
struct HTTPKeyManagerTests {

    @Test("Key masking hides middle of key")
    func testKeyMasking() {
        let key = "sk-test-1234567890abcdef"
        let masked = HTTPKeyManager.masked(key)

        #expect(masked.hasPrefix("sk-t"))
        #expect(masked.hasSuffix("cdef"))
        #expect(masked.contains("..."))
    }

    @Test("Short keys are fully masked")
    func testShortKeyMasking() {
        let shortKey = "short"
        let masked = HTTPKeyManager.masked(shortKey)

        #expect(masked == "****")
    }
}
