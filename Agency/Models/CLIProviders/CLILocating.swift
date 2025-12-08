import Foundation

/// Information about a located CLI binary.
struct CLILocation: Sendable, Equatable {
    /// Absolute path to the CLI executable.
    let path: String

    /// CLI version string, if available.
    let version: String?

    /// How the CLI was discovered.
    let source: CLIDiscoverySource
}

/// How a CLI binary was discovered.
enum CLIDiscoverySource: String, Sendable, Equatable {
    /// User explicitly configured the path.
    case userOverride = "User Override"

    /// Found via PATH environment variable.
    case pathLookup = "PATH"

    /// Found in a common installation location.
    case commonLocation = "Common Location"

    /// Bundled with the application.
    case bundled = "Bundled"
}

/// Errors that can occur during CLI location.
enum CLILocatorError: LocalizedError, Equatable, Sendable {
    /// CLI binary was not found.
    case notFound

    /// CLI binary exists but is not executable.
    case notExecutable(String)

    /// Version check failed.
    case versionCheckFailed(String)

    /// CLI binary failed validation.
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "CLI binary not found."
        case .notExecutable(let path):
            return "CLI at \(path) is not executable."
        case .versionCheckFailed(let reason):
            return "Version check failed: \(reason)"
        case .validationFailed(let reason):
            return "Validation failed: \(reason)"
        }
    }
}

/// Protocol for locating CLI binaries.
protocol CLILocating: Sendable {
    /// Identifier for this locator (matches the provider identifier).
    var identifier: String { get }

    /// Common installation paths to check.
    var commonPaths: [String] { get }

    /// Locates the CLI binary.
    /// - Parameter userOverride: Optional user-specified path to check first.
    /// - Returns: The location result or an error.
    func locate(userOverride: String?) async -> Result<CLILocation, CLILocatorError>

    /// Verifies that a specific path contains a valid CLI.
    /// - Parameter path: Path to verify.
    /// - Returns: The location result or an error.
    func verify(path: String) async -> Result<CLILocation, CLILocatorError>

    /// Gets the version of the CLI at the given path.
    /// - Parameter path: Path to the CLI binary.
    /// - Returns: Version string if available.
    func getVersion(at path: String) async -> String?
}

// MARK: - Default Implementation

extension CLILocating {
    func locate(userOverride: String?) async -> Result<CLILocation, CLILocatorError> {
        let fileManager = FileManager.default

        // 1. Check user override first
        if let override = userOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let expandedPath = (override as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expandedPath) {
                if fileManager.isExecutableFile(atPath: expandedPath) {
                    let version = await getVersion(at: expandedPath)
                    return .success(CLILocation(path: expandedPath, version: version, source: .userOverride))
                } else {
                    return .failure(.notExecutable(expandedPath))
                }
            }
        }

        // 2. Try PATH lookup
        if let pathResult = await lookupInPath() {
            let version = await getVersion(at: pathResult)
            return .success(CLILocation(path: pathResult, version: version, source: .pathLookup))
        }

        // 3. Check common installation locations
        for path in commonPaths {
            let expandedPath = (path as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expandedPath) {
                if fileManager.isExecutableFile(atPath: expandedPath) {
                    let version = await getVersion(at: expandedPath)
                    return .success(CLILocation(path: expandedPath, version: version, source: .commonLocation))
                }
            }
        }

        return .failure(.notFound)
    }

    func verify(path: String) async -> Result<CLILocation, CLILocatorError> {
        let fileManager = FileManager.default
        let expandedPath = (path as NSString).expandingTildeInPath

        guard fileManager.fileExists(atPath: expandedPath) else {
            return .failure(.notFound)
        }

        guard fileManager.isExecutableFile(atPath: expandedPath) else {
            return .failure(.notExecutable(expandedPath))
        }

        let version = await getVersion(at: expandedPath)
        return .success(CLILocation(path: expandedPath, version: version, source: .userOverride))
    }

    private func lookupInPath() async -> String? {
        let cliName = identifier
        let runner = ProcessRunner()
        let output = await runner.run(command: "/usr/bin/which", arguments: [cliName])
        guard output.exitCode == 0 else { return nil }
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }
}
