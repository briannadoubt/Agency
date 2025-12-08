import Foundation
import Testing
@testable import Agency

@MainActor
struct ProviderRegistryTests {

    @Test func registersClaudeCodeProviderByDefault() {
        let registry = ProviderRegistry.shared

        let provider = registry.provider(for: "claude-code")
        #expect(provider != nil)
        #expect(provider?.displayName == "Claude Code")
    }

    @Test func registersAndUnregistersCustomProvider() {
        let registry = ProviderRegistry.shared
        let provider = TestProvider(identifier: "test-provider-\(UUID().uuidString)")

        registry.register(provider)
        #expect(registry.provider(for: provider.identifier) != nil)

        registry.unregister(identifier: provider.identifier)
        #expect(registry.provider(for: provider.identifier) == nil)
    }

    @Test func findsProvidersSupportingFlow() {
        let registry = ProviderRegistry.shared
        let uniqueID = UUID().uuidString
        let implementProvider = TestProvider(identifier: "impl-\(uniqueID)", flows: [.implement])
        let reviewProvider = TestProvider(identifier: "review-\(uniqueID)", flows: [.review])
        let allFlowProvider = TestProvider(identifier: "all-\(uniqueID)", flows: [.implement, .review, .research])

        registry.register(implementProvider)
        registry.register(reviewProvider)
        registry.register(allFlowProvider)
        defer {
            registry.unregister(identifier: implementProvider.identifier)
            registry.unregister(identifier: reviewProvider.identifier)
            registry.unregister(identifier: allFlowProvider.identifier)
        }

        // claude-code is always registered and supports implement, review, research, plan
        let implementProviders = registry.providers(supporting: .implement)
        #expect(implementProviders.count >= 2) // At least claude-code and our impl provider

        let reviewProviders = registry.providers(supporting: .review)
        #expect(reviewProviders.count >= 2)
    }

    @Test func defaultProviderForImplementIsClaudeCode() {
        let registry = ProviderRegistry.shared

        let defaultProvider = registry.defaultProvider(for: .implement)
        #expect(defaultProvider?.identifier == "claude-code")
    }

    @Test func registeredProvidersIncludesClaudeCode() {
        let registry = ProviderRegistry.shared

        let providers = registry.registeredProviders
        let hasClaudeCode = providers.contains { $0.identifier == "claude-code" }
        #expect(hasClaudeCode)
    }

    @Test func providerSummariesIncludesClaudeCode() {
        let registry = ProviderRegistry.shared

        let summaries = registry.providerSummaries
        let claudeSummary = summaries.first { $0.id == "claude-code" }

        #expect(claudeSummary != nil)
        #expect(claudeSummary?.displayName == "Claude Code")
        #expect(claudeSummary?.supportedFlows.contains(.implement) == true)
    }

    @Test func availabilityIsNilBeforeCheck() {
        let registry = ProviderRegistry.shared
        let uniqueID = UUID().uuidString
        let provider = TestProvider(identifier: "unchecked-\(uniqueID)")

        registry.register(provider)
        defer { registry.unregister(identifier: provider.identifier) }

        let availability = registry.availability(for: provider.identifier)
        #expect(availability == nil)
    }

    @Test func providerCapabilitiesOptionSetWorks() {
        let caps: ProviderCapabilities = [.streaming, .cancellation]

        #expect(caps.contains(.streaming))
        #expect(caps.contains(.cancellation))
        #expect(!caps.contains(.costTracking))
    }

    @Test func providerErrorDescriptions() {
        let cliNotFound = ProviderError.cliNotFound(provider: "TestCLI")
        #expect(cliNotFound.errorDescription?.contains("TestCLI") == true)
        #expect(cliNotFound.errorDescription?.contains("not found") == true)

        let apiKeyMissing = ProviderError.apiKeyMissing(provider: "TestAPI")
        #expect(apiKeyMissing.errorDescription?.contains("API key") == true)

        let unsupportedFlow = ProviderError.unsupportedFlow(provider: "TestProvider", flow: .plan)
        #expect(unsupportedFlow.errorDescription?.contains("plan") == true)
    }

    @Test func providerAvailabilityEquatable() {
        let avail1 = ProviderAvailability(
            isAvailable: true,
            path: "/usr/bin/test",
            version: "1.0.0",
            error: nil
        )

        let avail2 = ProviderAvailability(
            isAvailable: true,
            path: "/usr/bin/test",
            version: "1.0.0",
            error: nil
        )

        #expect(avail1 == avail2)
    }
}

// MARK: - Test Provider

private struct TestProvider: AgentCLIProvider {
    let identifier: String
    let displayName: String
    let supportedFlows: Set<AgentFlow>
    let capabilities: ProviderCapabilities

    var locator: any CLILocating { TestCLILocator() }
    var streamParser: any StreamParsing { TestStreamParser() }

    init(
        identifier: String,
        displayName: String = "Test Provider",
        flows: Set<AgentFlow> = [.implement],
        capabilities: ProviderCapabilities = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.supportedFlows = flows
        self.capabilities = capabilities
    }

    func buildArguments(for request: WorkerRunRequest, prompt: String) -> [String] {
        ["-p", prompt]
    }

    func buildEnvironment() throws -> [String: String] {
        [:]
    }
}

private struct TestCLILocator: CLILocating {
    let identifier = "test"
    let commonPaths: [String] = []

    func getVersion(at path: String) async -> String? {
        nil
    }
}

private struct TestStreamParser: StreamParsing {
    let identifier = "test"

    func parse(line: String) -> CLIStreamMessage? {
        nil
    }

    func toLogEvent(_ message: CLIStreamMessage) -> WorkerLogEvent? {
        nil
    }

    func estimateProgress(messageCount: Int) -> Double {
        0.5
    }
}
