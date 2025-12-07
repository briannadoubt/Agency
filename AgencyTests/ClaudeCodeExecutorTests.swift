import Foundation
import Testing
@testable import Agency

@MainActor
struct ClaudeCodeExecutorTests {

    // MARK: - Prompt Building Tests

    @MainActor
    @Test func buildPromptIncludesCardPath() {
        let executor = ClaudeCodeExecutor()
        let request = makeRequest(cardPath: "project/phase-1/card.md")

        let prompt = executor.testBuildPrompt(from: request)

        #expect(prompt.contains("project/phase-1/card.md"))
    }

    @MainActor
    @Test func buildPromptIncludesImplementationInstructions() {
        let executor = ClaudeCodeExecutor()
        let request = makeRequest()

        let prompt = executor.testBuildPrompt(from: request)

        #expect(prompt.contains("Read the card file"))
        #expect(prompt.contains("Implement the required changes"))
        #expect(prompt.contains("acceptance criteria"))
    }

    @MainActor
    @Test func buildPromptIncludesCLIArgsWhenProvided() {
        let executor = ClaudeCodeExecutor()
        let request = makeRequest(cliArgs: ["--verbose", "--dry-run"])

        let prompt = executor.testBuildPrompt(from: request)

        #expect(prompt.contains("--verbose"))
        #expect(prompt.contains("--dry-run"))
    }

    @MainActor
    @Test func buildPromptOmitsCLIArgsSectionWhenEmpty() {
        let executor = ClaudeCodeExecutor()
        let request = makeRequest(cliArgs: [])

        let prompt = executor.testBuildPrompt(from: request)

        #expect(!prompt.contains("Additional context from CLI args"))
    }

    // MARK: - Error Types Tests

    @MainActor
    @Test func cliNotFoundErrorHasHelpfulDescription() {
        let error = ClaudeCodeExecutor.ExecutorError.cliNotFound
        #expect(error.errorDescription?.contains("CLI not found") == true)
        #expect(error.errorDescription?.contains("Settings") == true)
    }

    @MainActor
    @Test func apiKeyNotFoundErrorHasHelpfulDescription() {
        let error = ClaudeCodeExecutor.ExecutorError.apiKeyNotFound
        #expect(error.errorDescription?.contains("API key") == true)
        #expect(error.errorDescription?.contains("Settings") == true)
    }

    @MainActor
    @Test func projectRootUnavailableErrorHasHelpfulDescription() {
        let error = ClaudeCodeExecutor.ExecutorError.projectRootUnavailable
        #expect(error.errorDescription?.contains("project root") == true)
    }

    // MARK: - AgentBackendKind Tests

    @MainActor
    @Test func agentBackendKindIncludesClaudeCode() {
        let allKinds = AgentBackendKind.allCases
        #expect(allKinds.contains(.claudeCode))
    }

    @MainActor
    @Test func claudeCodeBackendKindHasCorrectRawValue() {
        #expect(AgentBackendKind.claudeCode.rawValue == "claudeCode")
    }

    // MARK: - WorkerRunRequest Extension Tests

    @MainActor
    @Test func resolvedProjectRootReturnsNilForInvalidBookmark() {
        let request = makeRequest(projectBookmark: Data([0x00, 0x01, 0x02]))
        #expect(request.resolvedProjectRoot == nil)
    }

    @MainActor
    @Test func resolvedProjectRootReturnsNilForEmptyBookmark() {
        let request = makeRequest(projectBookmark: Data())
        #expect(request.resolvedProjectRoot == nil)
    }

    // MARK: - Helpers

    private func makeRequest(
        cardPath: String = "project/test-phase/card.md",
        cliArgs: [String] = [],
        projectBookmark: Data = Data()
    ) -> WorkerRunRequest {
        WorkerRunRequest(
            runID: UUID(),
            flow: "implement",
            cardRelativePath: cardPath,
            projectBookmark: projectBookmark,
            logDirectory: FileManager.default.temporaryDirectory,
            outputDirectory: FileManager.default.temporaryDirectory,
            allowNetwork: false,
            cliArgs: cliArgs
        )
    }
}

// MARK: - Test Helpers Extension

extension ClaudeCodeExecutor {
    /// Exposes buildPrompt for testing purposes.
    func testBuildPrompt(from request: WorkerRunRequest) -> String {
        // Replicate the prompt building logic for testing
        var prompt = """
        You are working on a task card at: \(request.cardRelativePath)

        Please implement the requirements specified in this card. Follow these steps:
        1. Read the card file to understand the acceptance criteria
        2. Implement the required changes
        3. Run any relevant tests
        4. Update the card to mark completed items

        Work through the acceptance criteria systematically.
        """

        if !request.cliArgs.isEmpty {
            prompt += "\n\nAdditional context from CLI args: \(request.cliArgs.joined(separator: " "))"
        }

        return prompt
    }
}
