import Foundation
import os.log

/// Registry for CLI providers, managing discovery and selection.
@MainActor @Observable
final class ProviderRegistry {
    private let logger = Logger(subsystem: "dev.agency.app", category: "ProviderRegistry")

    /// Shared instance for app-wide access.
    static let shared = ProviderRegistry()

    /// Registered providers by identifier.
    private var providers: [String: any AgentCLIProvider] = [:]

    /// Cached availability status for each provider.
    private var availabilityCache: [String: ProviderAvailability] = [:]

    /// When the availability cache was last refreshed.
    private var lastAvailabilityCheck: Date?

    private init() {
        // Register built-in providers
        registerBuiltInProviders()
    }

    // MARK: - Public API

    /// Registers a provider.
    func register(_ provider: any AgentCLIProvider) {
        providers[provider.identifier] = provider
        availabilityCache.removeValue(forKey: provider.identifier)
        logger.info("Registered provider: \(provider.identifier)")
    }

    /// Unregisters a provider.
    func unregister(identifier: String) {
        providers.removeValue(forKey: identifier)
        availabilityCache.removeValue(forKey: identifier)
        logger.info("Unregistered provider: \(identifier)")
    }

    /// Returns a provider by identifier.
    func provider(for identifier: String) -> (any AgentCLIProvider)? {
        providers[identifier]
    }

    /// Returns all registered providers.
    var registeredProviders: [any AgentCLIProvider] {
        Array(providers.values)
    }

    /// Returns providers that support a given flow.
    func providers(supporting flow: AgentFlow) -> [any AgentCLIProvider] {
        providers.values.filter { $0.supportedFlows.contains(flow) }
    }

    /// Returns the default provider for a given flow.
    func defaultProvider(for flow: AgentFlow) -> (any AgentCLIProvider)? {
        // Prefer Claude Code, fall back to first available
        if let claude = providers["claude-code"], claude.supportedFlows.contains(flow) {
            return claude
        }
        return providers(supporting: flow).first
    }

    /// Checks availability of all providers.
    func checkAvailability() async -> [String: ProviderAvailability] {
        var results: [String: ProviderAvailability] = [:]

        for (identifier, provider) in providers {
            let result = await provider.locator.locate(userOverride: nil)
            switch result {
            case .success(let location):
                results[identifier] = ProviderAvailability(
                    isAvailable: true,
                    path: location.path,
                    version: location.version,
                    error: nil
                )
            case .failure(let error):
                results[identifier] = ProviderAvailability(
                    isAvailable: false,
                    path: nil,
                    version: nil,
                    error: error.localizedDescription
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

    // MARK: - Private

    private func registerBuiltInProviders() {
        // Register Claude Code provider
        register(ClaudeCodeProvider())
    }
}

// MARK: - Provider Availability

/// Represents the availability status of a provider.
struct ProviderAvailability: Equatable, Sendable {
    /// Whether the provider's CLI is available.
    let isAvailable: Bool

    /// Path to the CLI binary (if found).
    let path: String?

    /// Version of the CLI (if available).
    let version: String?

    /// Error message (if not available).
    let error: String?
}

// MARK: - Provider Summary

extension ProviderRegistry {
    /// Summary of a provider for UI display.
    struct ProviderSummary: Identifiable, Sendable {
        let id: String
        let displayName: String
        let supportedFlows: Set<AgentFlow>
        let capabilities: ProviderCapabilities
        let isAvailable: Bool
        let version: String?
    }

    /// Returns summaries of all registered providers.
    var providerSummaries: [ProviderSummary] {
        providers.map { (identifier, provider) in
            let availability = availabilityCache[identifier]
            return ProviderSummary(
                id: identifier,
                displayName: provider.displayName,
                supportedFlows: provider.supportedFlows,
                capabilities: provider.capabilities,
                isAvailable: availability?.isAvailable ?? false,
                version: availability?.version
            )
        }
    }
}
