import Foundation

/// Unified status for agent runs across all layers (UI, coordinator, scheduler, worker).
/// Replaces: AgentRunPhase, AgentRunStatus, WorkerRunResult.Status
public enum AgentStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case idle       // Not running (coordinator/scheduler only)
    case queued     // Waiting to start
    case running    // Currently executing
    case succeeded  // Completed successfully
    case failed     // Completed with failure
    case canceled   // Stopped by user/system

    /// Terminal states that indicate the run is complete.
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .canceled:
            return true
        case .idle, .queued, .running:
            return false
        }
    }

    /// States that indicate the run is active (not terminal).
    public var isActive: Bool {
        !isTerminal
    }
}

// MARK: - Backward Compatibility

/// Typealias for gradual migration from AgentRunPhase.
public typealias AgentRunPhase = AgentStatus

/// Typealias for gradual migration from AgentRunStatus.
public typealias AgentRunStatus = AgentStatus
