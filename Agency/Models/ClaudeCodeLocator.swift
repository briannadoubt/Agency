import Foundation
import os.log
import Subprocess
import System

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

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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

    /// Locate the Claude CLI, checking user override first, then common locations, then PATH.
    func locate(userOverridePath: String? = nil) async -> Result<LocatorResult, LocatorError> {
        Self.logger.info("Starting Claude CLI location...")
        Self.logger.info("User override path: \(userOverridePath ?? "nil")")

        // 1. Check user override
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

        // 2. Check common installation locations (more reliable than PATH)
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

        // 3. Try PATH lookup via `which claude` as fallback
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
        do {
            let result = try await run(
                .path(FilePath("/usr/bin/which")),
                arguments: ["claude"],
                output: .string(limit: 4096),
                error: .string(limit: 4096)
            )

            let exitCode = exitCode(from: result.terminationStatus)
            let stdout = result.standardOutput ?? ""
            let stderr = result.standardError ?? ""
            Self.logger.info("which exit code: \(exitCode)")
            Self.logger.info("which stdout: \(stdout)")
            Self.logger.info("which stderr: \(stderr)")

            if result.terminationStatus.isSuccess {
                let rawPath = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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
        } catch {
            Self.logger.error("which command failed: \(error.localizedDescription)")
        }
        return nil
    }

    private func getVersion(at path: String) async -> String? {
        Self.logger.info("Getting version for: \(path)")
        do {
            let result = try await run(
                .path(FilePath(path)),
                arguments: ["--version"],
                output: .string(limit: 4096),
                error: .string(limit: 4096)
            )

            let exitCode = exitCode(from: result.terminationStatus)
            let stdout = result.standardOutput ?? ""
            let stderr = result.standardError ?? ""
            Self.logger.info("Version check exit code: \(exitCode)")
            Self.logger.info("Version stdout: '\(stdout)'")
            Self.logger.info("Version stderr: '\(stderr)'")

            guard result.terminationStatus.isSuccess else {
                Self.logger.warning("Version check failed with exit code \(exitCode)")
                return nil
            }
            let version = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return version.isEmpty ? nil : version
        } catch {
            Self.logger.error("Version check failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func exitCode(from status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let code):
            return code
        case .unhandledException(let code):
            return code
        }
    }
}

/// Simple process runner for CLI commands (used by settings view for connection test).
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

        // Use Foundation Process for now since Environment.Key init is package-private
        // This is only used for connection test in settings view
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        if let environment {
            // Merge with current environment
            var mergedEnv = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                mergedEnv[key] = value
            }
            process.environment = mergedEnv
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
