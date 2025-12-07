import Foundation

/// Unified outcome for agent run completion across all layers.
/// Replaces: AgentRunOutcome, AgentRunCompletion, WorkerRunResult.Status
public enum RunOutcome: Equatable, Sendable {
    case succeeded
    case failed(reason: String?)
    case canceled

    /// Convenience property for failed without reason (for AgentRunOutcome compatibility).
    public static var failed: RunOutcome { .failed(reason: nil) }

    /// Convert to the corresponding AgentStatus.
    public var status: AgentStatus {
        switch self {
        case .succeeded:
            return .succeeded
        case .failed:
            return .failed
        case .canceled:
            return .canceled
        }
    }

    /// Create from WorkerRunResult.Status.
    public static func from(workerStatus: WorkerRunResult.Status, summary: String?) -> RunOutcome {
        switch workerStatus {
        case .succeeded:
            return .succeeded
        case .failed:
            return .failed(reason: summary)
        case .canceled:
            return .canceled
        }
    }

    /// Create from WorkerRunResult.
    public static func from(result: WorkerRunResult) -> RunOutcome {
        from(workerStatus: result.status, summary: result.summary)
    }
}

// MARK: - Backward Compatibility Typealiases

/// Typealias for gradual migration from AgentRunOutcome.
public typealias AgentRunOutcome = RunOutcome

/// Typealias for gradual migration from AgentRunCompletion.
public typealias AgentRunCompletion = RunOutcome
