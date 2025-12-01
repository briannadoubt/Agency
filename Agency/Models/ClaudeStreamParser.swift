import Foundation

/// Represents the different message types in Claude Code's stream-json output.
enum ClaudeStreamMessage: Equatable {
    /// Session initialization with session ID and timestamp.
    case initSession(sessionID: String, timestamp: Date?)

    /// Assistant text message.
    case assistantText(String)

    /// Tool invocation request.
    case toolUse(name: String, input: [String: Any]?)

    /// Result from a tool invocation.
    case toolResult(toolUseID: String?, output: String?, isError: Bool)

    /// System message or status update.
    case system(String)

    /// Final result with status, duration, and cost.
    case result(status: ClaudeResultStatus, durationMs: Double?, costUSD: Double?)

    /// Unknown or partial message.
    case unknown([String: Any])

    static func == (lhs: ClaudeStreamMessage, rhs: ClaudeStreamMessage) -> Bool {
        switch (lhs, rhs) {
        case let (.initSession(lhsID, lhsTime), .initSession(rhsID, rhsTime)):
            return lhsID == rhsID && lhsTime == rhsTime
        case let (.assistantText(lhs), .assistantText(rhs)):
            return lhs == rhs
        case let (.toolUse(lhsName, _), .toolUse(rhsName, _)):
            return lhsName == rhsName
        case let (.toolResult(lhsID, lhsOut, lhsErr), .toolResult(rhsID, rhsOut, rhsErr)):
            return lhsID == rhsID && lhsOut == rhsOut && lhsErr == rhsErr
        case let (.system(lhs), .system(rhs)):
            return lhs == rhs
        case let (.result(lhsStat, lhsDur, lhsCost), .result(rhsStat, rhsDur, rhsCost)):
            return lhsStat == rhsStat && lhsDur == rhsDur && lhsCost == rhsCost
        case (.unknown, .unknown):
            return true
        default:
            return false
        }
    }
}

/// Status values for the final result message.
enum ClaudeResultStatus: String, Equatable {
    case success
    case failure
    case cancelled
    case timeout
    case unknown
}

/// Parses Claude Code's stream-json output format into structured messages.
struct ClaudeStreamParser {

    /// Parses a single line of stream-json output.
    /// - Parameter line: A single JSON line from Claude's stream output.
    /// - Returns: The parsed message, or nil if parsing fails.
    func parse(line: String) -> ClaudeStreamMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parse(json: json)
    }

    /// Parses a JSON dictionary into a ClaudeStreamMessage.
    func parse(json: [String: Any]) -> ClaudeStreamMessage? {
        let messageType = json["type"] as? String

        switch messageType {
        case "init", "session":
            return parseInit(json)
        case "message", "assistant":
            return parseMessage(json)
        case "tool_use":
            return parseToolUse(json)
        case "tool_result":
            return parseToolResult(json)
        case "system":
            return parseSystem(json)
        case "result":
            return parseResult(json)
        default:
            // Try to extract meaningful content from unknown types
            if let text = extractText(from: json) {
                return .assistantText(text)
            }
            return .unknown(json)
        }
    }

    /// Parses multiple lines of stream-json output.
    /// - Parameter data: Raw data containing newline-delimited JSON.
    /// - Returns: Array of parsed messages.
    func parseAll(data: Data) -> [ClaudeStreamMessage] {
        guard let string = String(data: data, encoding: .utf8) else { return [] }
        return parseAll(string: string)
    }

    /// Parses multiple lines of stream-json output.
    func parseAll(string: String) -> [ClaudeStreamMessage] {
        string.components(separatedBy: .newlines)
            .compactMap { parse(line: $0) }
    }

    // MARK: - Private Parsing Methods

    private func parseInit(_ json: [String: Any]) -> ClaudeStreamMessage {
        let sessionID = json["session_id"] as? String ?? ""
        var timestamp: Date?
        if let timestampString = json["timestamp"] as? String {
            timestamp = ISO8601DateFormatter().date(from: timestampString)
        }
        return .initSession(sessionID: sessionID, timestamp: timestamp)
    }

    private func parseMessage(_ json: [String: Any]) -> ClaudeStreamMessage {
        // Messages can have content as an array of content blocks
        if let content = json["content"] as? [[String: Any]] {
            let texts = content.compactMap { block -> String? in
                if block["type"] as? String == "text" {
                    return block["text"] as? String
                }
                return nil
            }
            if !texts.isEmpty {
                return .assistantText(texts.joined(separator: "\n"))
            }
        }

        // Or content can be a simple string
        if let text = json["content"] as? String {
            return .assistantText(text)
        }

        // Or there might be a text field directly
        if let text = json["text"] as? String {
            return .assistantText(text)
        }

        return .unknown(json)
    }

    private func parseToolUse(_ json: [String: Any]) -> ClaudeStreamMessage {
        let name = json["name"] as? String ?? json["tool"] as? String ?? "unknown"
        let input = json["input"] as? [String: Any]
        return .toolUse(name: name, input: input)
    }

    private func parseToolResult(_ json: [String: Any]) -> ClaudeStreamMessage {
        let toolUseID = json["tool_use_id"] as? String
        let output = json["output"] as? String ?? json["content"] as? String
        let isError = json["is_error"] as? Bool ?? false
        return .toolResult(toolUseID: toolUseID, output: output, isError: isError)
    }

    private func parseSystem(_ json: [String: Any]) -> ClaudeStreamMessage {
        let message = json["message"] as? String ?? json["text"] as? String ?? ""
        return .system(message)
    }

    private func parseResult(_ json: [String: Any]) -> ClaudeStreamMessage {
        let statusString = json["status"] as? String ?? "unknown"
        let status = ClaudeResultStatus(rawValue: statusString) ?? .unknown

        var durationMs: Double?
        if let dur = json["duration_ms"] as? Double {
            durationMs = dur
        } else if let dur = json["duration_ms"] as? Int {
            durationMs = Double(dur)
        }

        var costUSD: Double?
        if let cost = json["total_cost_usd"] as? Double {
            costUSD = cost
        } else if let cost = json["cost_usd"] as? Double {
            costUSD = cost
        }

        return .result(status: status, durationMs: durationMs, costUSD: costUSD)
    }

    private func extractText(from json: [String: Any]) -> String? {
        // Try various common text field names
        for key in ["text", "message", "content", "output", "data"] {
            if let text = json[key] as? String, !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

// MARK: - WorkerLogEvent Mapping

extension ClaudeStreamParser {

    /// Converts a ClaudeStreamMessage to a WorkerLogEvent for UI display.
    func toLogEvent(_ message: ClaudeStreamMessage) -> WorkerLogEvent? {
        switch message {
        case .initSession(let sessionID, _):
            return .log("Session started: \(sessionID)")

        case .assistantText(let text):
            return .log(text)

        case .toolUse(let name, let input):
            if let input, let command = input["command"] as? String {
                return .log("[\(name)] \(command)")
            }
            return .log("[\(name)] invoked")

        case .toolResult(_, let output, let isError):
            if isError {
                if let output {
                    return .log("Error: \(output)")
                }
                return .log("Tool returned error")
            }
            if let output, !output.isEmpty {
                // Truncate long outputs
                let truncated = output.count > 500 ? String(output.prefix(500)) + "..." : output
                return .log(truncated)
            }
            return nil

        case .system(let message):
            return .log(message)

        case .result(let status, _, let costUSD):
            // Don't emit .finished here - let the executor handle that
            // Just log the result summary
            var summary = "Claude Code \(status.rawValue)"
            if let cost = costUSD {
                summary += String(format: " ($%.4f)", cost)
            }
            return .log(summary)

        case .unknown:
            return nil
        }
    }

    /// Converts a stream of ClaudeStreamMessages to WorkerLogEvents.
    func toLogEvents(_ messages: [ClaudeStreamMessage]) -> [WorkerLogEvent] {
        messages.compactMap { toLogEvent($0) }
    }
}

// MARK: - Progress Estimation

extension ClaudeStreamParser {

    /// Estimates progress based on the messages received so far.
    /// This is heuristic-based since Claude doesn't provide explicit progress.
    func estimateProgress(messages: [ClaudeStreamMessage]) -> Double {
        var hasInit = false
        var toolCount = 0
        var hasResult = false

        for message in messages {
            switch message {
            case .initSession:
                hasInit = true
            case .toolUse, .toolResult:
                toolCount += 1
            case .result:
                hasResult = true
            default:
                break
            }
        }

        if hasResult {
            return 1.0
        }

        // Heuristic: assume typical task uses 3-10 tools
        // Map tool count to 0.1 - 0.9 range
        let baseProgress = hasInit ? 0.1 : 0.05
        let toolProgress = min(Double(toolCount) * 0.1, 0.8)

        return baseProgress + toolProgress
    }
}
