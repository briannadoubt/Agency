import Foundation
import Observation

/// Manages Claude Code CLI settings persisted in UserDefaults.
@MainActor
@Observable
final class ClaudeCodeSettings {
    static let shared = ClaudeCodeSettings()

    private let defaults: UserDefaults
    private let locator: ClaudeCodeLocator
    private var refreshTask: Task<Void, Never>?

    private static let cliPathKey = "claudeCodeCLIPath"

    /// User-specified override path for the Claude CLI (empty means auto-detect).
    var cliPathOverride: String {
        didSet {
            defaults.set(cliPathOverride, forKey: Self.cliPathKey)
            // Cancel any pending refresh and start a new one
            refreshTask?.cancel()
            refreshTask = Task { await refreshStatus() }
        }
    }

    /// Current status of the Claude CLI.
    private(set) var status: CLIStatus = .checking

    /// Status of the Claude Code CLI.
    enum CLIStatus: Equatable, Sendable {
        case checking
        case available(path: String, version: String?, source: ClaudeCodeLocator.DiscoverySource)
        case notFound
        case error(String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        var path: String? {
            if case .available(let path, _, _) = self { return path }
            return nil
        }

        var version: String? {
            if case .available(_, let version, _) = self { return version }
            return nil
        }

        var displayMessage: String {
            switch self {
            case .checking:
                return "Checking for Claude CLI..."
            case .available(let path, let version, let source):
                if let version {
                    return "Found: \(path) (\(version)) via \(source.rawValue)"
                }
                return "Found: \(path) via \(source.rawValue)"
            case .notFound:
                return "Claude CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
            case .error(let message):
                return "Error: \(message)"
            }
        }
    }

    init(defaults: UserDefaults = .standard,
         locator: ClaudeCodeLocator = ClaudeCodeLocator()) {
        self.defaults = defaults
        self.locator = locator
        self.cliPathOverride = defaults.string(forKey: Self.cliPathKey) ?? ""
    }

    /// Refresh the CLI status by re-running detection.
    func refreshStatus() async {
        status = .checking

        let override = cliPathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await locator.locate(userOverridePath: override.isEmpty ? nil : override)

        // Don't update status if this task was cancelled (a newer refresh is running)
        guard !Task.isCancelled else { return }

        switch result {
        case .success(let locatorResult):
            status = .available(
                path: locatorResult.path,
                version: locatorResult.version,
                source: locatorResult.source
            )
        case .failure(let error):
            switch error {
            case .notFound:
                status = .notFound
            case .notExecutable(let path):
                status = .error("File at \(path) is not executable")
            case .versionCheckFailed(let reason):
                status = .error(reason)
            }
        }
    }

    /// Clear the user override and refresh status.
    func clearOverride() async {
        cliPathOverride = ""
        await refreshStatus()
    }
}
