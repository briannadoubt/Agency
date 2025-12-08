import Foundation
import os.log

/// Locates the Claude Code CLI binary on the system.
struct ClaudeCodeLocator {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "ClaudeCodeLocator")
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
        case bookmark = "Saved Location"
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

    /// Locate the Claude CLI, checking bookmark first, then user override, then common locations, then PATH.
    func locate(userOverridePath: String? = nil) async -> Result<LocatorResult, LocatorError> {
        Self.logger.info("Starting Claude CLI location...")
        Self.logger.info("User override path: \(userOverridePath ?? "nil")")

        // 1. Check security-scoped bookmark first (required for sandboxed apps)
        Self.logger.info("Checking for security-scoped bookmark...")
        if let bookmarkURL = await CLIBookmarkStore.shared.startAccessing() {
            let path = bookmarkURL.path
            Self.logger.info("Bookmark found: \(path)")
            // Skip isExecutable check for bookmarks - symlinks may not report as executable
            // Just try to get the version directly
            Self.logger.info("Bookmark path found, checking version...")
            let version = await getVersion(at: path)
            if version != nil {
                Self.logger.info("Bookmark version: \(version ?? "nil")")
                return .success(LocatorResult(path: path, version: version, source: .bookmark))
            } else {
                Self.logger.warning("Bookmark version check failed - CLI may not be accessible")
                await CLIBookmarkStore.shared.stopAccessing()
            }
        } else {
            Self.logger.info("No bookmark available")
        }

        // 2. Check user override
        if let override = userOverridePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expandedPath = (override as NSString).expandingTildeInPath
            Self.logger.info("Checking user override: \(expandedPath)")
            if fileManager.fileExists(atPath: expandedPath) {
                Self.logger.info("User override exists")
                if fileManager.isExecutableFile(atPath: expandedPath) {
                    Self.logger.info("User override is executable, checking version...")
                    let version = await getVersion(at: expandedPath)
                    Self.logger.info("User override version: \(version ?? "nil")")
                    return .success(LocatorResult(path: expandedPath, version: version, source: .userOverride))
                } else {
                    Self.logger.warning("User override is not executable")
                    return .failure(.notExecutable(expandedPath))
                }
            } else {
                Self.logger.warning("User override does not exist")
            }
        }

        // 3. Check common installation locations (more reliable than PATH)
        Self.logger.info("Checking \(Self.commonPaths.count) common paths...")
        for path in Self.commonPaths {
            let expandedPath = (path as NSString).expandingTildeInPath
            Self.logger.info("Checking: \(expandedPath)")

            let exists = fileManager.fileExists(atPath: expandedPath)
            Self.logger.info("  exists: \(exists)")

            if exists {
                let isExecutable = fileManager.isExecutableFile(atPath: expandedPath)
                Self.logger.info("  isExecutable: \(isExecutable)")

                if isExecutable {
                    Self.logger.info("  Checking version...")
                    if let version = await getVersion(at: expandedPath) {
                        Self.logger.info("  SUCCESS! Version: \(version)")
                        return .success(LocatorResult(path: expandedPath, version: version, source: .commonLocation))
                    } else {
                        Self.logger.warning("  Version check failed (binary may be broken)")
                    }
                }
            }
        }

        // 4. Try PATH lookup via `which claude` as fallback
        Self.logger.info("Trying PATH lookup...")
        if let pathResult = await lookupInPath() {
            Self.logger.info("PATH lookup returned: \(pathResult)")
            // Verify it works
            if let version = await getVersion(at: pathResult) {
                Self.logger.info("PATH result works! Version: \(version)")
                return .success(LocatorResult(path: pathResult, version: version, source: .pathLookup))
            } else {
                Self.logger.warning("PATH result failed version check")
            }
        } else {
            Self.logger.info("PATH lookup returned nil")
        }

        Self.logger.error("Claude CLI not found after checking all locations")
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
        Self.logger.info("Running /usr/bin/which claude...")
        let output = await processRunner.run(command: "/usr/bin/which", arguments: ["claude"])
        Self.logger.info("which exit code: \(output.exitCode)")
        Self.logger.info("which stdout: \(output.stdout)")
        Self.logger.info("which stderr: \(output.stderr)")

        if output.exitCode == 0 {
            let rawPath = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            // Handle "claude: aliased to /path" format from zsh
            let path: String
            if rawPath.contains("aliased to ") {
                path = rawPath.components(separatedBy: "aliased to ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? rawPath
                Self.logger.info("Extracted path from alias: \(path)")
            } else {
                path = rawPath
            }
            let exists = fileManager.fileExists(atPath: path)
            Self.logger.info("Path '\(path)' exists: \(exists)")
            if !path.isEmpty, exists {
                return path
            }
        }
        return nil
    }

    private func getVersion(at path: String) async -> String? {
        Self.logger.info("Getting version for: \(path)")
        let output = await processRunner.run(command: path, arguments: ["--version"])
        Self.logger.info("Version check exit code: \(output.exitCode)")
        Self.logger.info("Version stdout: '\(output.stdout)'")
        Self.logger.info("Version stderr: '\(output.stderr)'")
        guard output.exitCode == 0 else {
            Self.logger.warning("Version check failed with exit code \(output.exitCode)")
            return nil
        }
        let version = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }
}

/// Simple process runner for CLI commands.
struct ProcessRunner: Sendable {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "ProcessRunner")

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
        Self.logger.info("ProcessRunner.run: \(command) \(arguments.joined(separator: " "))")

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
            Self.logger.info("Process started successfully")
        } catch {
            Self.logger.error("Process failed to start: \(error.localizedDescription)")
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
