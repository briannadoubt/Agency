import Foundation

/// Capabilities that a CLI provider may support.
struct ProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int

    /// Provider streams output in real-time.
    static let streaming = ProviderCapabilities(rawValue: 1 << 0)

    /// Provider tracks API costs.
    static let costTracking = ProviderCapabilities(rawValue: 1 << 1)

    /// Provider reports which tools it uses.
    static let toolUseReporting = ProviderCapabilities(rawValue: 1 << 2)

    /// Provider supports cancellation.
    static let cancellation = ProviderCapabilities(rawValue: 1 << 3)

    /// Provider supports session resumption.
    static let sessionResumption = ProviderCapabilities(rawValue: 1 << 4)

    /// Provider supports custom system prompts.
    static let customPrompts = ProviderCapabilities(rawValue: 1 << 5)
}

/// Protocol for agent CLI providers.
///
/// A provider encapsulates everything needed to run a specific agent CLI:
/// - Location discovery
/// - Argument building
/// - Environment configuration
/// - Output parsing
protocol AgentCLIProvider: Sendable {
    /// Unique identifier for this provider (e.g., "claude-code", "aider").
    var identifier: String { get }

    /// Human-readable display name (e.g., "Claude Code", "Aider").
    var displayName: String { get }

    /// Agent flows this provider supports.
    var supportedFlows: Set<AgentFlow> { get }

    /// Capabilities this provider offers.
    var capabilities: ProviderCapabilities { get }

    /// Locator for finding the CLI binary.
    var locator: any CLILocating { get }

    /// Parser for the CLI's output stream.
    var streamParser: any StreamParsing { get }

    /// Builds CLI arguments for a worker run request.
    /// - Parameters:
    ///   - request: The worker run request.
    ///   - prompt: The prompt to pass to the CLI.
    /// - Returns: Array of command-line arguments.
    func buildArguments(for request: WorkerRunRequest, prompt: String) -> [String]

    /// Builds the environment for the CLI process.
    /// - Returns: Dictionary of environment variables.
    /// - Throws: If required configuration is missing.
    func buildEnvironment() throws -> [String: String]

    /// Maximum number of tool use turns before stopping (if applicable).
    var maxTurns: Int { get }

    /// Tools the CLI is allowed to use (if applicable).
    var allowedTools: [String] { get }
}

// MARK: - Default Implementations

extension AgentCLIProvider {
    var maxTurns: Int { 50 }
    var allowedTools: [String] { [] }

    func buildEnvironment() throws -> [String: String] {
        // Default: inherit current environment
        ProcessInfo.processInfo.environment
    }
}

// MARK: - Provider Errors

enum ProviderError: LocalizedError, Equatable {
    case cliNotFound(provider: String)
    case apiKeyMissing(provider: String)
    case configurationMissing(provider: String, key: String)
    case unsupportedFlow(provider: String, flow: AgentFlow)

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let provider):
            return "\(provider) CLI not found. Please install and configure it."
        case .apiKeyMissing(let provider):
            return "API key for \(provider) is not configured."
        case .configurationMissing(let provider, let key):
            return "Missing configuration for \(provider): \(key)"
        case .unsupportedFlow(let provider, let flow):
            return "\(provider) does not support the \(flow.rawValue) flow."
        }
    }
}
