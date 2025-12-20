import Foundation
import os.log

/// Bridge for executing tool calls from HTTP-based agents.
///
/// This bridge receives tool call requests from the agent loop and executes
/// them safely, returning structured results. It supports the same tools
/// as CLI agents: Read, Write, Edit, Bash, Glob, and Grep.
actor ToolExecutionBridge {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "ToolExecutionBridge")

    /// Result of a tool execution.
    struct ToolResult: Sendable {
        let output: String
        let isError: Bool

        static func success(_ output: String) -> ToolResult {
            ToolResult(output: output, isError: false)
        }

        static func error(_ message: String) -> ToolResult {
            ToolResult(output: message, isError: true)
        }
    }

    /// Configuration for tool execution.
    struct Configuration: Sendable {
        /// Maximum execution time for each tool.
        var timeout: TimeInterval = 30
        /// Maximum output size in bytes.
        var maxOutputSize: Int = 100_000
        /// Allowed tools (empty means all).
        var allowedTools: Set<String> = []
        /// Directories the agent can write to.
        var writableDirectories: [URL] = []

        static let `default` = Configuration()
    }

    private let configuration: Configuration
    private let fileManager: FileManager

    // Store allowed tools separately for nonisolated access
    private let _allowedTools: Set<String>

    init(
        configuration: Configuration = .default,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self._allowedTools = configuration.allowedTools
    }

    /// Returns the tool definitions for the model.
    nonisolated var availableTools: [ToolDefinition] {
        var tools: [ToolDefinition] = []

        // Read tool
        tools.append(ToolDefinition(
            name: "Read",
            description: "Read the contents of a file at the specified path.",
            parameters: ToolDefinition.ToolParameters(
                properties: [
                    "file_path": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "The absolute path to the file to read."
                    ),
                    "offset": ToolDefinition.PropertySchema(
                        type: "integer",
                        description: "Optional line number to start reading from (1-based)."
                    ),
                    "limit": ToolDefinition.PropertySchema(
                        type: "integer",
                        description: "Optional maximum number of lines to read."
                    )
                ],
                required: ["file_path"]
            )
        ))

        // Write tool
        tools.append(ToolDefinition(
            name: "Write",
            description: "Write content to a file at the specified path.",
            parameters: ToolDefinition.ToolParameters(
                properties: [
                    "file_path": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "The absolute path to the file to write."
                    ),
                    "content": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "The content to write to the file."
                    )
                ],
                required: ["file_path", "content"]
            )
        ))

        // Edit tool
        tools.append(ToolDefinition(
            name: "Edit",
            description: "Replace text in a file. The old_string must match exactly.",
            parameters: ToolDefinition.ToolParameters(
                properties: [
                    "file_path": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "The absolute path to the file to edit."
                    ),
                    "old_string": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "The exact text to find and replace."
                    ),
                    "new_string": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "The text to replace it with."
                    ),
                    "replace_all": ToolDefinition.PropertySchema(
                        type: "boolean",
                        description: "Whether to replace all occurrences (default: false)."
                    )
                ],
                required: ["file_path", "old_string", "new_string"]
            )
        ))

        // Bash tool
        tools.append(ToolDefinition(
            name: "Bash",
            description: "Execute a bash command. Use for git, npm, build commands, etc.",
            parameters: ToolDefinition.ToolParameters(
                properties: [
                    "command": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "The bash command to execute."
                    ),
                    "timeout": ToolDefinition.PropertySchema(
                        type: "integer",
                        description: "Optional timeout in milliseconds (max 600000)."
                    )
                ],
                required: ["command"]
            )
        ))

        // Glob tool
        tools.append(ToolDefinition(
            name: "Glob",
            description: "Find files matching a glob pattern.",
            parameters: ToolDefinition.ToolParameters(
                properties: [
                    "pattern": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "The glob pattern to match (e.g., '**/*.swift')."
                    ),
                    "path": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "Optional directory to search in."
                    )
                ],
                required: ["pattern"]
            )
        ))

        // Grep tool
        tools.append(ToolDefinition(
            name: "Grep",
            description: "Search for a pattern in files using regex.",
            parameters: ToolDefinition.ToolParameters(
                properties: [
                    "pattern": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "The regex pattern to search for."
                    ),
                    "path": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "Optional file or directory to search in."
                    ),
                    "glob": ToolDefinition.PropertySchema(
                        type: "string",
                        description: "Optional glob pattern to filter files."
                    )
                ],
                required: ["pattern"]
            )
        ))

        // Filter by allowed tools if configured
        if !_allowedTools.isEmpty {
            tools = tools.filter { _allowedTools.contains($0.name) }
        }

        return tools
    }

    /// Executes a tool call.
    /// - Parameters:
    ///   - toolName: The name of the tool to execute.
    ///   - arguments: JSON string of arguments.
    ///   - projectRoot: The project root directory.
    /// - Returns: The tool execution result.
    func execute(
        toolName: String,
        arguments: String,
        projectRoot: URL
    ) async -> ToolResult {
        // Check if tool is allowed
        if !configuration.allowedTools.isEmpty && !configuration.allowedTools.contains(toolName) {
            return .error("Tool '\(toolName)' is not allowed")
        }

        // Parse arguments
        guard let argsData = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
            return .error("Invalid JSON arguments: \(arguments)")
        }

        // Execute tool
        // TODO: Add timeout handling using Task.withTimeout when available
        return await executeToolWithArgs(toolName: toolName, args: args, projectRoot: projectRoot)
    }

    private func executeToolWithArgs(
        toolName: String,
        args: [String: Any],
        projectRoot: URL
    ) async -> ToolResult {
        switch toolName {
        case "Read":
            return await executeRead(args: args, projectRoot: projectRoot)
        case "Write":
            return await executeWrite(args: args, projectRoot: projectRoot)
        case "Edit":
            return await executeEdit(args: args, projectRoot: projectRoot)
        case "Bash":
            return await executeBash(args: args, projectRoot: projectRoot)
        case "Glob":
            return await executeGlob(args: args, projectRoot: projectRoot)
        case "Grep":
            return await executeGrep(args: args, projectRoot: projectRoot)
        default:
            return .error("Unknown tool: \(toolName)")
        }
    }

    // MARK: - Tool Implementations

    private func executeRead(args: [String: Any], projectRoot: URL) async -> ToolResult {
        guard let filePath = args["file_path"] as? String else {
            return .error("Missing required parameter: file_path")
        }

        let url = resolveFilePath(filePath, projectRoot: projectRoot)

        do {
            var content = try String(contentsOf: url, encoding: .utf8)

            // Apply offset and limit
            let lines = content.components(separatedBy: .newlines)
            let offset = (args["offset"] as? Int ?? 1) - 1
            let limit = args["limit"] as? Int ?? lines.count

            if offset > 0 || limit < lines.count {
                let endIndex = min(offset + limit, lines.count)
                let selectedLines = Array(lines[max(0, offset)..<endIndex])
                content = selectedLines.enumerated()
                    .map { "\(offset + $0.offset + 1)\t\($0.element)" }
                    .joined(separator: "\n")
            }

            // Truncate if too large
            if content.count > configuration.maxOutputSize {
                content = String(content.prefix(configuration.maxOutputSize)) + "\n... (truncated)"
            }

            return .success(content)
        } catch {
            return .error("Failed to read file: \(error.localizedDescription)")
        }
    }

    private func executeWrite(args: [String: Any], projectRoot: URL) async -> ToolResult {
        guard let filePath = args["file_path"] as? String else {
            return .error("Missing required parameter: file_path")
        }
        guard let content = args["content"] as? String else {
            return .error("Missing required parameter: content")
        }

        let url = resolveFilePath(filePath, projectRoot: projectRoot)

        // Check if path is writable
        if !isPathWritable(url, projectRoot: projectRoot) {
            return .error("Path is not writable: \(filePath)")
        }

        do {
            // Create parent directories if needed
            let parentDir = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

            try content.write(to: url, atomically: true, encoding: .utf8)
            return .success("File written successfully: \(url.path)")
        } catch {
            return .error("Failed to write file: \(error.localizedDescription)")
        }
    }

    private func executeEdit(args: [String: Any], projectRoot: URL) async -> ToolResult {
        guard let filePath = args["file_path"] as? String else {
            return .error("Missing required parameter: file_path")
        }
        guard let oldString = args["old_string"] as? String else {
            return .error("Missing required parameter: old_string")
        }
        guard let newString = args["new_string"] as? String else {
            return .error("Missing required parameter: new_string")
        }

        let url = resolveFilePath(filePath, projectRoot: projectRoot)
        let replaceAll = args["replace_all"] as? Bool ?? false

        // Check if path is writable
        if !isPathWritable(url, projectRoot: projectRoot) {
            return .error("Path is not writable: \(filePath)")
        }

        do {
            var content = try String(contentsOf: url, encoding: .utf8)

            if replaceAll {
                let count = content.components(separatedBy: oldString).count - 1
                if count == 0 {
                    return .error("old_string not found in file")
                }
                content = content.replacingOccurrences(of: oldString, with: newString)
                try content.write(to: url, atomically: true, encoding: .utf8)
                return .success("Replaced \(count) occurrence(s)")
            } else {
                guard let range = content.range(of: oldString) else {
                    return .error("old_string not found in file")
                }

                // Check for uniqueness
                if content.range(of: oldString, range: range.upperBound..<content.endIndex) != nil {
                    return .error("old_string is not unique in file. Use replace_all=true or provide more context.")
                }

                content.replaceSubrange(range, with: newString)
                try content.write(to: url, atomically: true, encoding: .utf8)
                return .success("Edit applied successfully")
            }
        } catch {
            return .error("Failed to edit file: \(error.localizedDescription)")
        }
    }

    private func executeBash(args: [String: Any], projectRoot: URL) async -> ToolResult {
        guard let command = args["command"] as? String else {
            return .error("Missing required parameter: command")
        }

        let timeout = min(args["timeout"] as? Int ?? 120_000, 600_000) // Max 10 minutes
        let timeoutSeconds = Double(timeout) / 1000.0

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = projectRoot

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()

            // Wait with timeout
            let waitTask = Task {
                process.waitUntilExit()
            }

            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                process.terminate()
            }

            await waitTask.value
            timeoutTask.cancel()

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

            let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

            var output = stdoutStr
            if !stderrStr.isEmpty {
                output += "\n[stderr]\n" + stderrStr
            }

            // Truncate if too large
            if output.count > configuration.maxOutputSize {
                output = String(output.prefix(configuration.maxOutputSize)) + "\n... (truncated)"
            }

            if process.terminationStatus != 0 {
                return .error("Command failed with exit code \(process.terminationStatus):\n\(output)")
            }

            return .success(output.isEmpty ? "(no output)" : output)
        } catch {
            return .error("Failed to execute command: \(error.localizedDescription)")
        }
    }

    private func executeGlob(args: [String: Any], projectRoot: URL) async -> ToolResult {
        guard let pattern = args["pattern"] as? String else {
            return .error("Missing required parameter: pattern")
        }

        let searchPath = args["path"] as? String
        let baseURL = searchPath.map { resolveFilePath($0, projectRoot: projectRoot) } ?? projectRoot

        do {
            let matches = try globFiles(pattern: pattern, in: baseURL)
            if matches.isEmpty {
                return .success("No files matched pattern: \(pattern)")
            }

            let output = matches.prefix(1000).joined(separator: "\n")
            if matches.count > 1000 {
                return .success(output + "\n... and \(matches.count - 1000) more files")
            }
            return .success(output)
        } catch {
            return .error("Glob failed: \(error.localizedDescription)")
        }
    }

    private func executeGrep(args: [String: Any], projectRoot: URL) async -> ToolResult {
        guard let pattern = args["pattern"] as? String else {
            return .error("Missing required parameter: pattern")
        }

        let searchPath = args["path"] as? String ?? projectRoot.path
        let glob = args["glob"] as? String

        var rgArgs = ["-n", "--color=never", pattern, searchPath]
        if let glob {
            rgArgs.insert(contentsOf: ["--glob", glob], at: 0)
        }

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["rg"] + rgArgs
            process.currentDirectoryURL = projectRoot

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            var output = String(data: stdoutData, encoding: .utf8) ?? ""

            // Truncate if too large
            if output.count > configuration.maxOutputSize {
                output = String(output.prefix(configuration.maxOutputSize)) + "\n... (truncated)"
            }

            if output.isEmpty {
                return .success("No matches found for pattern: \(pattern)")
            }

            return .success(output)
        } catch {
            return .error("Grep failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func resolveFilePath(_ path: String, projectRoot: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return projectRoot.appendingPathComponent(path)
    }

    private func isPathWritable(_ url: URL, projectRoot: URL) -> Bool {
        // Always allow writing within project root
        if url.path.hasPrefix(projectRoot.path) {
            return true
        }

        // Check configured writable directories
        for dir in configuration.writableDirectories {
            if url.path.hasPrefix(dir.path) {
                return true
            }
        }

        return false
    }

    private func globFiles(pattern: String, in directory: URL) throws -> [String] {
        // Use shell globbing via find
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "find . -path '\(pattern)' -type f 2>/dev/null | head -1000"]
        process.currentDirectoryURL = directory

        let stdout = Pipe()
        process.standardOutput = stdout

        try process.run()
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return output.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }
}
