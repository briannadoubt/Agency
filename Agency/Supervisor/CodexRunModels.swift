import Foundation

/// Payload sent from the app to the supervisor when launching a worker.
/// Mirrors the structure described in `project/phase-5-agent-integration/agent-flow-mechanics.md`.
public struct CodexRunRequest: Codable, Sendable, Equatable {
    public let runID: UUID
    public let flow: String
    public let cardRelativePath: String
    public let projectBookmark: Data
    public let logDirectory: URL
    public let outputDirectory: URL
    public let allowNetwork: Bool
    public let cliArgs: [String]

    public init(runID: UUID,
                flow: String,
                cardRelativePath: String,
                projectBookmark: Data,
                logDirectory: URL,
                outputDirectory: URL,
                allowNetwork: Bool,
                cliArgs: [String]) {
        self.runID = runID
        self.flow = flow
        self.cardRelativePath = cardRelativePath
        self.projectBookmark = projectBookmark
        self.logDirectory = logDirectory
        self.outputDirectory = outputDirectory
        self.allowNetwork = allowNetwork
        self.cliArgs = cliArgs
    }
}

/// Result emitted by the worker when it finishes a run.
public struct WorkerRunResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case succeeded, failed, canceled }

    public let status: Status
    public let exitCode: Int32
    public let duration: TimeInterval
    public let bytesRead: Int64
    public let bytesWritten: Int64
    public let summary: String

    public init(status: Status,
                exitCode: Int32,
                duration: TimeInterval,
                bytesRead: Int64,
                bytesWritten: Int64,
                summary: String) {
        self.status = status
        self.exitCode = exitCode
        self.duration = duration
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.summary = summary
    }
}

/// Lightweight representation of an endpoint used to attach the app to a worker session.
/// This mirrors the system type but is defined here to keep the layer testable without the XPC runtime.
public struct WorkerEndpoint: Codable, Sendable, Equatable {
    public let runID: UUID
    public let bootstrapName: String

    public init(runID: UUID, bootstrapName: String) {
        self.runID = runID
        self.bootstrapName = bootstrapName
    }
}

/// Backoff policy shared between the scheduler and supervisor when retrying failed runs.
public struct WorkerBackoffPolicy: Sendable, Equatable {
    public let baseDelay: Duration
    public let multiplier: Double
    public let jitter: Double
    public let maxDelay: Duration
    public let maxRetries: Int

    public init(baseDelay: Duration = .seconds(30),
                multiplier: Double = 2.0,
                jitter: Double = 0.1,
                maxDelay: Duration = .seconds(300),
                maxRetries: Int = 5) {
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.jitter = jitter
        self.maxDelay = maxDelay
        self.maxRetries = maxRetries
    }

    public func delay(forFailureCount failures: Int) -> Duration {
        var generator = SystemRandomNumberGenerator()
        return delay(forFailureCount: failures, using: &generator)
    }

    public func delay<T: RandomNumberGenerator>(forFailureCount failures: Int,
                                                using generator: inout T) -> Duration {
        guard failures > 0 else { return .zero }
        let cappedFailures = min(failures - 1, maxRetries)
        let exponentialSeconds = Double(baseDelay.components.seconds) * pow(multiplier, Double(cappedFailures))
        let jitterRange = exponentialSeconds * jitter
        let jitterOffset = Double.random(in: -jitterRange...jitterRange, using: &generator)
        let candidateSeconds = exponentialSeconds + jitterOffset
        let clampedSeconds = min(max(0, candidateSeconds), Double(maxDelay.components.seconds))
        return .seconds(clampedSeconds)
    }
}

/// Errors surfaced by the supervisor/worker launch pipeline.
public enum CodexSupervisorError: Error, Equatable, LocalizedError {
    case registrationMissing(String)
    case workerBinaryMissing
    case workerLaunchFailed(String)
    case payloadEncodingFailed
    case capabilitiesMissing([String])

    public var errorDescription: String? {
        switch self {
        case .registrationMissing(let name):
            return "SMAppService plist \(name) is missing or could not be registered."
        case .workerBinaryMissing:
            return "Worker executable could not be located in the app bundle."
        case .workerLaunchFailed(let reason):
            return "Failed to launch worker: \(reason)."
        case .payloadEncodingFailed:
            return "Unable to encode worker payload."
        case .capabilitiesMissing(let missing):
            return "Required entitlements are missing: \(missing.joined(separator: ", "))."
        }
    }
}

extension CodexRunRequest {
    func updatingDirectories(logDirectory: URL, outputDirectory: URL) -> CodexRunRequest {
        CodexRunRequest(runID: runID,
                        flow: flow,
                        cardRelativePath: cardRelativePath,
                        projectBookmark: projectBookmark,
                        logDirectory: logDirectory,
                        outputDirectory: outputDirectory,
                        allowNetwork: allowNetwork,
                        cliArgs: cliArgs)
    }

    /// Resolves the project root URL from the security-scoped bookmark.
    /// Returns nil if the bookmark cannot be resolved.
    var resolvedProjectRoot: URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: projectBookmark,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else {
            return nil
        }
        // Start accessing security-scoped resource
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}
