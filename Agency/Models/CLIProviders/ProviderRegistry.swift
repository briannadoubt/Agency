import Foundation
import os.log

/// Registry for CLI and HTTP providers, managing discovery and selection.
@MainActor @Observable
final class ProviderRegistry {
    private let logger = Logger(subsystem: "dev.agency.app", category: "ProviderRegistry")

    /// Shared instance for app-wide access.
    static let shared = ProviderRegistry()

    /// Registered CLI providers by identifier.
    private var cliProviders: [String: any AgentCLIProvider] = [:]

    /// Registered HTTP providers by identifier.
    private var httpProviders: [String: any AgentHTTPProvider] = [:]

    /// Cached availability status for each provider.
    private var availabilityCache: [String: ProviderAvailability] = [:]

    /// When the availability cache was last refreshed.
    private var lastAvailabilityCheck: Date?

    private init() {
        // Register built-in providers
        registerBuiltInProviders()
    }

    // MARK: - CLI Provider API

    /// Registers a CLI provider.
    func register(_ provider: any AgentCLIProvider) {
        cliProviders[provider.identifier] = provider
        availabilityCache.removeValue(forKey: provider.identifier)
        logger.info("Registered CLI provider: \(provider.identifier)")
    }

    /// Unregisters a CLI provider.
    func unregister(identifier: String) {
        cliProviders.removeValue(forKey: identifier)
        httpProviders.removeValue(forKey: identifier)
        availabilityCache.removeValue(forKey: identifier)
        logger.info("Unregistered provider: \(identifier)")
    }

    /// Returns a CLI provider by identifier.
    func provider(for identifier: String) -> (any AgentCLIProvider)? {
        cliProviders[identifier]
    }

    /// Returns all registered CLI providers.
    var registeredProviders: [any AgentCLIProvider] {
        Array(cliProviders.values)
    }

    /// Returns CLI providers that support a given flow.
    func providers(supporting flow: AgentFlow) -> [any AgentCLIProvider] {
        cliProviders.values.filter { $0.supportedFlows.contains(flow) }
    }

    /// Returns the default CLI provider for a given flow.
    func defaultProvider(for flow: AgentFlow) -> (any AgentCLIProvider)? {
        // Prefer Claude Code, fall back to first available
        if let claude = cliProviders["claude-code"], claude.supportedFlows.contains(flow) {
            return claude
        }
        return providers(supporting: flow).first
    }

    // MARK: - HTTP Provider API

    /// Registers an HTTP provider.
    func register(_ provider: any AgentHTTPProvider) {
        httpProviders[provider.identifier] = provider
        availabilityCache.removeValue(forKey: provider.identifier)
        logger.info("Registered HTTP provider: \(provider.identifier)")
    }

    /// Returns an HTTP provider by identifier.
    func httpProvider(for identifier: String) -> (any AgentHTTPProvider)? {
        httpProviders[identifier]
    }

    /// Returns all registered HTTP providers.
    var registeredHTTPProviders: [any AgentHTTPProvider] {
        Array(httpProviders.values)
    }

    /// Returns HTTP providers that support a given flow.
    func httpProviders(supporting flow: AgentFlow) -> [any AgentHTTPProvider] {
        httpProviders.values.filter { $0.supportedFlows.contains(flow) }
    }

    /// Returns the default HTTP provider for a given flow.
    func defaultHTTPProvider(for flow: AgentFlow) -> (any AgentHTTPProvider)? {
        // Prefer Ollama for local models, fall back to first available
        if let ollama = httpProviders["ollama"], ollama.supportedFlows.contains(flow) {
            return ollama
        }
        return httpProviders(supporting: flow).first
    }

    // MARK: - Unified Provider API

    /// Returns all provider identifiers (CLI + HTTP).
    var allProviderIdentifiers: [String] {
        Array(Set(cliProviders.keys).union(httpProviders.keys))
    }

    /// Returns all providers (CLI + HTTP) that support a given flow.
    func allProviders(supporting flow: AgentFlow) -> [UnifiedProviderInfo] {
        var results: [UnifiedProviderInfo] = []

        for provider in cliProviders.values where provider.supportedFlows.contains(flow) {
            results.append(UnifiedProviderInfo(
                identifier: provider.identifier,
                displayName: provider.displayName,
                type: .cli,
                supportedFlows: provider.supportedFlows,
                isAvailable: availabilityCache[provider.identifier]?.isAvailable ?? false
            ))
        }

        for provider in httpProviders.values where provider.supportedFlows.contains(flow) {
            results.append(UnifiedProviderInfo(
                identifier: provider.identifier,
                displayName: provider.displayName,
                type: .http,
                supportedFlows: provider.supportedFlows,
                isAvailable: availabilityCache[provider.identifier]?.isAvailable ?? false
            ))
        }

        return results.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Availability Checking

    /// Checks availability of all providers (CLI + HTTP).
    func checkAvailability() async -> [String: ProviderAvailability] {
        var results: [String: ProviderAvailability] = [:]

        // Check CLI providers
        for (identifier, provider) in cliProviders {
            let result = await provider.locator.locate(userOverride: nil)
            switch result {
            case .success(let location):
                results[identifier] = ProviderAvailability(
                    isAvailable: true,
                    path: location.path,
                    version: location.version,
                    error: nil,
                    type: .cli
                )
            case .failure(let error):
                results[identifier] = ProviderAvailability(
                    isAvailable: false,
                    path: nil,
                    version: nil,
                    error: error.localizedDescription,
                    type: .cli
                )
            }
        }

        // Check HTTP providers
        for (identifier, provider) in httpProviders {
            let healthResult = await provider.checkHealth()
            switch healthResult {
            case .success(let status):
                results[identifier] = ProviderAvailability(
                    isAvailable: status.isHealthy,
                    path: provider.endpoint.baseURL.absoluteString,
                    version: status.version,
                    error: status.isHealthy ? nil : status.message,
                    type: .http
                )
            case .failure(let error):
                results[identifier] = ProviderAvailability(
                    isAvailable: false,
                    path: provider.endpoint.baseURL.absoluteString,
                    version: nil,
                    error: error.localizedDescription,
                    type: .http
                )
            }
        }

        availabilityCache = results
        lastAvailabilityCheck = Date()
        return results
    }

    /// Returns cached availability for a provider.
    func availability(for identifier: String) -> ProviderAvailability? {
        availabilityCache[identifier]
    }

    /// Returns all cached availability statuses.
    var allAvailability: [String: ProviderAvailability] {
        availabilityCache
    }

    // MARK: - Auto-Discovery

    /// Attempts to auto-discover and register HTTP providers.
    /// Call this on app startup to register available local providers.
    func autoDiscoverProviders() async {
        logger.info("Auto-discovering HTTP providers...")

        // Try to detect Ollama
        if let ollama = await OllamaProvider.autoDetect() {
            register(ollama)
            logger.info("Auto-discovered Ollama provider")
        }

        // Load custom providers from settings
        await loadCustomProvidersFromSettings()
    }

    private func loadCustomProvidersFromSettings() async {
        guard let data = UserDefaults.standard.data(forKey: "HTTPCustomProviders"),
              let configs = try? JSONDecoder().decode([CustomProviderConfig].self, from: data) else {
            return
        }

        for config in configs {
            guard let url = URL(string: config.endpoint) else { continue }

            let auth: HTTPProviderAuth
            if config.requiresApiKey {
                auth = .bearer(keychain: config.identifier)
            } else {
                auth = .none
            }

            let endpoint = HTTPProviderEndpoint(
                baseURL: url,
                model: config.model,
                auth: auth
            )

            let provider = OpenAICompatibleProvider(
                identifier: config.identifier,
                displayName: config.name,
                endpoint: endpoint
            )

            register(provider)
            logger.info("Loaded custom HTTP provider: \(config.name)")
        }
    }

    // MARK: - Private

    private func registerBuiltInProviders() {
        // Register CLI providers
        register(ClaudeCodeProvider())

        // HTTP providers are auto-discovered asynchronously
    }
}

// MARK: - Provider Types

/// Type of provider (CLI or HTTP).
enum ProviderType: String, Sendable, Codable {
    case cli
    case http
}

/// Unified information about a provider for UI display.
struct UnifiedProviderInfo: Identifiable, Sendable {
    let identifier: String
    let displayName: String
    let type: ProviderType
    let supportedFlows: Set<AgentFlow>
    let isAvailable: Bool

    var id: String { identifier }
}

// MARK: - Provider Availability

/// Represents the availability status of a provider.
struct ProviderAvailability: Equatable, Sendable {
    /// Whether the provider is available.
    let isAvailable: Bool

    /// Path to the CLI binary or HTTP endpoint URL.
    let path: String?

    /// Version of the provider (if available).
    let version: String?

    /// Error message (if not available).
    let error: String?

    /// Type of provider.
    let type: ProviderType

    init(
        isAvailable: Bool,
        path: String?,
        version: String?,
        error: String?,
        type: ProviderType = .cli
    ) {
        self.isAvailable = isAvailable
        self.path = path
        self.version = version
        self.error = error
        self.type = type
    }
}

// MARK: - Provider Summary

extension ProviderRegistry {
    /// Summary of a provider for UI display.
    struct ProviderSummary: Identifiable, Sendable {
        let id: String
        let displayName: String
        let supportedFlows: Set<AgentFlow>
        let type: ProviderType
        let isAvailable: Bool
        let version: String?
        let endpoint: String?
    }

    /// Returns summaries of all registered CLI providers.
    var cliProviderSummaries: [ProviderSummary] {
        cliProviders.map { (identifier, provider) in
            let availability = availabilityCache[identifier]
            return ProviderSummary(
                id: identifier,
                displayName: provider.displayName,
                supportedFlows: provider.supportedFlows,
                type: .cli,
                isAvailable: availability?.isAvailable ?? false,
                version: availability?.version,
                endpoint: availability?.path
            )
        }
    }

    /// Returns summaries of all registered HTTP providers.
    var httpProviderSummaries: [ProviderSummary] {
        httpProviders.map { (identifier, provider) in
            let availability = availabilityCache[identifier]
            return ProviderSummary(
                id: identifier,
                displayName: provider.displayName,
                supportedFlows: provider.supportedFlows,
                type: .http,
                isAvailable: availability?.isAvailable ?? false,
                version: availability?.version,
                endpoint: provider.endpoint.baseURL.absoluteString
            )
        }
    }

    /// Returns summaries of all registered providers (CLI + HTTP).
    var providerSummaries: [ProviderSummary] {
        cliProviderSummaries + httpProviderSummaries
    }
}
