import Foundation

/// Locates the Claude Code CLI binary on the system.
struct ClaudeCodeLocator {
    /// Common installation paths for the claude CLI.
    static let commonPaths: [String] = [
        "/opt/homebrew/bin/claude",  // Homebrew on Apple Silicon
        "/usr/local/bin/claude",     // Homebrew on Intel / npm global
        NSHomeDirectory() + "/.local/bin/claude",
        NSHomeDirectory() + "/.npm-global/bin/claude",
        "/usr/bin/claude"
    ]

    private let fileManager: FileManager
    private let processRunner: ProcessRunner

    init(fileManager: FileManager = .default,
         processRunner: ProcessRunner = ProcessRunner()) {
        self.fileManager = fileManager
        self.processRunner = processRunner
    }

    /// Result of locating the Claude CLI.
    struct LocatorResult: Sendable, Equatable {
        let path: String
        let version: String?
        let source: DiscoverySource
    }

    /// How the CLI was discovered.
    enum DiscoverySource: String, Sendable, Equatable {
        case userOverride = "User Override"
        case pathLookup = "PATH"
        case commonLocation = "Common Location"
    }

    /// Errors that can occur during CLI location.
    enum LocatorError: LocalizedError, Equatable {
        case notFound
        case notExecutable(String)
        case versionCheckFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Claude Code CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
            case .notExecutable(let path):
                return "Claude Code CLI at \(path) is not executable."
            case .versionCheckFailed(let reason):
                return "Claude Code CLI version check failed: \(reason)"
            }
        }
    }

    /// Locate the Claude CLI, checking user override first, then PATH, then common locations.
    func locate(userOverridePath: String? = nil) async -> Result<LocatorResult, LocatorError> {
        // 1. Check user override first
        if let override = userOverridePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expandedPath = (override as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expandedPath) {
                if fileManager.isExecutableFile(atPath: expandedPath) {
                    let version = await getVersion(at: expandedPath)
                    return .success(LocatorResult(path: expandedPath, version: version, source: .userOverride))
                } else {
                    return .failure(.notExecutable(expandedPath))
                }
            }
        }

        // 2. Check common installation locations first (more reliable)
        for path in Self.commonPaths {
            let expandedPath = (path as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expandedPath),
               fileManager.isExecutableFile(atPath: expandedPath) {
                // Verify it actually works by getting version
                if let version = await getVersion(at: expandedPath) {
                    return .success(LocatorResult(path: expandedPath, version: version, source: .commonLocation))
                }
            }
        }

        // 3. Try PATH lookup via `which claude` as fallback
        if let pathResult = await lookupInPath() {
            // Verify it works
            if let version = await getVersion(at: pathResult) {
                return .success(LocatorResult(path: pathResult, version: version, source: .pathLookup))
            }
        }

        return .failure(.notFound)
    }

    /// Verify that a specific path is a valid Claude CLI.
    func verify(path: String) async -> Result<LocatorResult, LocatorError> {
        let expandedPath = (path as NSString).expandingTildeInPath

        guard fileManager.fileExists(atPath: expandedPath) else {
            return .failure(.notFound)
        }

        guard fileManager.isExecutableFile(atPath: expandedPath) else {
            return .failure(.notExecutable(expandedPath))
        }

        let version = await getVersion(at: expandedPath)
        return .success(LocatorResult(path: expandedPath, version: version, source: .userOverride))
    }

    // MARK: - Private

    private func lookupInPath() async -> String? {
        // Try `which` first
        let output = await processRunner.run(command: "/usr/bin/which", arguments: ["claude"])
        if output.exitCode == 0 {
            let rawPath = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // Handle "claude: aliased to /path" format from zsh
            let path: String
            if rawPath.contains("aliased to ") {
                path = rawPath.components(separatedBy: "aliased to ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? rawPath
            } else {
                path = rawPath
            }
            if !path.isEmpty, fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func getVersion(at path: String) async -> String? {
        let output = await processRunner.run(command: path, arguments: ["--version"])
        guard output.exitCode == 0 else { return nil }
        let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }
}

/// Simple process runner for CLI commands.
struct ProcessRunner: Sendable {
    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Default timeout for process execution (10 seconds).
    static let defaultTimeout: Duration = .seconds(10)

    func run(command: String,
             arguments: [String] = [],
             environment: [String: String]? = nil,
             timeout: Duration = defaultTimeout) async -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return Output(stdout: "", stderr: error.localizedDescription, exitCode: 1)
        }

        // Use a Task to handle timeout with Swift Concurrency
        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning {
                process.terminate()
            }
        }

        // Read output (blocking, but process is already running)
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()
        timeoutTask.cancel()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return Output(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}
