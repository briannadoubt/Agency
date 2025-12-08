import Foundation
import os.log

/// The type of CLI backend to use for a worker run.
public enum WorkerBackend: String, Codable, Sendable {
    case xpc        // XPC-based agent workers
    case claudeCode // Claude Code CLI
}

/// Payload sent from the app to the supervisor when launching a worker.
/// Mirrors the structure described in `project/phase-5-agent-integration/agent-flow-mechanics.md`.
public struct WorkerRunRequest: Codable, Sendable, Equatable {
    public let runID: UUID
    public let flow: String
    public let cardRelativePath: String
    public let projectBookmark: Data
    public let logDirectory: URL
    public let outputDirectory: URL
    public let allowNetwork: Bool
    public let cliArgs: [String]
    public let backend: WorkerBackend

    public init(runID: UUID,
                flow: String,
                cardRelativePath: String,
                projectBookmark: Data,
                logDirectory: URL,
                outputDirectory: URL,
                allowNetwork: Bool,
                cliArgs: [String],
                backend: WorkerBackend = .xpc) {
        self.runID = runID
        self.flow = flow
        self.cardRelativePath = cardRelativePath
        self.projectBookmark = projectBookmark
        self.logDirectory = logDirectory
        self.outputDirectory = outputDirectory
        self.allowNetwork = allowNetwork
        self.cliArgs = cliArgs
        self.backend = backend
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

// Note: WorkerBackoffPolicy is now a typealias for BackoffPolicy in BackoffPolicy.swift

/// Errors surfaced by the supervisor/worker launch pipeline.
public enum AgentSupervisorError: Error, Equatable, LocalizedError {
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

extension WorkerRunRequest {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "WorkerRunRequest")

    func updatingDirectories(logDirectory: URL, outputDirectory: URL) -> WorkerRunRequest {
        WorkerRunRequest(runID: runID,
                        flow: flow,
                        cardRelativePath: cardRelativePath,
                        projectBookmark: projectBookmark,
                        logDirectory: logDirectory,
                        outputDirectory: outputDirectory,
                        allowNetwork: allowNetwork,
                        cliArgs: cliArgs,
                        backend: backend)
    }

    /// Resolves the project root URL from the security-scoped bookmark.
    /// Returns nil if the bookmark cannot be resolved.
    ///
    /// - Important: The caller is responsible for calling `stopAccessingSecurityScopedResource()`
    ///   on the returned URL when done. Use a `defer` block to ensure cleanup.
    var resolvedProjectRoot: URL? {
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: projectBookmark,
                          options: [.withSecurityScope],
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        } catch {
            Self.logger.warning("Failed to resolve project bookmark for run \(runID): \(error.localizedDescription)")
            return nil
        }
        if isStale {
            Self.logger.info("Project bookmark is stale for run \(runID); may need refresh")
        }
        // Start accessing security-scoped resource
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}
