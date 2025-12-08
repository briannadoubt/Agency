import Foundation

/// CLI provider for Claude Code.
struct ClaudeCodeProvider: AgentCLIProvider {
    let identifier = "claude-code"
    let displayName = "Claude Code"

    let supportedFlows: Set<AgentFlow> = [.implement, .review, .research, .plan]

    let capabilities: ProviderCapabilities = [
        .streaming,
        .costTracking,
        .toolUseReporting,
        .cancellation,
        .customPrompts
    ]

    var locator: any CLILocating { ClaudeCodeCLILocator() }
    var streamParser: any StreamParsing { ClaudeStreamParserAdapter() }

    let maxTurns = 50
    let allowedTools = ["Bash", "Read", "Write", "Edit", "Glob", "Grep"]

    func buildArguments(for request: WorkerRunRequest, prompt: String) -> [String] {
        var args = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--max-turns", String(maxTurns)
        ]

        if !allowedTools.isEmpty {
            args.append(contentsOf: ["--allowedTools", allowedTools.joined(separator: ",")])
        }

        return args
    }

    func buildEnvironment() throws -> [String: String] {
        guard let env = ClaudeKeyManager.environmentWithKey() else {
            throw ProviderError.apiKeyMissing(provider: displayName)
        }
        return env
    }
}

// MARK: - Claude Code CLI Locator

/// Locator for the Claude Code CLI.
struct ClaudeCodeCLILocator: CLILocating {
    let identifier = "claude"

    let commonPaths: [String] = [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        NSHomeDirectory() + "/.local/bin/claude",
        NSHomeDirectory() + "/.npm-global/bin/claude",
        "/usr/bin/claude"
    ]

    func getVersion(at path: String) async -> String? {
        let runner = ProcessRunner()
        let output = await runner.run(command: path, arguments: ["--version"])
        guard output.exitCode == 0 else { return nil }
        let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }
}
