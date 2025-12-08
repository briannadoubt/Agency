import Foundation
import os.log

/// Generates roadmap and architecture content using Claude Code CLI.
@MainActor
struct WizardAIGenerator {
    private static let logger = Logger(subsystem: "dev.agency.app", category: "WizardAIGenerator")
    private let locator: ClaudeCodeLocator

    init(locator: ClaudeCodeLocator = ClaudeCodeLocator()) {
        self.locator = locator
    }

    enum GenerationError: LocalizedError {
        case cliNotFound
        case apiKeyNotFound
        case generationFailed(String)
        case noOutput

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "Claude Code CLI not found. Configure it in Settings."
            case .apiKeyNotFound:
                return "Anthropic API key not configured. Add it in Settings."
            case .generationFailed(let message):
                return "Generation failed: \(message)"
            case .noOutput:
                return "No output was generated."
            }
        }
    }

    /// Generates a roadmap from the project goal.
    func generateRoadmap(projectName: String, goal: String) async throws -> String {
        let prompt = """
        Generate a project roadmap in Markdown format for the following project:

        Project Name: \(projectName)

        Project Goal:
        \(goal)

        Output a roadmap with the following structure:
        1. Start with a header: # Project: [name]
        2. Add Owner: system and Status: planning
        3. Add # Overview section with a brief summary
        4. Create 3-5 phases, each with:
           - Header: # Phase N: [Phase Name]
           - 2-4 tasks as checkboxes: - [ ] Task description

        Keep task descriptions concise but actionable. Focus on incremental delivery.

        Output ONLY the markdown content, no explanations or code blocks.
        """

        return try await runGeneration(prompt: prompt)
    }

    /// Generates architecture documentation from the roadmap.
    func generateArchitecture(projectName: String, roadmap: String) async throws -> String {
        let prompt = """
        Generate an architecture document in Markdown format based on this roadmap:

        \(roadmap)

        Output an architecture document with:
        1. Header: # Architecture: \(projectName)
        2. ## Overview - Brief technical summary
        3. ## Components - Key modules/services with bullet points
        4. ## Patterns - Design patterns and architectural decisions
        5. ## File Structure - Suggested folder organization (use code block)
        6. ## Dependencies - Key libraries/frameworks to consider

        Keep it concise and practical. Focus on guiding implementation.

        Output ONLY the markdown content, no explanations or wrapper code blocks.
        """

        return try await runGeneration(prompt: prompt)
    }

    // MARK: - Private

    private func runGeneration(prompt: String) async throws -> String {
        // Find CLI
        let override = ClaudeCodeSettings.shared.cliPathOverride
        let locateResult = await locator.locate(userOverridePath: override.isEmpty ? nil : override)

        let cliPath: String
        let isBookmark: Bool
        switch locateResult {
        case .success(let info):
            cliPath = info.path
            isBookmark = info.source == .bookmark
        case .failure:
            throw GenerationError.cliNotFound
        }

        // Ensure we stop accessing security-scoped resource when done
        defer {
            if isBookmark {
                Task {
                    await CLIBookmarkStore.shared.stopAccessing()
                }
            }
        }

        // Get API key
        guard let environment = ClaudeKeyManager.environmentWithKey() else {
            throw GenerationError.apiKeyNotFound
        }

        Self.logger.info("Running generation with Claude Code CLI")

        // Run Claude Code CLI
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "-p", prompt,
            "--output-format", "text",
            "--max-turns", "1"
        ]
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw GenerationError.generationFailed("Failed to start CLI: \(error.localizedDescription)")
        }

        // Wait with timeout
        let timeout: TimeInterval = 120
        let deadline = Date().addingTimeInterval(timeout)

        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }

        if process.isRunning {
            process.terminate()
            throw GenerationError.generationFailed("Generation timed out after \(Int(timeout)) seconds")
        }

        // Check result
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            Self.logger.error("Generation failed: \(stderr)")
            throw GenerationError.generationFailed(stderr.isEmpty ? "Exit code \(process.terminationStatus)" : stderr)
        }

        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw GenerationError.noOutput
        }

        Self.logger.info("Generation completed successfully")
        return output
    }
}
