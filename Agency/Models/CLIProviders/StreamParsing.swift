import Foundation

/// Unified stream message type for all CLI providers.
enum CLIStreamMessage: Equatable, Sendable {
    /// Session or initialization message.
    case session(id: String, timestamp: Date?)

    /// Text output from the assistant.
    case text(String)

    /// Tool invocation.
    case toolUse(name: String, input: String?)

    /// Result from tool execution.
    case toolResult(output: String?, isError: Bool)

    /// System or status message.
    case system(String)

    /// Final result with completion status.
    case result(status: CLIRunStatus, durationMs: Double?, costUSD: Double?)

    /// Progress update with percentage (0-1).
    case progress(Double, message: String?)

    /// Unknown or unrecognized message.
    case unknown
}

/// Completion status for CLI runs.
enum CLIRunStatus: String, Equatable, Sendable {
    case success
    case failure
    case cancelled
    case timeout
    case unknown
}

/// Protocol for parsing CLI output streams.
protocol StreamParsing: Sendable {
    /// Identifier for this parser (matches the provider identifier).
    var identifier: String { get }

    /// Parses a single line of output from the CLI.
    /// - Parameter line: A single line of output (may be JSON, text, etc.).
    /// - Returns: Parsed message, or nil if line should be skipped.
    func parse(line: String) -> CLIStreamMessage?

    /// Converts a stream message to a WorkerLogEvent for UI display.
    /// - Parameter message: The parsed stream message.
    /// - Returns: WorkerLogEvent, or nil if message shouldn't be shown in logs.
    func toLogEvent(_ message: CLIStreamMessage) -> WorkerLogEvent?

    /// Estimates progress based on message count (for CLIs without native progress).
    /// - Parameter messageCount: Number of messages received so far.
    /// - Returns: Estimated progress (0-1).
    func estimateProgress(messageCount: Int) -> Double
}

// MARK: - Default Implementation

extension StreamParsing {
    func estimateProgress(messageCount: Int) -> Double {
        // Default heuristic: assume ~20 messages for a typical task
        return min(0.1 + Double(messageCount) * 0.04, 0.9)
    }

    func toLogEvent(_ message: CLIStreamMessage) -> WorkerLogEvent? {
        switch message {
        case .session(let id, _):
            return .log("Session started: \(id)")

        case .text(let text):
            guard !text.isEmpty else { return nil }
            return .log(text)

        case .toolUse(let name, let input):
            if let input, !input.isEmpty {
                return .log("[\(name)] \(input.prefix(200))")
            }
            return .log("[\(name)] invoked")

        case .toolResult(let output, let isError):
            if isError {
                return .log("Error: \(output ?? "unknown error")")
            }
            if let output, !output.isEmpty {
                let truncated = output.count > 500 ? String(output.prefix(500)) + "..." : output
                return .log(truncated)
            }
            return nil

        case .system(let message):
            return .log(message)

        case .result(let status, _, let costUSD):
            var summary = "Completed: \(status.rawValue)"
            if let cost = costUSD {
                summary += String(format: " ($%.4f)", cost)
            }
            return .log(summary)

        case .progress(let value, let message):
            return .progress(value, message: message)

        case .unknown:
            return nil
        }
    }
}

// MARK: - Claude Stream Parser Adapter

/// Adapter that makes ClaudeStreamParser conform to StreamParsing.
struct ClaudeStreamParserAdapter: StreamParsing {
    let identifier = "claude-code"
    private let parser = ClaudeStreamParser()

    func parse(line: String) -> CLIStreamMessage? {
        guard let message = parser.parse(line: line) else { return nil }
        return convert(message)
    }

    func toLogEvent(_ message: CLIStreamMessage) -> WorkerLogEvent? {
        // Use default implementation
        switch message {
        case .session(let id, _):
            return .log("Session started: \(id)")

        case .text(let text):
            guard !text.isEmpty else { return nil }
            return .log(text)

        case .toolUse(let name, let input):
            if let input, !input.isEmpty {
                return .log("[\(name)] \(input.prefix(200))")
            }
            return .log("[\(name)] invoked")

        case .toolResult(let output, let isError):
            if isError {
                return .log("Error: \(output ?? "unknown error")")
            }
            if let output, !output.isEmpty {
                let truncated = output.count > 500 ? String(output.prefix(500)) + "..." : output
                return .log(truncated)
            }
            return nil

        case .system(let message):
            return .log(message)

        case .result(let status, _, let costUSD):
            var summary = "Claude Code \(status.rawValue)"
            if let cost = costUSD {
                summary += String(format: " ($%.4f)", cost)
            }
            return .log(summary)

        case .progress(let value, let message):
            return .progress(value, message: message)

        case .unknown:
            return nil
        }
    }

    private func convert(_ message: ClaudeStreamMessage) -> CLIStreamMessage {
        switch message {
        case .initSession(let sessionID, let timestamp):
            return .session(id: sessionID, timestamp: timestamp)

        case .assistantText(let text):
            return .text(text)

        case .toolUse(let name, let input):
            let inputStr = input.flatMap { dict -> String? in
                if let command = dict["command"] as? String {
                    return command
                }
                return nil
            }
            return .toolUse(name: name, input: inputStr)

        case .toolResult(_, let output, let isError):
            return .toolResult(output: output, isError: isError)

        case .system(let message):
            return .system(message)

        case .result(let status, let durationMs, let costUSD):
            let convertedStatus: CLIRunStatus
            switch status {
            case .success: convertedStatus = .success
            case .failure: convertedStatus = .failure
            case .cancelled: convertedStatus = .cancelled
            case .timeout: convertedStatus = .timeout
            case .unknown: convertedStatus = .unknown
            }
            return .result(status: convertedStatus, durationMs: durationMs, costUSD: costUSD)

        case .unknown:
            return .unknown
        }
    }
}
