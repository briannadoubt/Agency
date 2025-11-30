import Foundation
import Testing
@testable import Agency

@MainActor
struct ClaudeStreamParserTests {
    let parser = ClaudeStreamParser()

    // MARK: - Init Session Parsing

    @MainActor
    @Test func parsesInitSession() {
        let json = """
        {"type":"init","session_id":"abc123","timestamp":"2024-01-15T10:30:00Z"}
        """
        let message = parser.parse(line: json)

        guard case .initSession(let sessionID, let timestamp) = message else {
            Issue.record("Expected initSession message")
            return
        }

        #expect(sessionID == "abc123")
        #expect(timestamp != nil)
    }

    @MainActor
    @Test func parsesSessionTypeAsInit() {
        let json = """
        {"type":"session","session_id":"xyz789"}
        """
        let message = parser.parse(line: json)

        guard case .initSession(let sessionID, _) = message else {
            Issue.record("Expected initSession message")
            return
        }

        #expect(sessionID == "xyz789")
    }

    // MARK: - Assistant Text Parsing

    @MainActor
    @Test func parsesAssistantTextFromContentArray() {
        let json = """
        {"type":"message","role":"assistant","content":[{"type":"text","text":"Hello, world!"}]}
        """
        let message = parser.parse(line: json)

        guard case .assistantText(let text) = message else {
            Issue.record("Expected assistantText message")
            return
        }

        #expect(text == "Hello, world!")
    }

    @MainActor
    @Test func parsesAssistantTextFromContentString() {
        let json = """
        {"type":"message","content":"Simple text response"}
        """
        let message = parser.parse(line: json)

        guard case .assistantText(let text) = message else {
            Issue.record("Expected assistantText message")
            return
        }

        #expect(text == "Simple text response")
    }

    @MainActor
    @Test func parsesAssistantTextFromTextField() {
        let json = """
        {"type":"assistant","text":"Direct text field"}
        """
        let message = parser.parse(line: json)

        guard case .assistantText(let text) = message else {
            Issue.record("Expected assistantText message")
            return
        }

        #expect(text == "Direct text field")
    }

    @MainActor
    @Test func joinsMultipleTextBlocks() {
        let json = """
        {"type":"message","content":[{"type":"text","text":"Part 1"},{"type":"text","text":"Part 2"}]}
        """
        let message = parser.parse(line: json)

        guard case .assistantText(let text) = message else {
            Issue.record("Expected assistantText message")
            return
        }

        #expect(text.contains("Part 1"))
        #expect(text.contains("Part 2"))
    }

    // MARK: - Tool Use Parsing

    @MainActor
    @Test func parsesToolUse() {
        let json = """
        {"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}
        """
        let message = parser.parse(line: json)

        guard case .toolUse(let name, let input) = message else {
            Issue.record("Expected toolUse message")
            return
        }

        #expect(name == "Bash")
        #expect(input?["command"] as? String == "ls -la")
    }

    @MainActor
    @Test func parsesToolUseWithToolField() {
        let json = """
        {"type":"tool_use","tool":"Read"}
        """
        let message = parser.parse(line: json)

        guard case .toolUse(let name, _) = message else {
            Issue.record("Expected toolUse message")
            return
        }

        #expect(name == "Read")
    }

    // MARK: - Tool Result Parsing

    @MainActor
    @Test func parsesToolResult() {
        let json = """
        {"type":"tool_result","tool_use_id":"123","output":"file contents here"}
        """
        let message = parser.parse(line: json)

        guard case .toolResult(let toolUseID, let output, let isError) = message else {
            Issue.record("Expected toolResult message")
            return
        }

        #expect(toolUseID == "123")
        #expect(output == "file contents here")
        #expect(isError == false)
    }

    @MainActor
    @Test func parsesToolResultWithError() {
        let json = """
        {"type":"tool_result","output":"Command failed","is_error":true}
        """
        let message = parser.parse(line: json)

        guard case .toolResult(_, let output, let isError) = message else {
            Issue.record("Expected toolResult message")
            return
        }

        #expect(output == "Command failed")
        #expect(isError == true)
    }

    // MARK: - System Message Parsing

    @MainActor
    @Test func parsesSystemMessage() {
        let json = """
        {"type":"system","message":"Processing request..."}
        """
        let message = parser.parse(line: json)

        guard case .system(let text) = message else {
            Issue.record("Expected system message")
            return
        }

        #expect(text == "Processing request...")
    }

    // MARK: - Result Parsing

    @MainActor
    @Test func parsesSuccessResult() {
        let json = """
        {"type":"result","status":"success","duration_ms":1500,"total_cost_usd":0.0025}
        """
        let message = parser.parse(line: json)

        guard case .result(let status, let durationMs, let costUSD) = message else {
            Issue.record("Expected result message")
            return
        }

        #expect(status == .success)
        #expect(durationMs == 1500)
        #expect(costUSD == 0.0025)
    }

    @MainActor
    @Test func parsesFailureResult() {
        let json = """
        {"type":"result","status":"failure","duration_ms":500}
        """
        let message = parser.parse(line: json)

        guard case .result(let status, let durationMs, let costUSD) = message else {
            Issue.record("Expected result message")
            return
        }

        #expect(status == .failure)
        #expect(durationMs == 500)
        #expect(costUSD == nil)
    }

    @MainActor
    @Test func parsesCancelledResult() {
        let json = """
        {"type":"result","status":"cancelled"}
        """
        let message = parser.parse(line: json)

        guard case .result(let status, _, _) = message else {
            Issue.record("Expected result message")
            return
        }

        #expect(status == .cancelled)
    }

    @MainActor
    @Test func handlesUnknownStatus() {
        let json = """
        {"type":"result","status":"interrupted"}
        """
        let message = parser.parse(line: json)

        guard case .result(let status, _, _) = message else {
            Issue.record("Expected result message")
            return
        }

        #expect(status == .unknown)
    }

    // MARK: - Malformed JSON Handling

    @MainActor
    @Test func returnsNilForEmptyLine() {
        let message = parser.parse(line: "")
        #expect(message == nil)
    }

    @MainActor
    @Test func returnsNilForWhitespaceOnly() {
        let message = parser.parse(line: "   \n\t  ")
        #expect(message == nil)
    }

    @MainActor
    @Test func returnsNilForInvalidJSON() {
        let message = parser.parse(line: "not valid json")
        #expect(message == nil)
    }

    @MainActor
    @Test func returnsUnknownForUnrecognizedType() {
        let json = """
        {"type":"custom_event","payload":{"nested":"value"}}
        """
        let message = parser.parse(line: json)

        guard case .unknown = message else {
            Issue.record("Expected unknown message")
            return
        }
    }

    @MainActor
    @Test func extractsTextFromUnknownTypes() {
        let json = """
        {"type":"notification","text":"Important update"}
        """
        let message = parser.parse(line: json)

        guard case .assistantText(let text) = message else {
            Issue.record("Expected assistantText from text extraction")
            return
        }

        #expect(text == "Important update")
    }

    // MARK: - Batch Parsing

    @MainActor
    @Test func parsesMultipleLines() {
        let input = """
        {"type":"init","session_id":"test"}
        {"type":"message","text":"Hello"}
        {"type":"result","status":"success"}
        """

        let messages = parser.parseAll(string: input)

        #expect(messages.count == 3)
        guard case .initSession = messages[0] else {
            Issue.record("Expected initSession")
            return
        }
        guard case .assistantText = messages[1] else {
            Issue.record("Expected assistantText")
            return
        }
        guard case .result = messages[2] else {
            Issue.record("Expected result")
            return
        }
    }

    @MainActor
    @Test func skipsEmptyLinesInBatch() {
        let input = """
        {"type":"init","session_id":"test"}

        {"type":"result","status":"success"}
        """

        let messages = parser.parseAll(string: input)
        #expect(messages.count == 2)
    }

    // MARK: - WorkerLogEvent Mapping

    @MainActor
    @Test func mapsInitToLog() {
        let message = ClaudeStreamMessage.initSession(sessionID: "abc", timestamp: nil)
        let event = parser.toLogEvent(message)

        guard case .log(let text) = event else {
            Issue.record("Expected log event")
            return
        }

        #expect(text.contains("abc"))
    }

    @MainActor
    @Test func mapsAssistantTextToLog() {
        let message = ClaudeStreamMessage.assistantText("Hello from Claude")
        let event = parser.toLogEvent(message)

        guard case .log(let text) = event else {
            Issue.record("Expected log event")
            return
        }

        #expect(text == "Hello from Claude")
    }

    @MainActor
    @Test func mapsToolUseToLog() {
        let message = ClaudeStreamMessage.toolUse(name: "Bash", input: ["command": "pwd"])
        let event = parser.toLogEvent(message)

        guard case .log(let text) = event else {
            Issue.record("Expected log event")
            return
        }

        #expect(text.contains("Bash"))
        #expect(text.contains("pwd"))
    }

    @MainActor
    @Test func mapsSuccessResultToFinished() {
        let message = ClaudeStreamMessage.result(status: .success, durationMs: 2000, costUSD: 0.01)
        let event = parser.toLogEvent(message)

        guard case .finished(let result) = event else {
            Issue.record("Expected finished event")
            return
        }

        #expect(result.status == .succeeded)
        #expect(result.exitCode == 0)
        #expect(result.duration == 2.0)
        #expect(result.summary.contains("success"))
        #expect(result.summary.contains("$0.01"))
    }

    @MainActor
    @Test func mapsFailureResultToFinished() {
        let message = ClaudeStreamMessage.result(status: .failure, durationMs: 500, costUSD: nil)
        let event = parser.toLogEvent(message)

        guard case .finished(let result) = event else {
            Issue.record("Expected finished event")
            return
        }

        #expect(result.status == .failed)
        #expect(result.exitCode == 1)
    }

    @MainActor
    @Test func mapsCancelledResultToFinished() {
        let message = ClaudeStreamMessage.result(status: .cancelled, durationMs: nil, costUSD: nil)
        let event = parser.toLogEvent(message)

        guard case .finished(let result) = event else {
            Issue.record("Expected finished event")
            return
        }

        #expect(result.status == .canceled)
    }

    @MainActor
    @Test func returnsNilForUnknownMessage() {
        let message = ClaudeStreamMessage.unknown([:])
        let event = parser.toLogEvent(message)

        #expect(event == nil)
    }

    @MainActor
    @Test func truncatesLongToolOutput() {
        let longOutput = String(repeating: "x", count: 1000)
        let message = ClaudeStreamMessage.toolResult(toolUseID: nil, output: longOutput, isError: false)
        let event = parser.toLogEvent(message)

        guard case .log(let text) = event else {
            Issue.record("Expected log event")
            return
        }

        #expect(text.count < 1000)
        #expect(text.hasSuffix("..."))
    }

    // MARK: - Progress Estimation

    @MainActor
    @Test func estimatesProgressForEmptyMessages() {
        let progress = parser.estimateProgress(messages: [])
        #expect(progress == 0.05)
    }

    @MainActor
    @Test func estimatesProgressAfterInit() {
        let messages: [ClaudeStreamMessage] = [
            .initSession(sessionID: "test", timestamp: nil)
        ]
        let progress = parser.estimateProgress(messages: messages)
        #expect(progress >= 0.1)
    }

    @MainActor
    @Test func estimatesProgressIncrementsWithTools() {
        let messages: [ClaudeStreamMessage] = [
            .initSession(sessionID: "test", timestamp: nil),
            .toolUse(name: "Bash", input: nil),
            .toolResult(toolUseID: nil, output: nil, isError: false),
            .toolUse(name: "Read", input: nil),
            .toolResult(toolUseID: nil, output: nil, isError: false)
        ]
        let progress = parser.estimateProgress(messages: messages)
        #expect(progress > 0.1)
        #expect(progress < 1.0)
    }

    @MainActor
    @Test func progressIsOneAfterResult() {
        let messages: [ClaudeStreamMessage] = [
            .initSession(sessionID: "test", timestamp: nil),
            .result(status: .success, durationMs: nil, costUSD: nil)
        ]
        let progress = parser.estimateProgress(messages: messages)
        #expect(progress == 1.0)
    }
}
